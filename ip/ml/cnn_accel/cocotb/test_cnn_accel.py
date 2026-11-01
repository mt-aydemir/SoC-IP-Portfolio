"""Cocotb regression for cnn_accel.

Coverage
    directed   reset state, the status reply, a single-tile GEMM, an identity
               layer that must reproduce its input, a fused ReLU, multi-tile
               accumulation, and the interrupt
    randomised random layers - weights, parameters and batches - checked
               against a Python model of the whole accelerator
    regression sustained full-rate throughput, randomised back-pressure on the
               result stream, and every malformed frame the parser is supposed
               to survive

The model here is the whole datapath, not a piece of it: weights in, int8 out,
including the accumulation across tiles and the requantisation. That is the
level the driver works at, so it is the level a mistake would actually be felt
at.

The error tests matter as much as the arithmetic ones. An accelerator driven
entirely over its data stream has no way to resynchronise if a malformed frame
desynchronises the parser - every subsequent job would be wrong, and the
failure would look like an arithmetic bug rather than a framing one. Each of
these sends a bad frame and then proves a good one still works.
"""
from __future__ import annotations

import cocotb
from cocotb.triggers import ReadOnly, RisingEdge

from socip import (
    ClockDomain,
    RandomStream,
    assert_eq,
    bits,
    describe,
    get_param,
    sample,
    to_signed,
)

ARRAY_N = get_param("ARRAY_N", 16)
DATA_WIDTH = get_param("DATA_WIDTH", 8)
ACC_WIDTH = get_param("ACC_WIDTH", 32)
MULT_WIDTH = get_param("MULT_WIDTH", 24)
SHIFT_WIDTH = get_param("SHIFT_WIDTH", 6)
ACC_DEPTH = get_param("ACC_DEPTH", 256)
OUT_FIFO_DEPTH = get_param("OUT_FIFO_DEPTH", 64)

CLK_PERIOD_NS = 4.0
STREAM_WIDTH = ARRAY_N * DATA_WIDTH
TOTAL_LATENCY = 2 * ARRAY_N + 4

OP_NOP = 0x00
OP_LOAD_WEIGHTS = 0x01
OP_LOAD_PARAMS = 0x02
OP_COMPUTE = 0x03
OP_STATUS = 0x04

FLAG_FIRST = 1 << 0
FLAG_LAST = 1 << 1

OUT_MIN = -(1 << (DATA_WIDTH - 1))
OUT_MAX = (1 << (DATA_WIDTH - 1)) - 1


# ---------------------------------------------------------------------------
# Frame construction
# ---------------------------------------------------------------------------

def header(opcode: int, count: int = 0, flags: int = 0,
           zero_point: int = 0, out_min: int = OUT_MIN,
           out_max: int = OUT_MAX) -> int:
    return (bits(opcode, 8)
            | (bits(flags, 2) << 8)
            | (bits(count, 16) << 16)
            | (bits(zero_point, 8) << 32)
            | (bits(out_min, 8) << 40)
            | (bits(out_max, 8) << 48))


def lane_pack(values: list[int], width: int = DATA_WIDTH) -> int:
    word = 0
    for index, value in enumerate(values):
        word |= bits(value, width) << (index * width)
    return word


def lane_unpack(word: int, count: int = ARRAY_N, width: int = DATA_WIDTH
                ) -> list[int]:
    mask = (1 << width) - 1
    return [to_signed((word >> (i * width)) & mask, width)
            for i in range(count)]


def param_beat(bias: int, mult: int, shift: int) -> int:
    return (bits(bias, ACC_WIDTH)
            | (bits(mult, MULT_WIDTH) << ACC_WIDTH)
            | (bits(shift, SHIFT_WIDTH) << (ACC_WIDTH + MULT_WIDTH)))


# ---------------------------------------------------------------------------
# Reference model
# ---------------------------------------------------------------------------

class Quantisation:
    """The per-channel requantisation parameters of a layer."""

    def __init__(self, bias: list[int], mult: list[int], shift: list[int],
                 zero_point: int = 0, out_min: int = OUT_MIN,
                 out_max: int = OUT_MAX) -> None:
        self.bias = bias
        self.mult = mult
        self.shift = shift
        self.zero_point = zero_point
        self.out_min = out_min
        self.out_max = out_max

    def apply(self, acc: int, channel: int) -> int:
        """Identical arithmetic to requant_int8, and to the C driver."""
        product = (acc + self.bias[channel]) * self.mult[channel]
        shift = self.shift[channel]
        if shift == 0:
            adjust = 0
        else:
            half = 1 << (shift - 1)
            adjust = (half - 1) if product < 0 else half

        value = ((product + adjust) >> shift) + self.zero_point
        return max(self.out_min, min(self.out_max, value))


def gemm_tile(weights: list[list[int]], vector: list[int]) -> list[int]:
    return [sum(weights[k][m] * vector[k] for k in range(ARRAY_N))
            for m in range(ARRAY_N)]


def model_layer(tiles: list[tuple[list[list[int]], list[list[int]]]],
                quant: Quantisation) -> list[list[int]]:
    """Accumulate every tile of a chunk, then requantise.

    *tiles* is a list of (weights, batch) pairs, all batches the same length -
    which is exactly the constraint the hardware enforces, because the
    accumulator is indexed by position within the batch.
    """
    length = len(tiles[0][1])
    accumulator = [[0] * ARRAY_N for _ in range(length)]

    for weights, batch in tiles:
        for index, vector in enumerate(batch):
            products = gemm_tile(weights, vector)
            for m in range(ARRAY_N):
                accumulator[index][m] += products[m]

    return [[quant.apply(accumulator[v][m], m) for m in range(ARRAY_N)]
            for v in range(length)]


# ---------------------------------------------------------------------------
# Transactors
# ---------------------------------------------------------------------------

class StreamMaster:
    """Drives the command stream, one frame at a time."""

    def __init__(self, dut) -> None:
        self.dut = dut

    def idle(self) -> None:
        self.dut.s_axis_tvalid.value = 0
        self.dut.s_axis_tdata.value = 0
        self.dut.s_axis_tlast.value = 0

    async def send_frame(self, beats: list[int]) -> None:
        """Send one TLAST-delimited frame, honouring back-pressure."""
        dut = self.dut
        for index, beat in enumerate(beats):
            dut.s_axis_tvalid.value = 1
            dut.s_axis_tdata.value = bits(beat, STREAM_WIDTH)
            dut.s_axis_tlast.value = 1 if index == len(beats) - 1 else 0

            while True:
                await ReadOnly()
                if int(dut.s_axis_tready.value) == 1:
                    break
                await RisingEdge(dut.clk)

            await RisingEdge(dut.clk)

        dut.s_axis_tvalid.value = 0
        dut.s_axis_tlast.value = 0
        dut.s_axis_tdata.value = 0


class ResultSink:
    """Collects result frames, splitting them on TLAST."""

    def __init__(self, dut, rng: RandomStream | None = None,
                 ready_probability: float = 1.0) -> None:
        self.dut = dut
        self.rng = rng
        self.ready_probability = ready_probability
        self.frames: list[list[int]] = []
        self.irq_pulses = 0
        self._current: list[int] = []
        self._task = None

    def start(self) -> "ResultSink":
        self.dut.m_axis_tready.value = int(self.ready_probability >= 1.0)
        self._task = cocotb.start_soon(self._run())
        return self

    async def _run(self) -> None:
        dut = self.dut
        while True:
            await RisingEdge(dut.clk)
            if self.ready_probability < 1.0:
                dut.m_axis_tready.value = int(
                    self.rng.boolean(self.ready_probability))

            await ReadOnly()
            if int(dut.rst_n.value) == 0:
                continue
            if int(dut.irq.value) == 1:
                self.irq_pulses += 1
            if int(dut.m_axis_tvalid.value) != 1:
                continue
            if int(dut.m_axis_tready.value) != 1:
                continue

            self._current.append(int(dut.m_axis_tdata.value))
            if int(dut.m_axis_tlast.value) == 1:
                self.frames.append(self._current)
                self._current = []

    async def expect_frames(self, count: int, timeout_cycles: int = 20000
                            ) -> list[list[int]]:
        for _ in range(timeout_cycles):
            if len(self.frames) >= count:
                return self.frames
            await RisingEdge(self.dut.clk)
        raise AssertionError(
            f"expected {count} result frame(s), {len(self.frames)} arrived "
            f"within {timeout_cycles} cycles")


class Accelerator:
    """The driver a host would write, expressed as testbench transactions."""

    def __init__(self, dut, sink: ResultSink, master: StreamMaster) -> None:
        self.dut = dut
        self.sink = sink
        self.master = master

    async def load_weights(self, weights: list[list[int]]) -> None:
        beats = [header(OP_LOAD_WEIGHTS, count=ARRAY_N)]
        beats += [lane_pack(row) for row in weights]
        await self.master.send_frame(beats)

    async def load_params(self, quant: Quantisation) -> None:
        beats = [header(OP_LOAD_PARAMS, count=ARRAY_N,
                        zero_point=quant.zero_point,
                        out_min=quant.out_min, out_max=quant.out_max)]
        beats += [param_beat(quant.bias[m], quant.mult[m], quant.shift[m])
                  for m in range(ARRAY_N)]
        await self.master.send_frame(beats)

    async def compute(self, batch: list[list[int]], first: bool = True,
                      last: bool = True) -> None:
        flags = (FLAG_FIRST if first else 0) | (FLAG_LAST if last else 0)
        beats = [header(OP_COMPUTE, count=len(batch), flags=flags)]
        beats += [lane_pack(vector) for vector in batch]
        await self.master.send_frame(beats)

    async def nop(self) -> None:
        await self.master.send_frame([header(OP_NOP)])

    async def status(self) -> list[int]:
        before = len(self.sink.frames)
        await self.master.send_frame([header(OP_STATUS)])
        frames = await self.sink.expect_frames(before + 1)
        return frames[before]


async def bring_up(dut, ready_probability: float = 1.0,
                   rng: RandomStream | None = None
                   ) -> tuple[ClockDomain, Accelerator, ResultSink]:
    dut._log.info("cnn_accel: ARRAY_N=%d ACC_DEPTH=%d OUT_FIFO_DEPTH=%d "
                  "latency=%d, %s",
                  ARRAY_N, ACC_DEPTH, OUT_FIFO_DEPTH, TOTAL_LATENCY, describe())

    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    master = StreamMaster(dut)
    master.idle()
    dut.m_axis_tready.value = 1
    await domain.reset()

    sink = ResultSink(dut, rng=rng, ready_probability=ready_probability).start()
    return domain, Accelerator(dut, sink, master), sink


async def read_flag(dut, signal) -> int:
    """Sample a status flag and return to a phase where driving is legal.

    ``sample`` leaves the simulation in the read-only phase, so a test that
    reads a flag and then sends another frame would be writing where writes are
    illegal. Every flag check in this file goes through here.
    """
    value = (await sample(signal))[0]
    await RisingEdge(dut.clk)
    return value


def check_frame(got: list[int], want: list[list[int]], label: str) -> None:
    assert_eq(len(got), len(want), f"{label}: beats in the result frame")
    for index, (beat, expected) in enumerate(zip(got, want)):
        actual = lane_unpack(beat)
        if actual != expected:
            for m in range(ARRAY_N):
                if actual[m] != expected[m]:
                    raise AssertionError(
                        f"{label}: vector {index}, channel {m}: "
                        f"expected {expected[m]}, got {actual[m]}")


def simple_quant(rng: RandomStream | None = None) -> Quantisation:
    """A scale of exactly 1/256, which keeps hand-checking easy."""
    return Quantisation(bias=[0] * ARRAY_N,
                        mult=[1] * ARRAY_N,
                        shift=[8] * ARRAY_N)


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: idle, accepting commands, nothing in flight, no error."""
    await bring_up(dut)

    tready, tvalid, busy, error, irq = await sample(
        dut.s_axis_tready, dut.m_axis_tvalid, dut.busy, dut.error, dut.irq)

    assert_eq(tready, 1, "s_axis_tready after reset")
    assert_eq(tvalid, 0, "m_axis_tvalid after reset")
    assert_eq(busy, 0, "busy after reset")
    assert_eq(error, 0, "error after reset")
    assert_eq(irq, 0, "irq after reset")


@cocotb.test()
async def test_status_frame(dut) -> None:
    """Directed: the status reply describes the build the host is talking to.

    A driver that assumes the wrong array size produces garbage rather than an
    error, so being able to read the geometry back is what makes a mismatch
    between the bitstream and the software detectable at start-up.
    """
    _domain, accel, _sink = await bring_up(dut)

    frame = await accel.status()
    assert_eq(len(frame), 2, "status frame length")

    identity = frame[0]
    assert_eq(identity & 0xFF, 1, "version")
    assert_eq((identity >> 8) & 0xFF, ARRAY_N, "ARRAY_N reported")
    assert_eq((identity >> 16) & 0xFF, DATA_WIDTH, "DATA_WIDTH reported")
    assert_eq((identity >> 24) & 0xFF, ACC_WIDTH, "ACC_WIDTH reported")
    assert_eq((identity >> 32) & 1, 0, "error flag in status")
    assert_eq((identity >> 40) & 0xFFFF, ACC_DEPTH, "ACC_DEPTH reported")
    assert_eq((identity >> 56) & 0xFF, min(OUT_FIFO_DEPTH, 255),
              "OUT_FIFO_DEPTH reported")

    counters = frame[1]
    assert_eq(counters & 0xFFFFFFFF, 0, "job count before any work")
    assert_eq((counters >> 32) & 0xFFFFFFFF, 0, "vector count before any work")


@cocotb.test()
async def test_identity_layer(dut) -> None:
    """Directed: an identity tile with a unit scale must return its input.

    Every stage is exercised - weight load, the array, the accumulator, the
    requantiser - and the expected answer needs no model at all, so a failure
    here points at the plumbing rather than at the arithmetic.
    """
    _domain, accel, sink = await bring_up(dut)

    weights = [[1 if k == m else 0 for m in range(ARRAY_N)]
               for k in range(ARRAY_N)]
    quant = Quantisation(bias=[0] * ARRAY_N, mult=[1] * ARRAY_N,
                         shift=[0] * ARRAY_N)

    batch = [[(v * 7 + k) % 100 - 50 for k in range(ARRAY_N)]
             for v in range(8)]

    await accel.load_weights(weights)
    await accel.load_params(quant)
    await accel.compute(batch)

    frames = await sink.expect_frames(1)
    check_frame(frames[0], batch, "identity layer")


@cocotb.test()
async def test_single_tile_gemm(dut) -> None:
    """Directed: one weight tile, one batch, checked against the model."""
    _domain, accel, sink = await bring_up(dut)
    rng = RandomStream("single_tile")

    weights = [[rng.sint(DATA_WIDTH) for _ in range(ARRAY_N)]
               for _ in range(ARRAY_N)]
    quant = simple_quant()
    batch = [[rng.sint(DATA_WIDTH) for _ in range(ARRAY_N)]
             for _ in range(32)]

    await accel.load_weights(weights)
    await accel.load_params(quant)
    await accel.compute(batch)

    frames = await sink.expect_frames(1)
    check_frame(frames[0], model_layer([(weights, batch)], quant),
                "single tile")


@cocotb.test()
async def test_multi_tile_accumulation(dut) -> None:
    """Directed: a reduction deeper than the array, split across three tiles.

    This is the case the accumulator buffer exists for, and it is the one that
    makes the block a CNN accelerator rather than a GEMM tile engine: a real
    layer reduces over hundreds of terms, and the host must be able to split
    that across tiles without doing the additions itself.
    """
    _domain, accel, sink = await bring_up(dut)
    rng = RandomStream("multi_tile")

    quant = simple_quant()
    batch_length = 24
    tiles = []
    for _ in range(3):
        weights = [[rng.sint(DATA_WIDTH) for _ in range(ARRAY_N)]
                   for _ in range(ARRAY_N)]
        batch = [[rng.sint(DATA_WIDTH) for _ in range(ARRAY_N)]
                 for _ in range(batch_length)]
        tiles.append((weights, batch))

    await accel.load_params(quant)

    for index, (weights, batch) in enumerate(tiles):
        await accel.load_weights(weights)
        await accel.compute(batch,
                            first=(index == 0),
                            last=(index == len(tiles) - 1))

    frames = await sink.expect_frames(1)
    assert_eq(len(frames), 1, "only the last tile emits a result frame")
    check_frame(frames[0], model_layer(tiles, quant), "three-tile reduction")


@cocotb.test()
async def test_fused_relu(dut) -> None:
    """Directed: a fused ReLU is the clamp window, not a mode.

    Raising out_min to the output zero point is how a quantised graph expresses
    a fused ReLU, so every negative accumulator must land exactly on the zero
    point.
    """
    _domain, accel, sink = await bring_up(dut)
    rng = RandomStream("relu")

    zero_point = -7
    weights = [[rng.sint(DATA_WIDTH) for _ in range(ARRAY_N)]
               for _ in range(ARRAY_N)]
    quant = Quantisation(bias=[0] * ARRAY_N, mult=[1] * ARRAY_N,
                         shift=[8] * ARRAY_N, zero_point=zero_point,
                         out_min=zero_point, out_max=OUT_MAX)
    batch = [[rng.sint(DATA_WIDTH) for _ in range(ARRAY_N)]
             for _ in range(48)]

    await accel.load_weights(weights)
    await accel.load_params(quant)
    await accel.compute(batch)

    frames = await sink.expect_frames(1)
    expected = model_layer([(weights, batch)], quant)
    check_frame(frames[0], expected, "fused relu")

    floor_hits = sum(1 for beat in expected for value in beat
                     if value == zero_point)
    assert floor_hits > 0, (
        "the stimulus never produced a negative accumulator, so the ReLU was "
        "not actually exercised")
    dut._log.info("%d of %d outputs were clamped by the fused ReLU",
                  floor_hits, len(expected) * ARRAY_N)


@cocotb.test()
async def test_per_channel_parameters(dut) -> None:
    """Directed: each output channel really does use its own scale and bias.

    A design that latched one parameter set for the whole layer would pass
    every test where the channels share parameters, and quietly halve the
    accuracy of a depthwise convolution.
    """
    _domain, accel, sink = await bring_up(dut)
    rng = RandomStream("per_channel")

    weights = [[1 if k == m else 0 for m in range(ARRAY_N)]
               for k in range(ARRAY_N)]
    quant = Quantisation(
        bias=[m * 3 for m in range(ARRAY_N)],
        mult=[1 + m for m in range(ARRAY_N)],
        shift=[m % 5 for m in range(ARRAY_N)],
    )
    batch = [[rng.between(-8, 8) for _ in range(ARRAY_N)] for _ in range(16)]

    await accel.load_weights(weights)
    await accel.load_params(quant)
    await accel.compute(batch)

    frames = await sink.expect_frames(1)
    check_frame(frames[0], model_layer([(weights, batch)], quant),
                "per-channel parameters")


@cocotb.test()
async def test_interrupt_and_counters(dut) -> None:
    """Directed: one interrupt per emitted frame, and the counters agree."""
    domain, accel, sink = await bring_up(dut)
    rng = RandomStream("irq")

    weights = [[rng.sint(DATA_WIDTH) for _ in range(ARRAY_N)]
               for _ in range(ARRAY_N)]
    quant = simple_quant()

    await accel.load_weights(weights)
    await accel.load_params(quant)

    total_vectors = 0
    for jobs in range(3):
        batch = [[rng.sint(DATA_WIDTH) for _ in range(ARRAY_N)]
                 for _ in range(10 + jobs)]
        total_vectors += len(batch)
        await accel.compute(batch)

    await sink.expect_frames(3)
    # The interrupt is registered from the last beat's handshake, so it lands
    # the cycle after the frame is complete.
    await domain.cycles(4)
    assert_eq(sink.irq_pulses, 3, "one interrupt per emitted frame")

    counters = (await accel.status())[1]
    assert_eq(counters & 0xFFFFFFFF, 3, "completed job count")
    assert_eq((counters >> 32) & 0xFFFFFFFF, total_vectors,
              "processed vector count")


# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_unknown_opcode_is_survivable(dut) -> None:
    """Regression: a bad command raises the error and does not desynchronise."""
    _domain, accel, sink = await bring_up(dut)
    rng = RandomStream("bad_opcode")

    await accel.master.send_frame([header(0x7F, count=3), 0, 0, 0])

    assert_eq(await read_flag(dut, dut.error), 1, "error after an unknown opcode")

    # NOP is the acknowledgement, and the next job must be correct.
    await accel.nop()
    assert_eq(await read_flag(dut, dut.error), 0, "NOP clears the sticky error")

    weights = [[rng.sint(DATA_WIDTH) for _ in range(ARRAY_N)]
               for _ in range(ARRAY_N)]
    quant = simple_quant()
    batch = [[rng.sint(DATA_WIDTH) for _ in range(ARRAY_N)]
             for _ in range(12)]

    await accel.load_weights(weights)
    await accel.load_params(quant)
    await accel.compute(batch)

    frames = await sink.expect_frames(1)
    check_frame(frames[0], model_layer([(weights, batch)], quant),
                "job after a bad opcode")


@cocotb.test()
async def test_short_weight_frame_is_not_committed(dut) -> None:
    """Regression: a truncated weight tile is refused rather than half loaded.

    Half a tile is misaligned, not merely incomplete: every row would sit in
    the wrong row of the array. Computing with it would give numbers that look
    almost right, so the frame is discarded and the error raised instead.
    """
    _domain, accel, sink = await bring_up(dut)
    rng = RandomStream("short_weights")

    good = [[1 if k == m else 0 for m in range(ARRAY_N)]
            for k in range(ARRAY_N)]
    quant = Quantisation(bias=[0] * ARRAY_N, mult=[1] * ARRAY_N,
                         shift=[0] * ARRAY_N)

    await accel.load_weights(good)
    await accel.load_params(quant)

    # Now a weight frame that ends three rows early.
    truncated = [header(OP_LOAD_WEIGHTS, count=ARRAY_N)]
    truncated += [lane_pack([9] * ARRAY_N) for _ in range(ARRAY_N - 3)]
    await accel.master.send_frame(truncated)

    assert_eq(await read_flag(dut, dut.error), 1, "error after a short tile")

    # The published tile must still be the identity one.
    batch = [[rng.between(-40, 40) for _ in range(ARRAY_N)] for _ in range(8)]
    await accel.compute(batch)

    frames = await sink.expect_frames(1)
    check_frame(frames[0], batch, "the refused tile was not published")


@cocotb.test()
async def test_compute_count_mismatch(dut) -> None:
    """Regression: a batch shorter than its header still produces a valid frame.

    The header count and TLAST disagreeing is a driver bug. TLAST wins, because
    it is the delimiter the DMA actually produced; the mismatch is reported,
    and the result frame is well formed so the consumer's DMA still completes.
    """
    _domain, accel, sink = await bring_up(dut)
    rng = RandomStream("count_mismatch")

    weights = [[rng.sint(DATA_WIDTH) for _ in range(ARRAY_N)]
               for _ in range(ARRAY_N)]
    quant = simple_quant()

    await accel.load_weights(weights)
    await accel.load_params(quant)

    batch = [[rng.sint(DATA_WIDTH) for _ in range(ARRAY_N)]
             for _ in range(6)]
    beats = [header(OP_COMPUTE, count=20, flags=FLAG_FIRST | FLAG_LAST)]
    beats += [lane_pack(v) for v in batch]
    await accel.master.send_frame(beats)

    frames = await sink.expect_frames(1)
    check_frame(frames[0], model_layer([(weights, batch)], quant),
                "short compute frame")
    assert_eq(await read_flag(dut, dut.error), 1, "error after a count mismatch")


@cocotb.test()
async def test_surplus_compute_beats(dut) -> None:
    """Regression: beats past the header count are dropped, not accumulated."""
    _domain, accel, sink = await bring_up(dut)
    rng = RandomStream("surplus")

    weights = [[rng.sint(DATA_WIDTH) for _ in range(ARRAY_N)]
               for _ in range(ARRAY_N)]
    quant = simple_quant()

    await accel.load_weights(weights)
    await accel.load_params(quant)

    kept = [[rng.sint(DATA_WIDTH) for _ in range(ARRAY_N)] for _ in range(5)]
    surplus = [[rng.sint(DATA_WIDTH) for _ in range(ARRAY_N)]
               for _ in range(4)]

    beats = [header(OP_COMPUTE, count=len(kept), flags=FLAG_FIRST | FLAG_LAST)]
    beats += [lane_pack(v) for v in kept + surplus]
    await accel.master.send_frame(beats)

    frames = await sink.expect_frames(1)
    check_frame(frames[0], model_layer([(weights, kept)], quant),
                "surplus beats dropped")
    assert_eq(await read_flag(dut, dut.error), 1, "error after surplus beats")


@cocotb.test()
async def test_inconsistent_chunk_length(dut) -> None:
    """Regression: tiles of an accumulation chunk must agree on batch length.

    They index the same accumulator, so a mismatch adds one output position's
    partial sum to a different one's. It is reported rather than silently
    producing a plausible answer.
    """
    _domain, accel, _sink = await bring_up(dut)
    rng = RandomStream("chunk_length")

    quant = simple_quant()
    await accel.load_params(quant)

    weights = [[rng.sint(DATA_WIDTH) for _ in range(ARRAY_N)]
               for _ in range(ARRAY_N)]

    await accel.load_weights(weights)
    await accel.compute([[1] * ARRAY_N for _ in range(10)],
                        first=True, last=False)
    assert_eq(await read_flag(dut, dut.error), 0, "no error on the first tile")

    await accel.load_weights(weights)
    await accel.compute([[1] * ARRAY_N for _ in range(7)],
                        first=False, last=True)
    assert_eq(await read_flag(dut, dut.error), 1,
              "error when a later tile changes the batch length")


# ---------------------------------------------------------------------------
# Randomised and throughput tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_layers(dut) -> None:
    """Randomised: eight layers of random weights, parameters and batches."""
    _domain, accel, sink = await bring_up(dut)
    rng = RandomStream("random_layers")
    dut._log.info("random seed = %d", rng.seed)

    for layer in range(8):
        weights = [[rng.corner_sint(DATA_WIDTH) for _ in range(ARRAY_N)]
                   for _ in range(ARRAY_N)]
        quant = Quantisation(
            bias=[rng.sint(16) for _ in range(ARRAY_N)],
            mult=[rng.between(1 << (MULT_WIDTH - 2), (1 << MULT_WIDTH) - 1)
                  for _ in range(ARRAY_N)],
            shift=[rng.between(MULT_WIDTH - 2, MULT_WIDTH + 6)
                   for _ in range(ARRAY_N)],
            zero_point=rng.between(-16, 16),
        )
        batch = [[rng.corner_sint(DATA_WIDTH) for _ in range(ARRAY_N)]
                 for _ in range(rng.between(1, 40))]

        await accel.load_weights(weights)
        await accel.load_params(quant)
        await accel.compute(batch)

        frames = await sink.expect_frames(layer + 1)
        check_frame(frames[layer], model_layer([(weights, batch)], quant),
                    f"random layer {layer}")


@cocotb.test()
async def test_random_multi_tile_layers(dut) -> None:
    """Randomised: layers whose reduction is split over two to four tiles."""
    _domain, accel, sink = await bring_up(dut)
    rng = RandomStream("random_multi_tile")

    for layer in range(4):
        quant = Quantisation(
            bias=[rng.sint(16) for _ in range(ARRAY_N)],
            mult=[rng.between(1, (1 << MULT_WIDTH) - 1) for _ in range(ARRAY_N)],
            shift=[rng.between(MULT_WIDTH - 2, MULT_WIDTH + 8)
                   for _ in range(ARRAY_N)],
        )
        await accel.load_params(quant)

        length = rng.between(4, 30)
        count = rng.between(2, 4)
        tiles = []
        for _ in range(count):
            tiles.append((
                [[rng.sint(DATA_WIDTH) for _ in range(ARRAY_N)]
                 for _ in range(ARRAY_N)],
                [[rng.sint(DATA_WIDTH) for _ in range(ARRAY_N)]
                 for _ in range(length)],
            ))

        for index, (weights, batch) in enumerate(tiles):
            await accel.load_weights(weights)
            await accel.compute(batch, first=(index == 0),
                                last=(index == count - 1))

        frames = await sink.expect_frames(layer + 1)
        check_frame(frames[layer], model_layer(tiles, quant),
                    f"random multi-tile layer {layer} ({count} tiles)")


@cocotb.test()
async def test_result_stream_back_pressure(dut) -> None:
    """Regression: a consumer that stalls must not corrupt or drop a result.

    The credit scheme is what makes this work: the block stops admitting
    activations long before the output buffer fills, because everything already
    inside the pipeline is committed to arriving.
    """
    rng = RandomStream("back_pressure")
    _domain, accel, sink = await bring_up(dut, ready_probability=0.3, rng=rng)

    weights = [[rng.sint(DATA_WIDTH) for _ in range(ARRAY_N)]
               for _ in range(ARRAY_N)]
    quant = simple_quant()
    batch = [[rng.sint(DATA_WIDTH) for _ in range(ARRAY_N)]
             for _ in range(200)]

    await accel.load_weights(weights)
    await accel.load_params(quant)
    await accel.compute(batch)

    frames = await sink.expect_frames(1, timeout_cycles=40000)
    check_frame(frames[0], model_layer([(weights, batch)], quant),
                "under back-pressure")


@cocotb.test()
async def test_full_rate_throughput(dut) -> None:
    """Regression: a long batch sustains close to one vector per cycle.

    The design's whole claim is ARRAY_N**2 multiply-accumulates per cycle, and
    that only holds if the frame overhead stays small. Measuring it here means
    a change that quietly inserted a bubble per vector would be caught.
    """
    domain, accel, sink = await bring_up(dut)
    rng = RandomStream("throughput")

    weights = [[rng.sint(DATA_WIDTH) for _ in range(ARRAY_N)]
               for _ in range(ARRAY_N)]
    quant = simple_quant()
    batch = [[rng.sint(DATA_WIDTH) for _ in range(ARRAY_N)]
             for _ in range(ACC_DEPTH)]

    await accel.load_weights(weights)
    await accel.load_params(quant)

    start = cocotb.utils.get_sim_time(units="ns")
    await accel.compute(batch)
    frames = await sink.expect_frames(1, timeout_cycles=20000)
    elapsed_ns = cocotb.utils.get_sim_time(units="ns") - start

    check_frame(frames[0], model_layer([(weights, batch)], quant),
                "full rate batch")

    cycles = elapsed_ns / CLK_PERIOD_NS
    per_vector = cycles / len(batch)
    dut._log.info("%d vectors in %.0f cycles: %.3f cycles per vector, "
                  "%.0f MAC/cycle",
                  len(batch), cycles, per_vector,
                  ARRAY_N * ARRAY_N / per_vector)

    # One header beat, plus the pipeline drain, over ACC_DEPTH vectors.
    budget = 1.0 + (TOTAL_LATENCY + 4) / len(batch)
    assert per_vector <= budget, (
        f"throughput regressed: {per_vector:.3f} cycles per vector, "
        f"budget {budget:.3f}")

    await domain.cycles(4)


@cocotb.test()
async def test_maximum_batch(dut) -> None:
    """Regression: a batch that exactly fills the accumulator buffer."""
    _domain, accel, sink = await bring_up(dut)
    rng = RandomStream("max_batch")

    weights = [[rng.sint(DATA_WIDTH) for _ in range(ARRAY_N)]
               for _ in range(ARRAY_N)]
    quant = simple_quant()
    batch = [[rng.sint(DATA_WIDTH) for _ in range(ARRAY_N)]
             for _ in range(ACC_DEPTH)]

    await accel.load_weights(weights)
    await accel.load_params(quant)
    await accel.compute(batch, first=True, last=False)
    await accel.load_weights(weights)
    await accel.compute(batch, first=False, last=True)

    frames = await sink.expect_frames(1, timeout_cycles=40000)
    check_frame(frames[0],
                model_layer([(weights, batch), (weights, batch)], quant),
                "full accumulator buffer, two tiles")

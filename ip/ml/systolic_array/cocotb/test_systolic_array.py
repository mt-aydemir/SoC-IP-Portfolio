"""Cocotb regression for systolic_array.

Coverage
    directed   reset state, the measured latency, an identity weight tile, a
               single vector, the signed extremes, and the weight double
               buffer loaded while the array is computing
    randomised 200 random weight tiles and vector batches against a Python
               matrix multiply
    regression a long full-rate batch with no bubbles, a batch with gaps, and
               back-to-back tiles with different weights

The failure this suite exists to catch is a skew or deskew off by one. An
array with the wrong skew still produces plausible numbers - each result is a
sum of real products of real operands - and it takes a reference model to see
that the operands belong to different vectors. Testing with an identity tile
finds it immediately, which is why that test comes before the random one.
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

ROWS = get_param("ROWS", 16)
COLS = get_param("COLS", 16)
DATA_WIDTH = get_param("DATA_WIDTH", 8)
ACC_WIDTH = get_param("ACC_WIDTH", 32)

CLK_PERIOD_NS = 4.0
LATENCY = ROWS + COLS - 1

DATA_MIN = -(1 << (DATA_WIDTH - 1))
DATA_MAX = (1 << (DATA_WIDTH - 1)) - 1


def pack(values: list[int], width: int) -> int:
    """Little-endian lane packing: element 0 occupies the low bits."""
    word = 0
    for index, value in enumerate(values):
        word |= bits(value, width) << (index * width)
    return word


def unpack(word: int, count: int, width: int) -> list[int]:
    mask = (1 << width) - 1
    return [to_signed((word >> (index * width)) & mask, width)
            for index in range(count)]


def matmul(weights: list[list[int]], vector: list[int]) -> list[int]:
    """res[m] = sum over k of W[k][m] * a[k], the array's contract."""
    return [sum(weights[k][m] * vector[k] for k in range(ROWS))
            for m in range(COLS)]


async def bring_up(dut) -> ClockDomain:
    dut._log.info("systolic_array: %dx%d, DATA_WIDTH=%d, ACC_WIDTH=%d, "
                  "LATENCY=%d, %s",
                  ROWS, COLS, DATA_WIDTH, ACC_WIDTH, LATENCY, describe())

    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    dut.w_valid.value = 0
    dut.w_row.value = 0
    dut.w_commit.value = 0
    dut.a_valid.value = 0
    dut.a_vector.value = 0
    await domain.reset()
    return domain


async def push_tile(dut, weights: list[list[int]], commit: bool = True) -> None:
    """Push a ROWS x COLS weight tile in, row 0 first, and optionally publish it.

    Rows enter at the south edge and shift north, which is what makes the
    natural order the correct one.
    """
    for row in weights:
        await RisingEdge(dut.clk)
        dut.w_valid.value = 1
        dut.w_row.value = pack(row, DATA_WIDTH)

    await RisingEdge(dut.clk)
    dut.w_valid.value = 0
    dut.w_row.value = 0

    if commit:
        dut.w_commit.value = 1
        await RisingEdge(dut.clk)
        dut.w_commit.value = 0


async def commit_tile(dut) -> None:
    await RisingEdge(dut.clk)
    dut.w_commit.value = 1
    await RisingEdge(dut.clk)
    dut.w_commit.value = 0


async def stream(dut, vectors: list[list[int] | None]) -> list[list[int]]:
    """Present one vector per cycle - None is an idle cycle - and collect results."""
    results: list[list[int]] = []
    total = len(vectors) + LATENCY + 2

    for index in range(total):
        await RisingEdge(dut.clk)
        vector = vectors[index] if index < len(vectors) else None
        if vector is None:
            dut.a_valid.value = 0
            dut.a_vector.value = 0
        else:
            dut.a_valid.value = 1
            dut.a_vector.value = pack(vector, DATA_WIDTH)

        await ReadOnly()
        if int(dut.res_valid.value) == 1:
            results.append(unpack(int(dut.res_vector.value), COLS, ACC_WIDTH))

    await RisingEdge(dut.clk)
    return results


async def check_batch(dut, weights: list[list[int]],
                      vectors: list[list[int] | None]) -> None:
    results = await stream(dut, vectors)
    expected = [matmul(weights, v) for v in vectors if v is not None]

    assert_eq(len(results), len(expected), "number of result vectors")
    for index, (want, got) in enumerate(zip(expected, results)):
        if want != got:
            for m in range(COLS):
                if want[m] != got[m]:
                    raise AssertionError(
                        f"vector {index}, column {m}: expected {want[m]}, "
                        f"got {got[m]}")


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: nothing in flight, no result claimed."""
    await bring_up(dut)

    res_valid, busy, res_vector = await sample(
        dut.res_valid, dut.busy, dut.res_vector)
    assert_eq(res_valid, 0, "res_valid after reset")
    assert_eq(busy, 0, "busy after reset")
    assert_eq(res_vector, 0, "res_vector after reset")


@cocotb.test()
async def test_latency(dut) -> None:
    """Directed: the result lands exactly ROWS + COLS - 1 cycles later.

    The consumer aligns per-channel parameters by counting cycles, so this
    number is part of the contract.
    """
    domain = await bring_up(dut)

    weights = [[1 if k == 0 else 0 for _ in range(COLS)] for k in range(ROWS)]
    await push_tile(dut, weights)

    await domain.edge()
    dut.a_valid.value = 1
    dut.a_vector.value = pack([3] + [0] * (ROWS - 1), DATA_WIDTH)
    await domain.edge()
    dut.a_valid.value = 0
    dut.a_vector.value = 0

    for cycle in range(1, LATENCY + 4):
        valid = (await sample(dut.res_valid))[0]
        if valid:
            assert_eq(cycle, LATENCY, "measured array latency")
            break
        await domain.edge()
    else:
        raise AssertionError("no result vector appeared")


@cocotb.test()
async def test_identity_tile(dut) -> None:
    """Directed: with W = I every result column is the activation of its row.

    This is the test that catches a skew or deskew off by one. Any misalignment
    moves an activation into the wrong column, and with an identity tile that
    is visible by inspection rather than only through a reference model.
    """
    await bring_up(dut)

    # The diagonal is well defined for a rectangular array too: column m
    # selects activation m when the array is at least that many rows deep, and
    # is zero otherwise.
    weights = [[1 if k == m else 0 for m in range(COLS)] for k in range(ROWS)]
    await push_tile(dut, weights)

    vectors = [[(k + 1) % (DATA_MAX + 1) for k in range(ROWS)],
               [DATA_MAX if k % 2 else DATA_MIN for k in range(ROWS)],
               [0] * ROWS]

    results = await stream(dut, list(vectors))
    assert_eq(len(results), len(vectors), "result count")
    for index, vector in enumerate(vectors):
        expected = [vector[m] if m < ROWS else 0 for m in range(COLS)]
        assert results[index] == expected, (
            f"identity tile, vector {index}: expected {expected}, "
            f"got {results[index]}")


@cocotb.test()
async def test_single_vector(dut) -> None:
    """Directed: one vector through a known tile, computed by hand."""
    await bring_up(dut)

    # Column m holds the constant m+1 in every row, so the result of a vector
    # is (m+1) * sum(a).
    weights = [[(m + 1) % (DATA_MAX + 1) for m in range(COLS)]
               for _ in range(ROWS)]
    await push_tile(dut, weights)

    vector = [2] * ROWS
    results = await stream(dut, [vector])

    assert_eq(len(results), 1, "one result vector")
    for m in range(COLS):
        assert_eq(results[0][m], ((m + 1) % (DATA_MAX + 1)) * 2 * ROWS,
                  f"column {m}")


@cocotb.test()
async def test_signed_extremes(dut) -> None:
    """Directed: the tile that produces the largest possible column sum.

    Every weight and every activation at DATA_MIN gives ROWS * DATA_MIN**2,
    which is the value that decides whether ACC_WIDTH is wide enough.
    """
    await bring_up(dut)

    weights = [[DATA_MIN] * COLS for _ in range(ROWS)]
    await push_tile(dut, weights)

    vectors = [
        [DATA_MIN] * ROWS,
        [DATA_MAX] * ROWS,
        [DATA_MIN if k % 2 else DATA_MAX for k in range(ROWS)],
    ]
    await check_batch(dut, weights, list(vectors))

    results = await stream(dut, [[DATA_MIN] * ROWS])
    assert_eq(results[0][0], ROWS * DATA_MIN * DATA_MIN,
              "largest positive column sum")


@cocotb.test()
async def test_busy_tracks_the_pipeline(dut) -> None:
    """Directed: busy is high from admission until the last result emerges.

    The consumer uses busy to decide when publishing a new weight tile is safe,
    so it must cover the whole pipeline and not just part of it.
    """
    domain = await bring_up(dut)

    weights = [[1] * COLS for _ in range(ROWS)]
    await push_tile(dut, weights)

    assert_eq((await sample(dut.busy))[0], 0, "busy before any work")

    await domain.edge()
    dut.a_valid.value = 1
    dut.a_vector.value = pack([1] * ROWS, DATA_WIDTH)
    assert_eq((await sample(dut.busy))[0], 1, "busy in the admission cycle")

    await domain.edge()
    dut.a_valid.value = 0
    dut.a_vector.value = 0

    for _ in range(LATENCY - 1):
        assert_eq((await sample(dut.busy))[0], 1, "busy while data is inside")
        await domain.edge()

    # The result emerges on the LATENCY-th cycle; busy clears with it.
    assert_eq((await sample(dut.res_valid))[0], 1, "result on the last cycle")
    await domain.edge()
    assert_eq((await sample(dut.busy))[0], 0, "busy clears once drained")
    await domain.edge()


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_tiles(dut) -> None:
    """Randomised: 20 random tiles, 10 random vectors each, against the model."""
    await bring_up(dut)
    rng = RandomStream("systolic_array")
    dut._log.info("random seed = %d", rng.seed)

    for _ in range(20):
        weights = [[rng.corner_sint(DATA_WIDTH) for _ in range(COLS)]
                   for _ in range(ROWS)]
        await push_tile(dut, weights)

        vectors: list[list[int] | None] = [
            [rng.corner_sint(DATA_WIDTH) for _ in range(ROWS)]
            for _ in range(10)
        ]
        await check_batch(dut, weights, vectors)


@cocotb.test()
async def test_random_with_gaps(dut) -> None:
    """Randomised: idle cycles scattered through the batch.

    An idle cycle presents a zero vector, which must contribute nothing to any
    result. A skew buffer that held its previous contents instead would corrupt
    the vectors either side of the gap.
    """
    await bring_up(dut)
    rng = RandomStream("gaps")

    weights = [[rng.sint(DATA_WIDTH) for _ in range(COLS)]
               for _ in range(ROWS)]
    await push_tile(dut, weights)

    vectors: list[list[int] | None] = []
    for _ in range(120):
        if rng.boolean(0.3):
            vectors.append(None)
        else:
            vectors.append([rng.sint(DATA_WIDTH) for _ in range(ROWS)])

    await check_batch(dut, weights, vectors)


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_full_rate_batch(dut) -> None:
    """Regression: 500 vectors with no bubbles.

    At one vector per cycle the array retires ROWS*COLS multiply-accumulates
    every cycle, which is the number the whole design exists to reach.
    """
    await bring_up(dut)
    rng = RandomStream("full_rate")

    weights = [[rng.sint(DATA_WIDTH) for _ in range(COLS)]
               for _ in range(ROWS)]
    await push_tile(dut, weights)

    vectors: list[list[int] | None] = [
        [rng.sint(DATA_WIDTH) for _ in range(ROWS)] for _ in range(500)
    ]
    await check_batch(dut, weights, vectors)

    dut._log.info("%d vectors, %d MACs retired",
                  len(vectors), len(vectors) * ROWS * COLS)


@cocotb.test()
async def test_double_buffered_weight_load(dut) -> None:
    """Regression: load the next tile while the current one is computing.

    This is what the shadow weight register is for. The next tile is pushed
    through the array during the batch, and published only once the pipeline
    has drained - publishing it early would leave the vectors in flight
    accumulating against a mixture of two tiles.
    """
    domain = await bring_up(dut)
    rng = RandomStream("double_buffer")

    tile_a = [[rng.sint(DATA_WIDTH) for _ in range(COLS)] for _ in range(ROWS)]
    tile_b = [[rng.sint(DATA_WIDTH) for _ in range(COLS)] for _ in range(ROWS)]

    await push_tile(dut, tile_a)

    batch: list[list[int] | None] = [
        [rng.sint(DATA_WIDTH) for _ in range(ROWS)] for _ in range(40)
    ]
    expected_a = [matmul(tile_a, v) for v in batch if v is not None]

    # Admit the batch, and push tile B through the array while it runs. The
    # array is a pipeline, so the loads and the compute interleave cleanly as
    # long as the two do not share a cycle.
    results: list[list[int]] = []
    row_index = 0

    for index in range(len(batch) + LATENCY + 2):
        await RisingEdge(dut.clk)

        vector = batch[index] if index < len(batch) else None
        loading = vector is None and row_index < ROWS

        dut.a_valid.value = 0 if vector is None else 1
        dut.a_vector.value = 0 if vector is None else pack(vector, DATA_WIDTH)
        dut.w_valid.value = 1 if loading else 0
        dut.w_row.value = pack(tile_b[row_index], DATA_WIDTH) if loading else 0
        if loading:
            row_index += 1

        await ReadOnly()
        if int(dut.res_valid.value) == 1:
            results.append(unpack(int(dut.res_vector.value), COLS, ACC_WIDTH))

    await RisingEdge(dut.clk)
    dut.w_valid.value = 0
    dut.w_row.value = 0

    assert_eq(len(results), len(expected_a), "results from tile A")
    for index, (want, got) in enumerate(zip(expected_a, results)):
        assert want == got, f"tile A vector {index}: expected {want}, got {got}"
    assert_eq(row_index, ROWS, "the whole of tile B was pushed during the batch")

    # The pipeline has drained, so publishing tile B is now safe.
    await commit_tile(dut)

    batch_b: list[list[int] | None] = [
        [rng.sint(DATA_WIDTH) for _ in range(ROWS)] for _ in range(20)
    ]
    await check_batch(dut, tile_b, batch_b)
    dut._log.info("tile B took effect with no idle cycles spent loading it")


@cocotb.test()
async def test_consecutive_tiles(dut) -> None:
    """Regression: three tiles in a row, each with its own batch."""
    await bring_up(dut)
    rng = RandomStream("consecutive")

    for tile in range(3):
        weights = [[rng.sint(DATA_WIDTH) for _ in range(COLS)]
                   for _ in range(ROWS)]
        await push_tile(dut, weights)

        vectors: list[list[int] | None] = [
            [rng.sint(DATA_WIDTH) for _ in range(ROWS)] for _ in range(30)
        ]
        await check_batch(dut, weights, vectors)
        dut._log.info("tile %d verified", tile)

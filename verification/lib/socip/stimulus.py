"""Reproducible randomised stimulus generation.

Every random test seeds an explicit ``RandomStream`` so that a failing
regression can be replayed bit-for-bit from the seed printed in the log.
"""
from __future__ import annotations

import os
import random
from typing import Iterable, Iterator, Sequence, TypeVar

T = TypeVar("T")


class RandomStream:
    """A named, independently seeded random source.

    The seed comes from (in order) an explicit argument, the
    ``COCOTB_RANDOM_SEED`` environment variable set by the runner, or the
    system entropy pool. It is always reported through :attr:`seed` so the
    test can log it.
    """

    def __init__(self, name: str = "rng", seed: int | None = None) -> None:
        if seed is None:
            env = os.environ.get("COCOTB_RANDOM_SEED")
            seed = int(env) if env and env.isdigit() else random.randrange(1 << 31)
        self.name = name
        self.seed = seed
        self._rng = random.Random(seed)

    def __repr__(self) -> str:
        return f"RandomStream(name={self.name!r}, seed={self.seed})"

    # -- primitive draws ----------------------------------------------------
    def uint(self, width: int) -> int:
        """Uniform unsigned integer of *width* bits."""
        return self._rng.getrandbits(width) if width > 0 else 0

    def sint(self, width: int) -> int:
        """Uniform signed integer representable in *width* bits."""
        return self._rng.randrange(-(1 << (width - 1)), 1 << (width - 1))

    def between(self, low: int, high: int) -> int:
        """Uniform integer in the inclusive range [low, high]."""
        return self._rng.randint(low, high)

    def boolean(self, true_probability: float = 0.5) -> bool:
        return self._rng.random() < true_probability

    def choice(self, population: Sequence[T]) -> T:
        return self._rng.choice(population)

    def shuffled(self, population: Iterable[T]) -> list[T]:
        items = list(population)
        self._rng.shuffle(items)
        return items

    # -- corner-biased draws ------------------------------------------------
    def corner_uint(self, width: int, corner_probability: float = 0.35) -> int:
        """Unsigned draw biased towards the values that break arithmetic.

        Pure uniform stimulus almost never hits zero, all-ones or the
        power-of-two boundaries where carry chains and saturation logic go
        wrong, so those are injected explicitly.
        """
        if self._rng.random() < corner_probability:
            corners = [0, 1, (1 << width) - 1, (1 << width) - 2,
                       1 << (width - 1), (1 << (width - 1)) - 1]
            return self._rng.choice([c & ((1 << width) - 1) for c in corners])
        return self.uint(width)

    def corner_sint(self, width: int, corner_probability: float = 0.35) -> int:
        """Signed draw biased towards the extremes and around zero."""
        if self._rng.random() < corner_probability:
            corners = [0, 1, -1, (1 << (width - 1)) - 1, -(1 << (width - 1)),
                       (1 << (width - 1)) - 2, -(1 << (width - 1)) + 1]
            return self._rng.choice(corners)
        return self.sint(width)

    def delay(self, max_idle: int = 3, idle_probability: float = 0.4) -> int:
        """Back-pressure gap length: mostly zero, occasionally a burst gap."""
        if self._rng.random() < idle_probability:
            return self._rng.randint(1, max_idle)
        return 0


def constrained_ints(rng: RandomStream, count: int, width: int,
                     signed: bool = False) -> Iterator[int]:
    """Yield *count* corner-biased integers of *width* bits."""
    draw = rng.corner_sint if signed else rng.corner_uint
    for _ in range(count):
        yield draw(width)


def weighted_choice(rng: RandomStream, choices: Sequence[tuple[T, int]]) -> T:
    """Pick from ``[(value, weight), ...]`` proportionally to the weights."""
    total = sum(weight for _, weight in choices)
    if total <= 0:
        raise ValueError("weighted_choice: total weight must be positive")
    point = rng.between(1, total)
    cumulative = 0
    for value, weight in choices:
        cumulative += weight
        if point <= cumulative:
            return value
    return choices[-1][0]

"""A minimal, strict in-order scoreboard.

Producers push expected transactions, monitors push observed ones. Any
mismatch, and any residue left at the end of the test, is an error.
"""
from __future__ import annotations

from collections import deque
from typing import Any, Callable, Deque, Optional


class ScoreboardError(AssertionError):
    """Raised on a scoreboard mismatch or on leftover expected items."""


class Scoreboard:
    """In-order comparison of expected against observed transactions.

    Parameters
    ----------
    name:
        Used in failure messages.
    compare:
        Optional custom equality predicate; defaults to ``==``.
    formatter:
        Optional rendering function for failure messages.
    """

    def __init__(self, name: str = "scoreboard",
                 compare: Optional[Callable[[Any, Any], bool]] = None,
                 formatter: Optional[Callable[[Any], str]] = None) -> None:
        self.name = name
        self._expected: Deque[Any] = deque()
        self._compare = compare or (lambda a, b: a == b)
        self._format = formatter or repr
        self.matched = 0
        self.errors = 0

    def expect(self, item: Any) -> None:
        self._expected.append(item)

    def expect_many(self, items) -> None:
        self._expected.extend(items)

    def observe(self, item: Any) -> None:
        if not self._expected:
            self.errors += 1
            raise ScoreboardError(
                f"{self.name}: unexpected transaction {self._format(item)} "
                f"(nothing was expected)")
        expected = self._expected.popleft()
        if not self._compare(expected, item):
            self.errors += 1
            raise ScoreboardError(
                f"{self.name}: transaction {self.matched} mismatch\n"
                f"  expected: {self._format(expected)}\n"
                f"  observed: {self._format(item)}")
        self.matched += 1

    @property
    def outstanding(self) -> int:
        return len(self._expected)

    def check_done(self) -> None:
        """Fail if any expected transaction was never observed."""
        if self._expected:
            pending = ", ".join(self._format(x) for x in list(self._expected)[:8])
            more = "" if len(self._expected) <= 8 else f" (+{len(self._expected) - 8} more)"
            raise ScoreboardError(
                f"{self.name}: {len(self._expected)} expected transaction(s) "
                f"never arrived: {pending}{more}")

    def summary(self) -> str:
        return (f"{self.name}: {self.matched} matched, "
                f"{self.errors} error(s), {self.outstanding} outstanding")

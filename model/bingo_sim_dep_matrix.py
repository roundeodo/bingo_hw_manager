"""
Counter-Based Dependency Matrix Model — mirrors bingo_hw_manager_dep_matrix.sv.

Each cell is an 8-bit saturating counter (not a 1-bit flag). Multiple
set_column operations accumulate without rejection, eliminating the
deadlock caused by overlap detection in the original 1-bit design.

Operations:
  - check_row(row, check_code): True if counter[row][c] >= 1 for all c in check_code
  - set_column(col, set_code): increment counter[r][col] for each r in set_code (always succeeds)
  - clear_row(row, check_code): decrement counter[row][c] for each c in check_code
"""


class DepMatrix:
    """Per-cluster dependency matrix.

    Two modes, selected per operation by the optional ``tag`` argument:

    * ``tag is None`` (default) — the legacy identity-blind path: one 8-bit
      saturating counter per ``(row, col)`` cell. Byte-identical to the original
      hardware and to ``EnableTaggedDeps=0`` in the RTL.
    * ``tag`` given — the identity-aware path (``EnableTaggedDeps=1``): each cell
      is a small tag→count scoreboard, so a "+1" raised for one edge can only be
      drained by the consumer that expects that same tag. The compiler guarantees
      at most one live edge per tag, so in hardware each slot is a 1-bit presence
      flag; we keep a count here only to mirror the saturating add/sub exactly.
    """

    def __init__(self, rows: int, cols: int):
        self.rows = rows
        self.cols = cols
        # 8-bit saturating counter per cell (untagged path)
        self.counters: list[list[int]] = [[0] * cols for _ in range(rows)]
        # tagged path: per-cell dict tag -> count (mirrors the 2^W scoreboard)
        self.tagged: list[list[dict]] = [[dict() for _ in range(cols)] for _ in range(rows)]

    def check_row(self, row: int, check_code: int, tag=None) -> bool:
        """Check if all required dependencies are satisfied (counter >= 1).

        Mirrors dep_matrix.sv:
          dep_check_result_o[r] = all(counter_q[r][c] >= 1 for c where check_code[c]=1)
        With a tag, the per-cell slot ``tbl[r][c][tag]`` must be >= 1.
        """
        for c in range(self.cols):
            if (check_code >> c) & 1:
                if tag is None:
                    if self.counters[row][c] < 1:
                        return False
                else:
                    if self.tagged[row][c].get(tag, 0) < 1:
                        return False
        return True

    def set_column(self, col: int, set_code: int, tag=None) -> bool:
        """Increment counters. Always succeeds (no overlap rejection).

        Mirrors dep_matrix.sv:
          counter_d[r][col] = counter_q[r][col] + 1  (saturating at 255)
          dep_set_ready_o = '1  (always ready)
        With a tag, the increment lands in ``tbl[r][col][tag]``.
        """
        for r in range(self.rows):
            if (set_code >> r) & 1:
                if tag is None:
                    if self.counters[r][col] < 255:
                        self.counters[r][col] += 1
                else:
                    d = self.tagged[r][col]
                    if d.get(tag, 0) < 255:
                        d[tag] = d.get(tag, 0) + 1
        return True  # Always ready

    def clear_row(self, row: int, check_code: int, tag=None):
        """Decrement counters for the checked bits.

        Mirrors dep_matrix.sv:
          counter_d[r][c] = counter_q[r][c] - 1
        With a tag, the decrement applies to ``tbl[r][c][tag]``.
        """
        for c in range(self.cols):
            if (check_code >> c) & 1:
                if tag is None:
                    if self.counters[row][c] > 0:
                        self.counters[row][c] -= 1
                else:
                    d = self.tagged[row][c]
                    if d.get(tag, 0) > 0:
                        d[tag] -= 1

    def dump_state(self) -> str:
        """Human-readable matrix state."""
        lines = []
        for r in range(self.rows):
            vals = " ".join(f"{self.counters[r][c]:3d}" for c in range(self.cols))
            lines.append(f"  Row {r} (Core {r} depends on): [{vals}]")
        return "\n".join(lines)

    def is_empty(self) -> bool:
        """Check if all entries are zero."""
        return all(
            self.counters[r][c] == 0
            for r in range(self.rows)
            for c in range(self.cols)
        )

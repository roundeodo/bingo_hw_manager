"""
Identity-aware (tagged) Dependency Matrix Model — mirrors bingo_hw_manager_dep_matrix.sv.

Each cell ``(row, col)`` is a presence-bit scoreboard over tags: bit ``t`` set
means an edge tagged ``t`` has signalled producer core ``col`` -> consumer core
``row`` and has not yet been drained. A check passes only on its own tag, so a
stray set raised by another edge sharing the same cell (which carries a
different tag) can never satisfy it. The compiler guarantees at most one live
edge per tag per cell, so a 1-bit presence flag per slot is sufficient.

Operations:
  - check_row(row, check_code, tag): True if tag is present in [row][c] for all c in check_code
  - set_column(col, set_code, tag): set presence bit [r][col][tag] for each r in set_code (always succeeds)
  - clear_row(row, check_code, tag): clear presence bit [row][c][tag] for each c in check_code
"""


class DepMatrix:
    """Per-cluster identity-aware dependency matrix.

    ``tag=None`` is coerced to tag 0, matching the RTL where an all-zero tag
    field is still a valid (shared) tag slot.
    """

    def __init__(self, rows: int, cols: int):
        self.rows = rows
        self.cols = cols
        # per-cell set of live tags (mirrors the 2^TagWidth presence bits)
        self.tags: list[list[set]] = [[set() for _ in range(cols)] for _ in range(rows)]

    def check_row(self, row: int, check_code: int, tag=None) -> bool:
        """Check if all required dependencies are satisfied.

        Mirrors dep_matrix.sv:
          dep_check_result_o[r] = all(sb_q[r][c][tag] for c where check_code[c]=1)
        """
        tag = 0 if tag is None else tag
        for c in range(self.cols):
            if (check_code >> c) & 1:
                if tag not in self.tags[row][c]:
                    return False
        return True

    def set_column(self, col: int, set_code: int, tag=None) -> bool:
        """Set presence bits. Always succeeds (no overlap rejection).

        Mirrors dep_matrix.sv:
          sb_d[r][col][tag] = 1
          dep_set_ready_o = '1  (always ready)
        """
        tag = 0 if tag is None else tag
        for r in range(self.rows):
            if (set_code >> r) & 1:
                self.tags[r][col].add(tag)
        return True  # Always ready

    def clear_row(self, row: int, check_code: int, tag=None):
        """Clear the presence bits drained by a passing check.

        Mirrors dep_matrix.sv:
          sb_q[r][c][tag] <= 0
        """
        tag = 0 if tag is None else tag
        for c in range(self.cols):
            if (check_code >> c) & 1:
                self.tags[row][c].discard(tag)

    def dump_state(self) -> str:
        """Human-readable matrix state (live tags per cell)."""
        lines = []
        for r in range(self.rows):
            vals = " ".join(
                "{" + ",".join(str(t) for t in sorted(self.tags[r][c])) + "}"
                for c in range(self.cols)
            )
            lines.append(f"  Row {r} (Core {r} depends on): [{vals}]")
        return "\n".join(lines)

    def is_empty(self) -> bool:
        """Check if no tag is live anywhere."""
        return all(
            not self.tags[r][c]
            for r in range(self.rows)
            for c in range(self.cols)
        )

"""Unit tests for the identity-aware (tagged) dependency matrix model."""

import pytest
from model.bingo_sim_dep_matrix import DepMatrix


def row_bitmask(dm, row, tag=0):
    """Convert a row to a bitmask (bit c = 1 if `tag` is live in cell [row][c])."""
    mask = 0
    for c in range(dm.cols):
        if tag in dm.tags[row][c]:
            mask |= (1 << c)
    return mask


class TestDepMatrix:
    def test_initial_state(self):
        dm = DepMatrix(4, 4)
        assert dm.is_empty()
        for r in range(4):
            assert row_bitmask(dm, r) == 0

    def test_set_column_basic(self):
        dm = DepMatrix(3, 3)
        # Set column 0 with set_code = 0b010 (row 1 depends on col 0)
        result = dm.set_column(0, 0b010)
        assert result is True
        assert row_bitmask(dm, 1) == 0b001  # bit 0 set in row 1

    def test_check_row_pass(self):
        dm = DepMatrix(3, 3)
        # Set: row 0 depends on col 1
        dm.set_column(1, 0b001)  # set_code bit 0 → row 0, col 1
        assert row_bitmask(dm, 0) == 0b010
        # Check: row 0 with check_code = 0b010 → should pass
        assert dm.check_row(0, 0b010) is True

    def test_check_row_fail(self):
        dm = DepMatrix(3, 3)
        # Row 0 is empty
        assert dm.check_row(0, 0b010) is False

    def test_check_row_partial(self):
        dm = DepMatrix(3, 3)
        # Set only col 0 bit for row 1
        dm.set_column(0, 0b010)
        # Check row 1 for both col 0 and col 1
        assert dm.check_row(1, 0b011) is False  # col 1 not set
        assert dm.check_row(1, 0b001) is True   # col 0 is set

    def test_clear_row(self):
        dm = DepMatrix(3, 3)
        dm.set_column(0, 0b010)  # row 1, col 0
        dm.set_column(1, 0b010)  # row 1, col 1
        assert row_bitmask(dm, 1) == 0b011

        # Clear only col 0 from row 1
        dm.clear_row(1, 0b001)
        assert row_bitmask(dm, 1) == 0b010  # col 1 still set

    def test_set_is_idempotent_per_tag(self):
        """Presence-bit semantics: a duplicate set on the same (cell, tag) is
        absorbed — one clear drains it. Concurrently-live duplicates must use
        distinct tags (the compiler guarantees this)."""
        dm = DepMatrix(3, 3)
        assert dm.set_column(0, 0b010) is True
        assert dm.set_column(0, 0b010) is True  # same cell, same tag → absorbed
        assert dm.check_row(1, 0b001) is True

        dm.clear_row(1, 0b001)
        assert dm.check_row(1, 0b001) is False  # a single clear drains the bit

    def test_no_overlap_different_rows(self):
        dm = DepMatrix(3, 3)
        # Set col 0, row 1
        dm.set_column(0, 0b010)
        # Set col 0, row 2 → no overlap (different row)
        result = dm.set_column(0, 0b100)
        assert result is True
        assert row_bitmask(dm, 1) == 0b001
        assert row_bitmask(dm, 2) == 0b001

    def test_accumulate_dependencies(self):
        dm = DepMatrix(4, 4)
        # Row 0 depends on col 0 and col 2
        dm.set_column(0, 0b0001)  # set row 0, col 0
        dm.set_column(2, 0b0001)  # set row 0, col 2
        assert row_bitmask(dm, 0) == 0b0101

        # Check with full dep code
        assert dm.check_row(0, 0b0101) is True
        assert dm.check_row(0, 0b0001) is True  # subset
        assert dm.check_row(0, 0b0111) is False  # col 1 not set

    def test_clear_preserves_unchecked(self):
        """Mirrors dep_matrix.sv: clear only checked bits, preserve others."""
        dm = DepMatrix(3, 3)
        dm.set_column(0, 0b001)  # row 0, col 0
        dm.set_column(1, 0b001)  # row 0, col 1
        dm.set_column(2, 0b001)  # row 0, col 2
        assert row_bitmask(dm, 0) == 0b111

        # Clear only bits 0 and 2
        dm.clear_row(0, 0b101)
        assert row_bitmask(dm, 0) == 0b010  # only col 1 remains

    def test_check_with_zero_code(self):
        """check_code=0 should always pass (no dependencies)."""
        dm = DepMatrix(3, 3)
        assert dm.check_row(0, 0) is True

    def test_dump_state(self):
        dm = DepMatrix(2, 2)
        dm.set_column(0, 0b01)
        state = dm.dump_state()
        assert "Row 0" in state
        assert "Row 1" in state


class TestDepMatrixTagged:
    """Identity awareness: a set raised for one edge's tag can only be drained
    by a consumer that expects that same tag."""

    def test_stray_tag_does_not_satisfy_check(self):
        dm = DepMatrix(3, 3)
        # A stray producer sets cell [0][1] with tag 7 (meant for another edge).
        dm.set_column(1, 0b001, tag=7)
        # A consumer on row 0 waiting on col 1 with its OWN tag 2 must NOT pass.
        assert dm.check_row(0, 0b010, tag=2) is False
        # The consumer that actually owns tag 7 passes.
        assert dm.check_row(0, 0b010, tag=7) is True

    def test_two_edges_same_cell_independent(self):
        dm = DepMatrix(3, 3)
        # Two producers feed the SAME cell (row 0, col 1) with different tags.
        dm.set_column(1, 0b001, tag=1)
        dm.set_column(1, 0b001, tag=2)
        # Each consumer drains only its own tag; clearing one leaves the other.
        assert dm.check_row(0, 0b010, tag=1) is True
        dm.clear_row(0, 0b010, tag=1)
        assert dm.check_row(0, 0b010, tag=1) is False   # tag 1 drained
        assert dm.check_row(0, 0b010, tag=2) is True    # tag 2 untouched

    def test_none_tag_is_tag_zero(self):
        dm = DepMatrix(3, 3)
        dm.set_column(0, 0b010)            # tag=None → tag 0
        assert dm.check_row(1, 0b001, tag=0) is True
        assert dm.check_row(1, 0b001) is True            # None on check side too
        assert dm.check_row(1, 0b001, tag=9) is False    # unrelated tag absent

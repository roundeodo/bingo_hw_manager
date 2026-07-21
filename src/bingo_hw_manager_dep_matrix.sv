// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Xiaoling Yi  <xiaoling.yi@kuleuven.be>
// - Yunhao Deng  <yunhao.deng@kuleuven.be>

// Identity-aware (tagged) dependency matrix.
//
// Each cell (consumer_core R, producer_core C) is a 2**TagWidth presence-bit
// scoreboard. Every set carries the producing edge's tag (dep_set_tag_i) and
// every check carries the tag it expects (dep_check_tag_i); a check passes only
// on its own tag, so a stray increment raised by another edge sharing the same
// cell (which carries a different tag) can never satisfy it. This removes the
// counter-sharing hazard of the former identity-blind saturating-counter
// matrix, where a consumer could drain an increment meant for another consumer
// and dispatch before its own input was ready (see COUNTER_SHARING_BUG.md).
//
// The mini-compiler assigns the tags and GUARANTEES at most one live edge per
// tag per cell, so a 1-bit presence flag per slot is sufficient.
//
// Operations:
//   set_column(col, set_code, tag): set presence bit [r][col][tag] for each row r in set_code
//   check_row(row, check_code, tag): true if bit [row][c][tag] is set for all c in check_code
//   clear_row(row, check_code, tag): clear bit [row][c][tag] for each c in check_code
//
// dep_set_ready_o is always 1 — no backpressure, no deadlock.

module bingo_hw_manager_dep_matrix #(
    // Number of rows (one per core — the consumer/dependent side)
    parameter int unsigned DEP_MATRIX_ROWS = 4,
    // Number of columns (one per core — the producer/signaling side)
    parameter int unsigned DEP_MATRIX_COLS = 4,
    // Tag width: a cell holds up to 2**TagWidth concurrently-live edges
    parameter int unsigned TagWidth = 4,
    /// Dependent parameters, DO NOT OVERRIDE!
    // pattern to check per row (which columns to check)
    parameter type dep_check_code_t = logic [DEP_MATRIX_COLS-1:0],
    // pattern to write per column (which rows to signal)
    parameter type dep_set_code_t   = logic [DEP_MATRIX_ROWS-1:0],
    // per-operation identity tag
    parameter type dep_tag_t        = logic [TagWidth-1:0]
) (
    input  logic   clk_i,
    input  logic   rst_ni,
    // Row check interface
    input  logic              [DEP_MATRIX_ROWS-1:0] dep_check_valid_i,
    input  dep_check_code_t   [DEP_MATRIX_ROWS-1:0] dep_check_code_i,
    input  dep_tag_t          [DEP_MATRIX_ROWS-1:0] dep_check_tag_i,
    output logic              [DEP_MATRIX_ROWS-1:0] dep_check_result_o,
    // Column set interface
    input  logic              [DEP_MATRIX_COLS-1:0] dep_set_valid_i,
    output logic              [DEP_MATRIX_COLS-1:0] dep_set_ready_o,
    input  dep_set_code_t     [DEP_MATRIX_COLS-1:0] dep_set_code_i,
    input  dep_tag_t          [DEP_MATRIX_COLS-1:0] dep_set_tag_i
);

    localparam int unsigned NumTags = 1 << TagWidth;

    // dep_set is ALWAYS ready — no overlap rejection, no backpressure
    assign dep_set_ready_o = '1;

    // Presence-bit scoreboard: one bit per (row, col, tag). The tag dimension
    // is PACKED so a cell's occupancy is a simple reduction (|sb_q[r][c]).
    // sb_q[r][c][t] = 1 means: an edge tagged `t` has signalled producer
    // core c -> consumer core r and has not yet been drained.
    logic [NumTags-1:0] sb_d [DEP_MATRIX_ROWS][DEP_MATRIX_COLS];
    logic [NumTags-1:0] sb_q [DEP_MATRIX_ROWS][DEP_MATRIX_COLS];
    logic [DEP_MATRIX_ROWS-1:0] dep_matrix_clear_row;

    // Next-state: set the (r,c,tag) presence bit for each valid set op.
    always_comb begin
        for (int r = 0; r < DEP_MATRIX_ROWS; r++) begin
            for (int c = 0; c < DEP_MATRIX_COLS; c++) begin
                for (int t = 0; t < NumTags; t++) begin
                    sb_d[r][c][t] = sb_q[r][c][t];
                end
            end
        end
        for (int c = 0; c < DEP_MATRIX_COLS; c++) begin
            if (dep_set_valid_i[c]) begin
                for (int r = 0; r < DEP_MATRIX_ROWS; r++) begin
                    if (dep_set_code_i[c][r]) begin
                        sb_d[r][c][dep_set_tag_i[c]] = 1'b1;
                    end
                end
            end
        end
    end

    // Sequential update.  A consumed tag may be reused immediately for the
    // next edge in the same cell.  In that case the clear retires the old
    // token and the simultaneous set installs the replacement token, so set
    // must win over clear.
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (int r = 0; r < DEP_MATRIX_ROWS; r++) begin
                for (int c = 0; c < DEP_MATRIX_COLS; c++) begin
                    for (int t = 0; t < NumTags; t++) begin
                        sb_q[r][c][t] <= 1'b0;
                    end
                end
            end
        end else begin
            for (int r = 0; r < DEP_MATRIX_ROWS; r++) begin
                for (int c = 0; c < DEP_MATRIX_COLS; c++) begin
                    for (int t = 0; t < NumTags; t++) begin
                        if (dep_matrix_clear_row[r] && dep_check_code_i[r][c]
                            && (t == dep_check_tag_i[r])
                            && !(dep_set_valid_i[c] && dep_set_code_i[c][r]
                                 && (dep_set_tag_i[c] == dep_check_tag_i[r]))) begin
                            sb_q[r][c][t] <= 1'b0;
                        end else begin
                            sb_q[r][c][t] <= sb_d[r][c][t];
                        end
                    end
                end
            end
        end
    end

    // Row check: every required column has this row's expected tag present.
    always_comb begin
        dep_check_result_o = '0;
        for (int r = 0; r < DEP_MATRIX_ROWS; r++) begin
            if (dep_check_valid_i[r]) begin
                automatic logic all_satisfied = 1'b1;
                for (int c = 0; c < DEP_MATRIX_COLS; c++) begin
                    if (dep_check_code_i[r][c]) begin
                        if (!sb_q[r][c][dep_check_tag_i[r]]) begin
                            all_satisfied = 1'b0;
                        end
                    end
                end
                dep_check_result_o[r] = all_satisfied;
            end
        end
    end

    // Clear rows that matched (valid and all satisfied)
    always_comb begin
        dep_matrix_clear_row = '0;
        for (int r = 0; r < DEP_MATRIX_ROWS; r++) begin
            if (dep_check_valid_i[r] && dep_check_result_o[r]) begin
                dep_matrix_clear_row[r] = 1'b1;
            end
        end
    end

endmodule

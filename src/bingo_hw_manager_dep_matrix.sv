// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Xiaoling Yi  <xiaoling.yi@kuleuven.be>
// - Yunhao Deng  <yunhao.deng@kuleuven.be>

// Counter-based dependency matrix.
//
// Each cell is an 8-bit saturating counter instead of a single bit.
// This allows multiple dep_set operations to accumulate on the same cell
// without overlap rejection, eliminating the deadlock caused by the
// interaction of overlap detection + done queue HOL blocking.
//
// Operations:
//   set_column(col, set_code): increment counter[r][col] for each row r in set_code
//   check_row(row, check_code): true if counter[row][c] >= 1 for all c in check_code
//   clear_row(row, check_code): decrement counter[row][c] by 1 for each c in check_code
//
// dep_set_ready_o is always 1 — no backpressure, no deadlock.

module bingo_hw_manager_dep_matrix #(
    // Number of rows (one per core — the consumer/dependent side)
    parameter int unsigned DEP_MATRIX_ROWS = 4,
    // Number of columns (one per core — the producer/signaling side)
    parameter int unsigned DEP_MATRIX_COLS = 4,
    // Counter width per cell (8 bits supports up to 255 pending signals)
    parameter int unsigned COUNTER_WIDTH = 8,
    /// Dependent parameters, DO NOT OVERRIDE!
    // pattern to check per row (which columns to check)
    parameter type dep_check_code_t = logic [DEP_MATRIX_COLS-1:0],
    // pattern to write per column (which rows to signal)
    parameter type dep_set_code_t   = logic [DEP_MATRIX_ROWS-1:0]
) (
    input  logic   clk_i,
    input  logic   rst_ni,
    // Phase flush: clear all counters to zero on new phase start
    input  logic   flush_i,
    // Row check interface
    input  logic              [DEP_MATRIX_ROWS-1:0] dep_check_valid_i,
    input  dep_check_code_t   [DEP_MATRIX_ROWS-1:0] dep_check_code_i,
    output logic              [DEP_MATRIX_ROWS-1:0] dep_check_result_o,
    // Column set interface
    input  logic              [DEP_MATRIX_COLS-1:0] dep_set_valid_i,
    output logic              [DEP_MATRIX_COLS-1:0] dep_set_ready_o,
    input  dep_set_code_t     [DEP_MATRIX_COLS-1:0] dep_set_code_i
);

    // Counter matrix: counter_q[row][col] counts pending signals
    logic [COUNTER_WIDTH-1:0] counter_d [DEP_MATRIX_ROWS][DEP_MATRIX_COLS];
    logic [COUNTER_WIDTH-1:0] counter_q [DEP_MATRIX_ROWS][DEP_MATRIX_COLS];
    logic [DEP_MATRIX_ROWS-1:0] dep_matrix_clear_row;

    // dep_set_ready is ALWAYS high — no overlap rejection, no backpressure
    assign dep_set_ready_o = '1;

    // Compute next-state: increment counters for set operations
    always_comb begin
        // Default: hold current state
        for (int r = 0; r < DEP_MATRIX_ROWS; r++) begin
            for (int c = 0; c < DEP_MATRIX_COLS; c++) begin
                counter_d[r][c] = counter_q[r][c];
            end
        end

        // Increment for each valid set operation
        for (int c = 0; c < DEP_MATRIX_COLS; c++) begin
            if (dep_set_valid_i[c]) begin
                for (int r = 0; r < DEP_MATRIX_ROWS; r++) begin
                    if (dep_set_code_i[c][r]) begin
                        // Saturating increment
                        if (counter_d[r][c] < {COUNTER_WIDTH{1'b1}}) begin
                            counter_d[r][c] = counter_d[r][c] + 1;
                        end
                    end
                end
            end
        end
    end

    // Sequential update: apply set increments and check decrements
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (int r = 0; r < DEP_MATRIX_ROWS; r++) begin
                for (int c = 0; c < DEP_MATRIX_COLS; c++) begin
                    counter_q[r][c] <= '0;
                end
            end
        end else if (flush_i) begin
            for (int r = 0; r < DEP_MATRIX_ROWS; r++) begin
                for (int c = 0; c < DEP_MATRIX_COLS; c++) begin
                    counter_q[r][c] <= '0;
                end
            end
        end else begin
            for (int r = 0; r < DEP_MATRIX_ROWS; r++) begin
                for (int c = 0; c < DEP_MATRIX_COLS; c++) begin
                    if (dep_matrix_clear_row[r] && dep_check_code_i[r][c]) begin
                        // Decrement by 1 for each checked column (saturate at 0)
                        // Apply on top of any set increment from this cycle
                        if (counter_d[r][c] > 0) begin
                            counter_q[r][c] <= counter_d[r][c] - 1;
                        end else begin
                            counter_q[r][c] <= '0;
                        end
                    end else begin
                        counter_q[r][c] <= counter_d[r][c];
                    end
                end
            end
        end
    end

    // Row check: all required counters >= 1
    always_comb begin
        dep_check_result_o = '0;
        for (int r = 0; r < DEP_MATRIX_ROWS; r++) begin
            if (dep_check_valid_i[r]) begin
                automatic logic all_satisfied = 1'b1;
                for (int c = 0; c < DEP_MATRIX_COLS; c++) begin
                    if (dep_check_code_i[r][c]) begin
                        if (counter_q[r][c] == '0) begin
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

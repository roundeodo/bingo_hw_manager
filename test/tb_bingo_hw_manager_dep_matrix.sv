`timescale 1ns/1ps

// Unit testbench for bingo_hw_manager_dep_matrix.
//
// Covers BOTH modes of the module:
//   * the default legacy identity-blind saturating-counter path (EnableTaggedDeps=0)
//   * the opt-in identity-aware presence-bit scoreboard (EnableTaggedDeps=1)
//
// Stimulus is driven on the negedge and the DUT registers update on the posedge,
// so a non-destructive "peek" can read the combinational result and deassert
// dep_check_valid before the next posedge (the clear only fires when a check is
// both valid and passing at a clock edge).

module tb_bingo_hw_manager_dep_matrix();

    localparam int unsigned N     = 4;
    localparam int unsigned TAG_W = 3;

    logic clk_i;
    logic rst_ni;
    int   errors = 0;

    // Packed arrays matching the module's port types (dep_code_t [N-1:0], dep_tag_t [N-1:0]).
    // -- Legacy DUT --
    logic [N-1:0]              l_check_valid,  l_check_result, l_set_valid, l_set_ready;
    logic [N-1:0][N-1:0]       l_check_code,   l_set_code;
    logic [N-1:0][TAG_W-1:0]   l_check_tag,    l_set_tag;
    // -- Tagged DUT --
    logic [N-1:0]              t_check_valid,  t_check_result, t_set_valid, t_set_ready;
    logic [N-1:0][N-1:0]       t_check_code,   t_set_code;
    logic [N-1:0][TAG_W-1:0]   t_check_tag,    t_set_tag;

    bingo_hw_manager_dep_matrix #(
        .DEP_MATRIX_ROWS(N), .DEP_MATRIX_COLS(N), .EnableTaggedDeps(1'b0), .TagWidth(TAG_W)
    ) dut_legacy (
        .clk_i, .rst_ni,
        .dep_check_valid_i(l_check_valid), .dep_check_code_i(l_check_code),
        .dep_check_tag_i(l_check_tag), .dep_check_result_o(l_check_result),
        .dep_set_valid_i(l_set_valid), .dep_set_ready_o(l_set_ready),
        .dep_set_code_i(l_set_code), .dep_set_tag_i(l_set_tag)
    );

    bingo_hw_manager_dep_matrix #(
        .DEP_MATRIX_ROWS(N), .DEP_MATRIX_COLS(N), .EnableTaggedDeps(1'b1), .TagWidth(TAG_W)
    ) dut_tagged (
        .clk_i, .rst_ni,
        .dep_check_valid_i(t_check_valid), .dep_check_code_i(t_check_code),
        .dep_check_tag_i(t_check_tag), .dep_check_result_o(t_check_result),
        .dep_set_valid_i(t_set_valid), .dep_set_ready_o(t_set_ready),
        .dep_set_code_i(t_set_code), .dep_set_tag_i(t_set_tag)
    );

    initial clk_i = 0;
    always #5 clk_i = ~clk_i;

    // ---- Legacy helpers ----
    task automatic l_set(input int col, input logic [N-1:0] rows);
        @(negedge clk_i); l_set_valid = '0; l_set_valid[col] = 1'b1; l_set_code[col] = rows;
        @(posedge clk_i); @(negedge clk_i); l_set_valid = '0; l_set_code[col] = '0;
    endtask
    task automatic l_consume(input int row, input logic [N-1:0] cols);
        @(negedge clk_i); l_check_valid = '0; l_check_valid[row] = 1'b1; l_check_code[row] = cols;
        @(posedge clk_i); @(negedge clk_i); l_check_valid = '0; l_check_code[row] = '0;
    endtask
    task automatic l_peek(input int row, input logic [N-1:0] cols, output logic res);
        l_check_valid = '0; l_check_valid[row] = 1'b1; l_check_code[row] = cols; #1;
        res = l_check_result[row]; l_check_valid[row] = 1'b0; l_check_code[row] = '0;
    endtask

    // ---- Tagged helpers ----
    task automatic t_set(input int col, input logic [N-1:0] rows, input logic [TAG_W-1:0] tag);
        @(negedge clk_i); t_set_valid = '0; t_set_valid[col] = 1'b1; t_set_code[col] = rows; t_set_tag[col] = tag;
        @(posedge clk_i); @(negedge clk_i); t_set_valid = '0; t_set_code[col] = '0;
    endtask
    task automatic t_consume(input int row, input logic [N-1:0] cols, input logic [TAG_W-1:0] tag);
        @(negedge clk_i); t_check_valid = '0; t_check_valid[row] = 1'b1; t_check_code[row] = cols; t_check_tag[row] = tag;
        @(posedge clk_i); @(negedge clk_i); t_check_valid = '0; t_check_code[row] = '0;
    endtask
    task automatic t_peek(input int row, input logic [N-1:0] cols, input logic [TAG_W-1:0] tag, output logic res);
        t_check_valid = '0; t_check_valid[row] = 1'b1; t_check_code[row] = cols; t_check_tag[row] = tag; #1;
        res = t_check_result[row]; t_check_valid[row] = 1'b0; t_check_code[row] = '0;
    endtask

    task automatic expect_eq(input logic got, input logic exp, input string msg);
        if (got !== exp) begin errors++; $error("FAIL: %s (got=%0b exp=%0b)", msg, got, exp); end
        else $display("ok: %s = %0b", msg, got);
    endtask

    logic res;
    initial begin
        l_check_valid='0; l_set_valid='0; l_check_code='0; l_set_code='0; l_check_tag='0; l_set_tag='0;
        t_check_valid='0; t_set_valid='0; t_check_code='0; t_set_code='0; t_check_tag='0; t_set_tag='0;
        rst_ni = 1'b0; repeat (2) @(posedge clk_i); rst_ni = 1'b1; @(negedge clk_i);

        // ============ Legacy (identity-blind counter) ============
        $display("--- legacy: ready is always high (counter design, no overlap rejection) ---");
        expect_eq(&l_set_ready, 1'b1, "legacy dep_set_ready all high");

        $display("--- legacy: set / check / accumulate / clear ---");
        l_set(1, 4'b0010);                                   // counter[1][1] = 1
        l_peek(1, 4'b0010, res); expect_eq(res, 1'b1, "legacy row1 col1 set");
        l_set(1, 4'b0010);                                   // counter[1][1] = 2 (accumulate)
        l_consume(1, 4'b0010);                               // -> 1
        l_peek(1, 4'b0010, res); expect_eq(res, 1'b1, "legacy still set after 1 of 2 clears");
        l_consume(1, 4'b0010);                               // -> 0
        l_peek(1, 4'b0010, res); expect_eq(res, 1'b0, "legacy cleared after 2nd clear");

        $display("--- legacy: subset check across columns ---");
        l_set(0, 4'b0001); l_set(2, 4'b0001);                // row0: col0 and col2
        l_peek(0, 4'b0101, res); expect_eq(res, 1'b1, "legacy row0 {col0,col2} set");
        l_peek(0, 4'b0111, res); expect_eq(res, 1'b0, "legacy row0 {col0,col1,col2} -> col1 missing");

        // ============ Tagged (identity-aware scoreboard) ============
        $display("--- tagged: a stray tag cannot satisfy a check for a different tag ---");
        t_set(1, 4'b0001, 3'd7);                             // row0,col1 tagged 7 (stray)
        t_peek(0, 4'b0010, 3'd2, res); expect_eq(res, 1'b0, "tagged row0 col1 tag2 (stray tag7) -> miss");
        t_peek(0, 4'b0010, 3'd7, res); expect_eq(res, 1'b1, "tagged row0 col1 tag7 -> hit");

        $display("--- tagged: two edges on the same cell are independent per tag ---");
        t_set(1, 4'b0001, 3'd1);                             // row0,col1 tag1
        t_set(1, 4'b0001, 3'd2);                             // row0,col1 tag2 (same cell)
        t_peek(0, 4'b0010, 3'd1, res); expect_eq(res, 1'b1, "tagged tag1 present");
        t_consume(0, 4'b0010, 3'd1);                         // drain tag1 only
        t_peek(0, 4'b0010, 3'd1, res); expect_eq(res, 1'b0, "tagged tag1 drained");
        t_peek(0, 4'b0010, 3'd2, res); expect_eq(res, 1'b1, "tagged tag2 untouched");

        if (errors == 0) $display("All dep_matrix tests passed");
        else             $error("%0d dep_matrix test(s) FAILED", errors);
        #10 $finish;
    end

    initial begin #100000; $fatal("TIMEOUT"); end

endmodule

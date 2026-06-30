`timescale 1ns/1ps

module tb_bingo_hw_manager_dep_matrix();

    // testbench parameters (match DUT default)
    localparam int unsigned N = 4;
    localparam int unsigned INPUT_WIDTH = (N > 1) ? $clog2(N) : 1;

    // clock / reset
    logic clk_i;
    logic rst_ni;
    logic flush_i;

    // DUT signals (match new DUT interface)
    logic [N-1:0]                      dep_check_valid_i;
    logic [N-1:0]                      dep_check_result_o;
    logic [N-1:0]                      dep_set_valid_i;
    logic [N-1:0]                      dep_set_ready_o;
    // arrays of vectors: indexed by row/column, each element is N-bit wide
    logic [N-1:0]                      dep_check_code_i [N-1:0];
    logic [N-1:0]                      dep_set_code_i   [N-1:0];

    // helper variables
    logic [INPUT_WIDTH-1:0] col;
    logic [N-1:0]           pattern;
    logic [N-1:0]           expected_row;

    // Instantiate DUT
    bingo_hw_manager_dep_matrix #(
        .DEP_MATRIX_ROWS(N),
        .DEP_MATRIX_COLS(N)
    ) dut (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .flush_i(flush_i),
        .dep_check_valid_i(dep_check_valid_i),
        .dep_check_code_i(dep_check_code_i),
        .dep_check_result_o(dep_check_result_o),
        .dep_set_valid_i(dep_set_valid_i),
        .dep_set_ready_o(dep_set_ready_o),
        .dep_set_code_i(dep_set_code_i)
    );

    // Clock generator: 10 ns period
    initial clk_i = 0;
    always #5 clk_i = ~clk_i;

    // Task: drive a column write (synchronous in DUT)
    // Updated to handle ready handshake
    task automatic set_column(input int unsigned col_in,
                              input logic [N-1:0] code);
    begin
        // prepare arrays: clear all entries, then assign selected column entry
        for (int i = 0; i < N; i++) begin
            dep_set_code_i[i] = '0;
        end

        // apply at clock edge
        @(posedge clk_i);
        dep_set_code_i[col_in]  <= code;
        dep_set_valid_i         <= {N{1'b0}};
        dep_set_valid_i[col_in] <= 1'b1;

        // Wait for ready
        wait (dep_set_ready_o[col_in] == 1'b1);

        // allow DUT to sample on next posedge (synchronous update)
        @(posedge clk_i);
        #1;

        // clear signals on next posedge
        
        dep_set_valid_i         <= '0;
        for (int i = 0; i < N; i++) dep_set_code_i[i] <= '0;
    end
    endtask

    // Task: check a single row (combinational result) - NON DESTRUCTIVE
    task automatic check_row(input int unsigned row,
                             input logic [N-1:0] expected_code,
                             input bit expected_result);
    begin
        // prepare all check_code entries to zero
        for (int i = 0; i < N; i++) dep_check_code_i[i] = '0;

        @(posedge clk_i);
        dep_check_code_i[row]   <= expected_code;
        dep_check_valid_i       <= '0; // Non-destructive

        // allow combinational result to settle within the same cycle
        #1;
        if (dep_check_result_o[row] !== expected_result) begin
            $error("CHECK FAILED: row=%0d expected_code=%b expected_res=%0d got_res=%0d",
                   row, expected_code, expected_result, dep_check_result_o[row]);
        end else begin
            $display("CHECK OK: row=%0d code=%b result=%0d", row, expected_code, dep_check_result_o[row]);
        end
    end
    endtask

    // Task: Consume/Clear a dependency (fires valid)
    task automatic consume_row(input int unsigned row,
                               input logic [N-1:0] code);
    begin
        for (int i = 0; i < N; i++) dep_check_code_i[i] = '0;
        @(posedge clk_i);
        dep_check_code_i[row] <= code;
        dep_check_valid_i     <= '0;
        dep_check_valid_i[row] <= 1'b1;
        
        @(posedge clk_i); // Turn off valid after one cycle
        dep_check_valid_i[row] <= 1'b0;
        dep_check_code_i[row]  <= '0;
    end
    endtask

    // Test sequence
    initial begin
        // initialize inputs and valids
        for (int i = 0; i < N; i++) begin
            dep_check_code_i[i] = {N{1'b0}}; // Initialize to all zeros
            dep_set_code_i[i]   = {N{1'b0}}; // Initialize to all zeros
        end
        dep_check_valid_i = {N{1'b0}}; // Initialize to all zeros
        dep_set_valid_i   = {N{1'b0}}; // Initialize to all zeros
        flush_i           = 1'b0;
        col               = '0;        // Initialize to zero
        pattern           = '0;        // Initialize to zero
        expected_row      = '0;        // Initialize to zero

        // apply reset (active low)
        rst_ni = 1'b0;
        repeat (2) @(posedge clk_i);
        rst_ni = 1'b1;
        @(posedge clk_i);
        #1;

        $display("RESET released, expect all rows to be zero");

        // After reset DUT matrix should be zeros => checking row with zero code should pass
        for (int i = 0; i < N; i++) begin
            check_row(i, {N{1'b0}}, 1'b1); // row == 0 should match code 0 -> result 1
        end

        // Set column 1 to pattern 4'b1010 (bit index => row index)
        col     = 1;
        pattern = 4'b1010;
        $display("Setting column %0d with pattern %b", col, pattern);
        set_column(col, pattern);

        // After the set_column sequence the matrix has been updated. Verify each row
        $display("Verifying matrix contents after first set...");
        for (int i = 0; i < N; i++) begin
            // build expected_row: a vector with a '1' at position 'col' if pattern[i] is 1
            expected_row = '0;
            if (pattern[i])
                expected_row[col] = 1'b1;

            // check correct code -> expect match (1)
            // Note: We use the SUBSET check logic now.
            // Row i is [0 1 0 0] if pattern[i] is 1, else 0.
            // Check code expected_row is [0 1 0 0].
            // (Mat & Check) == Check -> ( [0 1 0 0] & [0 1 0 0] ) == [0 1 0 0] -> OK.
            
            // To properly test the subset logic, we should set another bit and see if it passes.
            check_row(i, expected_row, 1'b1);
        end

        // Test Overlap / Ready Logic
        $display("Testing Overlap/Ready logic...");
        // Try to set the same pattern again on the same column.
        // Matrix already has 1s where pattern has 1s.
        // Ready should be LOW.
        @(posedge clk_i);
        dep_set_code_i[col]  <= pattern;
        dep_set_valid_i[col] <= 1'b1;
        #1;
        if (dep_set_ready_o[col] !== 1'b0) begin
             $error("READY CHECK FAILED: Expected ready=0 for overlap, got %b", dep_set_ready_o[col]);
        end else begin
             $display("READY CHECK OK: Overlap correctly detected.");
        end
        @(posedge clk_i);
        dep_set_valid_i[col] <= 1'b0;


        // Test Subset Check Logic
        $display("Testing Subset Check logic...");
        // Set another bit in row 1, column 2.
        // Row 1 currently has column 1 set (pattern[1]=1 in 4'b1010). Row 1 = [0 1 0 0].
        // We add col 2.
        col = 2;
        pattern = 4'b0010; // Only row 1 affected
        set_column(col, pattern);
        
        // Now Row 1 should have col 1 AND col 2 set. Row 1 = [0 1 1 0].
        // Check only for col 1. Should pass.
        // Check code: [0 1 0 0]
        // Matrix:     [0 1 1 0]
        // (Mat & Check) = [0 1 0 0] == Check -> Pass.
        check_row(1, 4'b0010, 1'b1); // Checking for col 1 (bit 1)

        // Check only for col 2. Should pass.
        check_row(1, 4'b0100, 1'b1); // Checking for col 2 (bit 2)

        // Check for col 1 AND col 2. Should pass.
        check_row(1, 4'b0110, 1'b1); 
        
        // Check for col 3 (not set). Should fail.
        check_row(1, 4'b1000, 1'b0);

        // Check for col 1 AND col 3. Should fail.
        check_row(1, 4'b1010, 1'b0);

        // Test Clearing Logic
        $display("Testing Clearing Check logic...");
        // At this point, Row 1 has col 1 and col 2 set. Row 1 = [0 1 1 0].
        // We will consume (clear) col 1 (bit 1).
        consume_row(1, 4'b0010);

        // Now Row 1 should be [0 1 0 0] (bit 1 cleared).
        // Check col 1 -> Should fail (already consumed)
        check_row(1, 4'b0010, 1'b0);
        
        // Check col 2 -> Should still pass (not consumed yet)
        check_row(1, 4'b0100, 1'b1);
        
        // Check col 1 | col 2 combined -> Should fail because col 1 is missing
        check_row(1, 4'b0110, 1'b0);

        // Consume col 2
        consume_row(1, 4'b0100);
        
        // Now Row 1 should be [0 0 0 0] (empty)
        check_row(1, 4'b0100, 1'b0);
        check_row(1, 4'b0110, 1'b0);


        $display("All tests passed");
        #10 $finish;
    end

    // Timeout safety
    initial begin
        #10000;
        $fatal("TIMEOUT");
    end

endmodule

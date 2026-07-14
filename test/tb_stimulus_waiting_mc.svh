// =============================================================================
// Cross-cluster waiting-queue head-of-line regression
//
// Task 1 blocks on cluster0/core0.  Task 2 is independent but uses core0 on
// cluster1 and is submitted behind task 1.  The dependency release is delayed
// by 200 cycles.  Task 2 must complete before that release is submitted.
// =============================================================================

localparam int unsigned EXPECTED_TASK_COUNT     = 2;
localparam int unsigned DEADLOCK_THRESHOLD      = 2000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t blocked_c0 = pack_normal_task(
    1'b0, 16'd1, 0, 0, 0,
    1'b1, bingo_hw_manager_dep_code_t'(2'b10),
    1'b0, 1'b0, 0, 0, '0
);

bingo_hw_manager_task_desc_full_t independent_c1 = pack_normal_task(
    1'b0, 16'd2, 0, 1, 0,
    1'b0, '0,
    1'b0, 1'b0, 0, 0, '0
);

// Dummy set runs on producer column core1 and sets consumer row core0.
bingo_hw_manager_task_desc_full_t release_c0 = pack_dummy_set_task(
    1'b1, 16'd3, 0, 0, 1,
    1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(2'b01)
);

initial begin : chip0_push_sequence
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    @(posedge clk_i);
    task_queue_master[0].reset();
    done_queue_master[0].reset();

    $display("[TRACE] %0t,TASK_PUSHED,0,0,0,1", $time);
    task_queue_master[0].write(task_queue_base[0], '0, blocked_c0, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,0,1,0,2", $time);
    task_queue_master[0].write(task_queue_base[0], '0, independent_c1, '1, resp);

    repeat (200) @(posedge clk_i);
    if (!task_completed_bitmap[2]) begin
        $fatal(1, "cluster1/core0 task was blocked by cluster0/core0 waiting head");
    end
    if (task_completed_bitmap[1]) begin
        $fatal(1, "blocked cluster0/core0 task completed before dependency release");
    end

    $display("[TRACE] %0t,TASK_PUSHED,0,0,1,3", $time);
    task_queue_master[0].write(task_queue_base[0], '0, release_c0, '1, resp);
end

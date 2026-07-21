// =============================================================================
// Cross-cluster waiting-queue head-of-line regression
//
// Ten tasks block on cluster1/core0, exceeding the historical waiting depth of
// eight.  An independent cluster0/core0 task is submitted behind them.  It must
// complete before any cluster1 dependency release is submitted; otherwise a
// full destination waiting queue is blocking the single global ingress head.
// =============================================================================

localparam int unsigned BLOCKED_TASK_COUNT      = 10;
localparam int unsigned INDEPENDENT_TASK_ID     = BLOCKED_TASK_COUNT + 1;
localparam int unsigned EXPECTED_TASK_COUNT     = BLOCKED_TASK_COUNT + 1;
localparam int unsigned DEADLOCK_THRESHOLD      = 2000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t independent_c0 = pack_normal_task(
    1'b0, bingo_hw_manager_task_id_t'(INDEPENDENT_TASK_ID), 0, 0, 0,
    1'b0, '0,
    1'b0, 1'b0, 0, 0, '0
);

initial begin : chip0_push_sequence
    automatic axi_pkg::resp_t resp;
    automatic bingo_hw_manager_task_desc_full_t task_desc;
    wait (rst_ni);
    @(posedge clk_i);
    task_queue_master[0].reset();
    done_queue_master[0].reset();

    for (int unsigned i = 0; i < BLOCKED_TASK_COUNT; i++) begin
        task_desc = pack_normal_task(
            1'b0, bingo_hw_manager_task_id_t'(i + 1), 0, 1, 0,
            1'b1, bingo_hw_manager_dep_code_t'(2'b10),
            1'b0, 1'b0, 0, 0, '0
        );
        $display("[TRACE] %0t,TASK_PUSHED,0,1,0,%0d", $time, i + 1);
        task_queue_master[0].write(task_queue_base[0], '0, task_desc, '1, resp);
    end

    $display(
        "[TRACE] %0t,TASK_PUSHED,0,0,0,%0d", $time,
        INDEPENDENT_TASK_ID);
    task_queue_master[0].write(
        task_queue_base[0], '0, independent_c0, '1, resp);

    repeat (200) @(posedge clk_i);
    if (!task_completed_bitmap[INDEPENDENT_TASK_ID]) begin
        $fatal(1,
            "independent cluster0/core0 task was blocked by full cluster1/core0 waiting queue");
    end
    for (int unsigned i = 1; i <= BLOCKED_TASK_COUNT; i++) begin
        if (task_completed_bitmap[i]) begin
            $fatal(1,
                "blocked cluster1/core0 task %0d completed before dependency release", i);
        end
    end

    // Dummy set runs on producer column core1 and sets consumer row core0.
    for (int unsigned i = 0; i < BLOCKED_TASK_COUNT; i++) begin
        task_desc = pack_dummy_set_task(
            1'b1, bingo_hw_manager_task_id_t'(100 + i), 0, 1, 1,
            1'b1, 1'b0, 0, 1, bingo_hw_manager_dep_code_t'(2'b01)
        );
        $display("[TRACE] %0t,TASK_PUSHED,0,1,1,%0d", $time, 100 + i);
        task_queue_master[0].write(task_queue_base[0], '0, task_desc, '1, resp);
        wait (task_completed_bitmap[i + 1]);
    end
end

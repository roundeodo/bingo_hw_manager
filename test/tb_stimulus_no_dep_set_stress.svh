// More tasks than DoneQueueDepth on every physical resource exercise
// completion retirement rather than merely proving that a device submitted a
// done record. Interleaving the descriptors also covers ingress routing.
localparam int unsigned TASKS_PER_RESOURCE      = 40;
localparam int unsigned EXPECTED_TASK_COUNT     =
    TASKS_PER_RESOURCE * NUM_CLUSTERS_PER_CHIPLET * NUM_CORES_PER_CLUSTER;
localparam int unsigned DEADLOCK_THRESHOLD      = 5000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

initial begin : chip0_push_sequence
    automatic axi_pkg::resp_t resp;
    automatic bingo_hw_manager_task_desc_full_t task_desc;

    wait (rst_ni);
    @(posedge clk_i);
    task_queue_master[0].reset();
    done_queue_master[0].reset();

    for (int round = 0; round < TASKS_PER_RESOURCE; round++) begin
        for (int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster++) begin
            for (int core = 0; core < NUM_CORES_PER_CLUSTER; core++) begin
                // Task IDs are scoped by the physical (cluster, core) queue.
                // Reuse 1..40 on each resource so the stress does not overflow
                // the protocol task-id field while still exceeding queue depth.
                automatic int task_id = round + 1;
                task_desc = pack_normal_task(
                    2'b00, bingo_hw_manager_task_id_t'(task_id), 0,
                    bingo_hw_manager_assigned_cluster_id_t'(cluster),
                    bingo_hw_manager_assigned_core_id_t'(core),
                    1'b0, '0,
                    1'b0, 1'b0, 0, 0, '0
                );
                $display("[TRACE] %0t,TASK_PUSHED,0,%0d,%0d,%0d",
                         $time, cluster, core, task_id);
                task_queue_master[0].write(
                    task_queue_base[0], '0, task_desc, '1, resp);
                #50;
            end
        end
        // Keep one task per physical resource in flight. This isolates done
        // retirement from unrelated upstream FIFO-capacity effects: the old
        // RTL stalls when its 32 stale done entries fill; the fixed RTL can
        // complete all 40 rounds.
        wait (completed_task_count >=
              (round + 1) * NUM_CLUSTERS_PER_CHIPLET * NUM_CORES_PER_CLUSTER);
    end
end

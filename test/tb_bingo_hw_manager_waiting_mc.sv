// Verifies that dependency waiting is independent for each (core, cluster).
`define TB_STIMULUS_FILE "tb_stimulus_waiting_mc.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 2
`define TB_NUM_CORES_PER_CLUSTER 2

module tb_bingo_hw_manager_waiting_mc;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule

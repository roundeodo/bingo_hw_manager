// Verifies that completions retire for normal tasks without outgoing deps.
`define TB_STIMULUS_FILE "tb_stimulus_no_dep_set_stress.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 2
`define TB_NUM_CORES_PER_CLUSTER 2

module tb_bingo_hw_manager_no_dep_set_stress;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule

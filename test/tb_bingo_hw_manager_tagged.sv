// =============================================================================
// Bingo HW Manager Tagged Testbench — identity-aware deps end-to-end
// =============================================================================
// Same harness as tb_bingo_hw_manager_top, but defines BINGO_TAGGED_DEPS so the
// DUT is instantiated with EnableTaggedDeps=1, and drives a stimulus that puts
// two distinct-tag edges on one dep-matrix cell. `undef at the end so the macro
// cannot leak into any testbench compiled after this one.
// =============================================================================
`define BINGO_TAGGED_DEPS
`define TB_STIMULUS_FILE "tb_stimulus_tagged.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3

module tb_bingo_hw_manager_tagged;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule

`undef BINGO_TAGGED_DEPS

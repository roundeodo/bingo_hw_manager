// =============================================================================
// Bingo HW Manager Testbench Harness
// =============================================================================
// Reusable testbench infrastructure for bingo_hw_manager_top.
// This file is `included inside a module wrapper that defines:
//   `TB_NUM_CHIPLET
//   `TB_NUM_CLUSTERS_PER_CHIPLET
//   `TB_NUM_CORES_PER_CLUSTER
//   `TB_STIMULUS_FILE  (path to stimulus .svh file)
//
// The stimulus file must define:
//   localparam int unsigned EXPECTED_TASK_COUNT = ...;
//   localparam int unsigned DEADLOCK_THRESHOLD  = ...;  (cycles without progress => deadlock)
//   localparam int unsigned DEP_MATRIX_LOG_INTERVAL = ...; (0 = disabled)
//   Task descriptor declarations (using pack_*_task helpers)
//   Per-chiplet push sequences (initial blocks)
// =============================================================================

`timescale 1ns/1ps
`include "axi/typedef.svh"
`include "axi/assign.svh"
`include "axi/port.svh"

import axi_pkg::*;
import axi_test::*;

// ---------------------------------------------------------------------------
// Local configuration (from defines)
// ---------------------------------------------------------------------------
localparam int unsigned READY_AND_DONE_QUEUE_INTERFACE_TYPE = 1; // 1: CSR Req/Resp
localparam int unsigned TASK_QUEUE_TYPE = 0;                     // 0: AXI Lite Slave
localparam int unsigned NUM_CHIPLET                = `TB_NUM_CHIPLET;
localparam int unsigned NUM_CLUSTERS_PER_CHIPLET   = `TB_NUM_CLUSTERS_PER_CHIPLET;
localparam int unsigned NUM_CORES_PER_CLUSTER      = `TB_NUM_CORES_PER_CLUSTER;
localparam int unsigned READY_AGENT_NUM = NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET;

localparam time CyclTime = 10ns;
localparam time ApplTime =  2ns;
localparam time TestTime =  8ns;

localparam int unsigned ChipIdWidth = 8;
localparam int unsigned HOST_AW = 48;
localparam int unsigned HOST_DW = 64;
localparam int unsigned DEV_AW  = 48;
localparam int unsigned DEV_DW  = 32;

typedef logic [HOST_AW-1:0]   host_axi_lite_addr_t;
typedef logic [HOST_DW-1:0]   host_axi_lite_data_t;
typedef logic [HOST_DW/8-1:0] host_axi_lite_strb_t;
typedef logic [DEV_AW-1:0]    device_axi_lite_addr_t;
typedef logic [DEV_DW-1:0]    device_axi_lite_data_t;
typedef logic [DEV_DW/8-1:0]  device_axi_lite_strb_t;
typedef logic [ChipIdWidth-1:0] chip_id_t;

localparam host_axi_lite_addr_t TASK_QUEUE_BASE      = 48'h1000_0000;
localparam host_axi_lite_addr_t DONE_QUEUE_BASE      = 48'h2000_0000;
localparam host_axi_lite_addr_t READY_QUEUE_BASE     = 48'h3000_0000;
localparam host_axi_lite_addr_t READY_QUEUE_STRIDE   = 48'h1000;
localparam host_axi_lite_addr_t H2H_DONE_QUEUE_BASE  = 48'h4000_0000;

// ---------------------------------------------------------------------------
// Type definitions
// ---------------------------------------------------------------------------
localparam int unsigned TaskIdWidth = 12;

typedef logic [1:0]                                                  bingo_hw_manager_task_type_t;
typedef logic [TaskIdWidth-1:0]                                      bingo_hw_manager_task_id_t;
typedef logic [ChipIdWidth-1:0]                                      bingo_hw_manager_assigned_chiplet_id_t;
typedef logic [cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET)-1:0] bingo_hw_manager_assigned_cluster_id_t;
typedef logic [cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER)-1:0]    bingo_hw_manager_assigned_core_id_t;
typedef logic [NUM_CORES_PER_CLUSTER-1:0]                            bingo_hw_manager_dep_code_t;
// Per-edge identity tag (must mirror bingo_hw_manager_top exactly).
localparam int unsigned DEP_TAG_WIDTH = 3;
typedef logic [DEP_TAG_WIDTH-1:0]                                    bingo_hw_manager_dep_tag_t;
// Opt-in: a testbench that `define`s BINGO_TAGGED_DEPS before including this
// harness instantiates the DUT with identity-aware dep tracking enabled.
`ifdef BINGO_TAGGED_DEPS
localparam bit ENABLE_TAGGED_DEPS = 1'b1;
`else
localparam bit ENABLE_TAGGED_DEPS = 1'b0;
`endif

typedef struct packed {
    bingo_hw_manager_dep_tag_t                   dep_check_tag;
    bingo_hw_manager_dep_code_t                  dep_check_code;
    logic                                        dep_check_en;
} bingo_hw_manager_dep_check_info_t;

typedef struct packed {
    bingo_hw_manager_dep_tag_t                   dep_set_tag;
    bingo_hw_manager_dep_code_t                  dep_set_code;
    bingo_hw_manager_assigned_cluster_id_t       dep_set_cluster_id;
    bingo_hw_manager_assigned_chiplet_id_t       dep_set_chiplet_id;
    logic                                        dep_set_all_chiplet;
    logic                                        dep_set_en;
} bingo_hw_manager_dep_set_info_t;

typedef struct packed {
    bingo_hw_manager_dep_set_info_t              dep_set_info;
    bingo_hw_manager_dep_check_info_t            dep_check_info;
    bingo_hw_manager_assigned_core_id_t          assigned_core_id;
    bingo_hw_manager_assigned_cluster_id_t       assigned_cluster_id;
    bingo_hw_manager_assigned_chiplet_id_t       assigned_chiplet_id;
    bingo_hw_manager_task_id_t                   task_id;
    bingo_hw_manager_task_type_t                 task_type;
    logic                                        cond_exec_en;
    logic [4:0]                                  cond_exec_group_id;
    logic                                        cond_exec_invert;
} bingo_hw_manager_task_desc_t;

localparam int unsigned TaskDescWidth = $bits(bingo_hw_manager_task_desc_t);
localparam int unsigned ReservedBitsForTaskDesc = HOST_DW - TaskDescWidth;

if (TaskDescWidth > HOST_DW) begin : gen_task_desc_width_check
    initial begin
        $error("Task Descriptor width (%0d) exceeds Host AXI Lite Data Width (%0d)!", TaskDescWidth, HOST_DW);
        $finish;
    end
end

typedef struct packed {
    logic [ReservedBitsForTaskDesc-1:0]          reserved_bits;
    bingo_hw_manager_dep_set_info_t              dep_set_info;
    bingo_hw_manager_dep_check_info_t            dep_check_info;
    bingo_hw_manager_assigned_core_id_t          assigned_core_id;
    bingo_hw_manager_assigned_cluster_id_t       assigned_cluster_id;
    bingo_hw_manager_assigned_chiplet_id_t       assigned_chiplet_id;
    bingo_hw_manager_task_id_t                   task_id;
    bingo_hw_manager_task_type_t                 task_type;
    logic                                        cond_exec_en;
    logic [4:0]                                  cond_exec_group_id;
    logic                                        cond_exec_invert;
} bingo_hw_manager_task_desc_full_t;

typedef struct packed {
    bingo_hw_manager_assigned_cluster_id_t     assigned_cluster_id;
    bingo_hw_manager_assigned_core_id_t        assigned_core_id;
    bingo_hw_manager_task_id_t                 task_id;
} bingo_hw_manager_done_info_t;

localparam int unsigned DoneInfoWidth = $bits(bingo_hw_manager_done_info_t);
localparam int unsigned ReservedBitsForDoneInfo = DEV_DW - DoneInfoWidth;

if (DoneInfoWidth > DEV_DW) begin : gen_done_info_width_check
    initial begin
        $error("Done Info width (%0d) exceeds Device AXI Lite Data Width (%0d)!", DoneInfoWidth, DEV_DW);
        $finish;
    end
end

typedef struct packed {
    logic [ReservedBitsForDoneInfo-1:0]        reserved_bits;
    bingo_hw_manager_assigned_cluster_id_t     assigned_cluster_id;
    bingo_hw_manager_assigned_core_id_t        assigned_core_id;
    bingo_hw_manager_task_id_t                 task_id;
} bingo_hw_manager_done_info_full_t;

// CSR types
typedef struct packed {
    device_axi_lite_addr_t   addr;
    device_axi_lite_data_t   data;
    logic                    write;
} csr_req_t;

typedef struct packed {
    device_axi_lite_data_t   data;
} csr_rsp_t;

// ---------------------------------------------------------------------------
// Helper functions
// ---------------------------------------------------------------------------
function automatic int flat_id(
    input int chip_id,
    input int cluster_id,
    input int core_id
);
    return chip_id * NUM_CLUSTERS_PER_CHIPLET * NUM_CORES_PER_CLUSTER +
           cluster_id * NUM_CORES_PER_CLUSTER +
           core_id;
endfunction

function automatic bingo_hw_manager_task_desc_full_t pack_normal_task(
    input bingo_hw_manager_task_type_t           task_type,
    input bingo_hw_manager_task_id_t             task_id,
    input bingo_hw_manager_assigned_chiplet_id_t assigned_chiplet_id,
    input bingo_hw_manager_assigned_cluster_id_t assigned_cluster_id,
    input bingo_hw_manager_assigned_core_id_t    assigned_core_id,
    input logic                                  dep_check_en,
    input bingo_hw_manager_dep_code_t            dep_check_code,
    input logic                                  dep_set_en,
    input logic                                  dep_set_all_chiplet,
    input bingo_hw_manager_assigned_chiplet_id_t dep_set_chiplet_id,
    input bingo_hw_manager_assigned_cluster_id_t dep_set_cluster_id,
    input bingo_hw_manager_dep_code_t            dep_set_code,
    input bingo_hw_manager_dep_tag_t             dep_check_tag = '0,
    input bingo_hw_manager_dep_tag_t             dep_set_tag = '0
);
    bingo_hw_manager_task_desc_full_t tmp;
    tmp.task_type                        = task_type;
    tmp.task_id                          = task_id;
    tmp.assigned_chiplet_id              = assigned_chiplet_id;
    tmp.assigned_cluster_id              = assigned_cluster_id;
    tmp.assigned_core_id                 = assigned_core_id;
    tmp.dep_check_info.dep_check_en      = dep_check_en;
    tmp.dep_check_info.dep_check_code    = dep_check_code;
    tmp.dep_check_info.dep_check_tag     = dep_check_tag;
    tmp.dep_set_info.dep_set_en          = dep_set_en;
    tmp.dep_set_info.dep_set_all_chiplet = dep_set_all_chiplet;
    tmp.dep_set_info.dep_set_chiplet_id  = dep_set_chiplet_id;
    tmp.dep_set_info.dep_set_cluster_id  = dep_set_cluster_id;
    tmp.dep_set_info.dep_set_code        = dep_set_code;
    tmp.dep_set_info.dep_set_tag         = dep_set_tag;
    tmp.cond_exec_en                     = 1'b0;
    tmp.cond_exec_group_id               = 5'b0;
    tmp.cond_exec_invert                 = 1'b0;
    tmp.reserved_bits                    = '0;
    return tmp;
endfunction

function automatic bingo_hw_manager_task_desc_full_t pack_dummy_check_task(
    input bingo_hw_manager_task_type_t           task_type,
    input bingo_hw_manager_task_id_t             task_id,
    input bingo_hw_manager_assigned_chiplet_id_t assigned_chiplet_id,
    input bingo_hw_manager_assigned_cluster_id_t assigned_cluster_id,
    input bingo_hw_manager_assigned_core_id_t    assigned_core_id,
    input logic                                  dep_check_en,
    input bingo_hw_manager_dep_code_t            dep_check_code,
    input bingo_hw_manager_dep_tag_t             dep_check_tag = '0
);
    bingo_hw_manager_task_desc_full_t tmp;
    tmp.task_type                        = task_type;
    tmp.task_id                          = task_id;
    tmp.assigned_chiplet_id              = assigned_chiplet_id;
    tmp.assigned_cluster_id              = assigned_cluster_id;
    tmp.assigned_core_id                 = assigned_core_id;
    tmp.dep_check_info.dep_check_en      = 1'b1;
    tmp.dep_check_info.dep_check_code    = dep_check_code;
    tmp.dep_check_info.dep_check_tag     = dep_check_tag;
    tmp.dep_set_info                     = '0;
    tmp.cond_exec_en                     = 1'b0;
    tmp.cond_exec_group_id               = 5'b0;
    tmp.cond_exec_invert                 = 1'b0;
    tmp.reserved_bits                    = '0;
    return tmp;
endfunction

function automatic bingo_hw_manager_task_desc_full_t pack_dummy_set_task(
    input bingo_hw_manager_task_type_t           task_type,
    input bingo_hw_manager_task_id_t             task_id,
    input bingo_hw_manager_assigned_chiplet_id_t assigned_chiplet_id,
    input bingo_hw_manager_assigned_cluster_id_t assigned_cluster_id,
    input bingo_hw_manager_assigned_core_id_t    assigned_core_id,
    input logic                                  dep_set_en,
    input logic                                  dep_set_all_chiplet,
    input bingo_hw_manager_assigned_chiplet_id_t dep_set_chiplet_id,
    input bingo_hw_manager_assigned_cluster_id_t dep_set_cluster_id,
    input bingo_hw_manager_dep_code_t            dep_set_code,
    input bingo_hw_manager_dep_tag_t             dep_set_tag = '0
);
    bingo_hw_manager_task_desc_full_t tmp;
    tmp.task_type                        = task_type;
    tmp.task_id                          = task_id;
    tmp.assigned_chiplet_id              = assigned_chiplet_id;
    tmp.assigned_cluster_id              = assigned_cluster_id;
    tmp.assigned_core_id                 = assigned_core_id;
    tmp.dep_check_info                   = '0;
    tmp.dep_set_info.dep_set_en          = dep_set_en;
    tmp.dep_set_info.dep_set_all_chiplet = dep_set_all_chiplet;
    tmp.dep_set_info.dep_set_chiplet_id  = dep_set_chiplet_id;
    tmp.dep_set_info.dep_set_cluster_id  = dep_set_cluster_id;
    tmp.dep_set_info.dep_set_code        = dep_set_code;
    tmp.dep_set_info.dep_set_tag         = dep_set_tag;
    tmp.cond_exec_en                     = 1'b0;
    tmp.cond_exec_group_id               = 5'b0;
    tmp.cond_exec_invert                 = 1'b0;
    tmp.reserved_bits                    = '0;
    return tmp;
endfunction

// ---------------------------------------------------------------------------
// Clock / Reset
// ---------------------------------------------------------------------------
logic clk_i;
logic rst_ni;

clk_rst_gen #(
    .ClkPeriod    ( CyclTime ),
    .RstClkCycles ( 5        )
) i_clk_gen (
    .clk_o  ( clk_i  ),
    .rst_no ( rst_ni )
);

// ---------------------------------------------------------------------------
// AXI-Lite type aliases
// ---------------------------------------------------------------------------
`AXI_LITE_TYPEDEF_ALL(host, host_axi_lite_addr_t, host_axi_lite_data_t, host_axi_lite_strb_t)
`AXI_LITE_TYPEDEF_ALL(dev,  device_axi_lite_addr_t, device_axi_lite_data_t, device_axi_lite_strb_t)

// ---------------------------------------------------------------------------
// Interface instantiation
// ---------------------------------------------------------------------------
AXI_LITE_DV #(.AXI_ADDR_WIDTH(HOST_AW), .AXI_DATA_WIDTH(HOST_DW))
    local_task_if [NUM_CHIPLET-1:0] (.clk_i(clk_i));

AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW), .AXI_DATA_WIDTH(DEV_DW))
    local_done_if [NUM_CHIPLET-1:0] (.clk_i(clk_i));

AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW), .AXI_DATA_WIDTH(DEV_DW))
    local_ready_if [NUM_CHIPLET*NUM_CLUSTERS_PER_CHIPLET*NUM_CORES_PER_CLUSTER-1:0] (.clk_i(clk_i));

// Task queue wires
host_req_t  [NUM_CHIPLET-1:0] local_task_queue_req;
host_resp_t [NUM_CHIPLET-1:0] local_task_queue_resp;

for (genvar chiplet_idx = 0; chiplet_idx < NUM_CHIPLET; chiplet_idx++) begin
    `AXI_LITE_ASSIGN_TO_REQ   (local_task_queue_req[chiplet_idx],  local_task_if[chiplet_idx]);
    `AXI_LITE_ASSIGN_FROM_RESP(local_task_if[chiplet_idx],         local_task_queue_resp[chiplet_idx]);
end

// Done queue wires
dev_req_t  [NUM_CHIPLET-1:0] local_done_queue_req;
dev_resp_t [NUM_CHIPLET-1:0] local_done_queue_resp;

for (genvar chiplet_idx = 0; chiplet_idx < NUM_CHIPLET; chiplet_idx++) begin
    `AXI_LITE_ASSIGN_TO_REQ   (local_done_queue_req[chiplet_idx],  local_done_if[chiplet_idx]);
    `AXI_LITE_ASSIGN_FROM_RESP(local_done_if[chiplet_idx],         local_done_queue_resp[chiplet_idx]);
end

// Ready queue wires
dev_req_t  [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] local_ready_queue_req  [NUM_CHIPLET];
dev_resp_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] local_ready_queue_resp [NUM_CHIPLET];

for (genvar chiplet_idx = 0; chiplet_idx < NUM_CHIPLET; chiplet_idx++) begin
    for (genvar cluster_idx = 0; cluster_idx < NUM_CLUSTERS_PER_CHIPLET; cluster_idx++) begin
        for (genvar core_idx = 0; core_idx < NUM_CORES_PER_CLUSTER; core_idx++) begin
            `AXI_LITE_ASSIGN_TO_REQ   (local_ready_queue_req[chiplet_idx][core_idx][cluster_idx],
                                       local_ready_if[flat_id(chiplet_idx, cluster_idx, core_idx)]);
            `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if[flat_id(chiplet_idx, cluster_idx, core_idx)],
                                       local_ready_queue_resp[chiplet_idx][core_idx][cluster_idx]);
        end
    end
end

// CSR interfaces
csr_req_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] csr_req       [NUM_CHIPLET];
logic     [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] csr_req_valid  [NUM_CHIPLET];
logic     [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] csr_req_ready  [NUM_CHIPLET];
csr_rsp_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] csr_resp       [NUM_CHIPLET];
logic     [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] csr_resp_valid [NUM_CHIPLET];
logic     [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] csr_resp_ready [NUM_CHIPLET];

// ---------------------------------------------------------------------------
// H2H Chiplet Xbar
// ---------------------------------------------------------------------------
localparam axi_pkg::xbar_cfg_t H2HAxiLiteXbarCfg = '{
    NoSlvPorts:         NUM_CHIPLET,
    NoMstPorts:         NUM_CHIPLET,
    MaxSlvTrans:        4,
    MaxMstTrans:        4,
    FallThrough:        0,
    LatencyMode:        axi_pkg::CUT_ALL_PORTS,
    PipelineStages:     0,
    AxiIdWidthSlvPorts: 0,
    AxiIdUsedSlvPorts:  0,
    UniqueIds:          0,
    AxiAddrWidth:       HOST_AW,
    AxiDataWidth:       HOST_DW,
    NoAddrRules:        NUM_CHIPLET
};

typedef struct packed {
    logic [31:0] idx;
    logic [47:0] start_addr;
    logic [47:0] end_addr;
} xbar_rule_48_t;

host_req_t     [NUM_CHIPLET-1:0] h2h_axi_lite_xbar_in_req;
host_resp_t    [NUM_CHIPLET-1:0] h2h_axi_lite_xbar_in_resp;
host_req_t     [NUM_CHIPLET-1:0] h2h_axi_lite_xbar_out_req;
host_resp_t    [NUM_CHIPLET-1:0] h2h_axi_lite_xbar_out_resp;
xbar_rule_48_t [NUM_CHIPLET-1:0] H2HAxiLiteXbarAddrmap;

for (genvar i = 0; i < NUM_CHIPLET; i++) begin
    assign H2HAxiLiteXbarAddrmap[i] = '{
        idx:        i,
        start_addr: {8'(i), 40'h0},
        end_addr:   {8'(i), 40'h8000_0000}
    };
end

axi_lite_xbar #(
    .Cfg        ( H2HAxiLiteXbarCfg ),
    .aw_chan_t  ( host_aw_chan_t     ),
    .w_chan_t   ( host_w_chan_t      ),
    .b_chan_t   ( host_b_chan_t      ),
    .ar_chan_t  ( host_ar_chan_t     ),
    .r_chan_t   ( host_r_chan_t      ),
    .axi_req_t ( host_req_t         ),
    .axi_resp_t( host_resp_t        ),
    .rule_t    ( xbar_rule_48_t     )
) i_axi_lite_xbar_h2h_chiplet (
    .clk_i                  ( clk_i                       ),
    .rst_ni                 ( rst_ni                      ),
    .test_i                 ( '0                          ),
    .slv_ports_req_i        ( h2h_axi_lite_xbar_in_req    ),
    .slv_ports_resp_o       ( h2h_axi_lite_xbar_in_resp   ),
    .mst_ports_req_o        ( h2h_axi_lite_xbar_out_req   ),
    .mst_ports_resp_i       ( h2h_axi_lite_xbar_out_resp  ),
    .addr_map_i             ( H2HAxiLiteXbarAddrmap       ),
    .en_default_mst_port_i  ( '0                          ),
    .default_mst_port_i     ( '0                          )
);

// ---------------------------------------------------------------------------
// AXI Drivers
// ---------------------------------------------------------------------------
typedef axi_test::axi_lite_rand_master #(
    .AW ( HOST_AW ), .DW ( HOST_DW ),
    .TA ( ApplTime ), .TT ( TestTime ),
    .MIN_ADDR ( 48'h0 ), .MAX_ADDR ( {8'(NUM_CHIPLET-1), 40'h8000_0000} ),
    .MAX_READ_TXNS  ( 10 ), .MAX_WRITE_TXNS ( 10 )
) host_rand_lite_master_t;

typedef axi_test::axi_lite_rand_master #(
    .AW ( DEV_AW ), .DW ( DEV_DW ),
    .TA ( ApplTime ), .TT ( TestTime ),
    .MIN_ADDR ( 48'h0 ), .MAX_ADDR ( {8'(NUM_CHIPLET-1), 40'h8000_0000} ),
    .MAX_READ_TXNS  ( 10 ), .MAX_WRITE_TXNS ( 10 )
) dev_rand_lite_master_t;

host_rand_lite_master_t task_queue_master [NUM_CHIPLET];
for (genvar chiplet_idx = 0; chiplet_idx < NUM_CHIPLET; chiplet_idx++) begin : gen_task_queue_master
    initial begin
        automatic string name = $sformatf("task_queue_master_chiplet%0d", chiplet_idx);
        task_queue_master[chiplet_idx] = new(local_task_if[chiplet_idx], name);
        task_queue_master[chiplet_idx].reset();
    end
end

dev_rand_lite_master_t done_queue_master [NUM_CHIPLET];
for (genvar chiplet_idx = 0; chiplet_idx < NUM_CHIPLET; chiplet_idx++) begin : gen_done_queue_master
    initial begin
        automatic string name = $sformatf("done_queue_master_chiplet%0d", chiplet_idx);
        done_queue_master[chiplet_idx] = new(local_done_if[chiplet_idx], name);
        done_queue_master[chiplet_idx].reset();
    end
end

dev_rand_lite_master_t ready_queue_master [NUM_CHIPLET*NUM_CLUSTERS_PER_CHIPLET*NUM_CORES_PER_CLUSTER];
for (genvar chiplet_idx = 0; chiplet_idx < NUM_CHIPLET; chiplet_idx++) begin : gen_ready_queue_master
    for (genvar cluster_idx = 0; cluster_idx < NUM_CLUSTERS_PER_CHIPLET; cluster_idx++) begin
        for (genvar core_idx = 0; core_idx < NUM_CORES_PER_CLUSTER; core_idx++) begin
            localparam int RQ_IDX = chiplet_idx * NUM_CLUSTERS_PER_CHIPLET * NUM_CORES_PER_CLUSTER
                                  + cluster_idx * NUM_CORES_PER_CLUSTER
                                  + core_idx;
            initial begin
                automatic string name = $sformatf("ready_queue_master_chip%0d_cl%0d_co%0d",
                                                  chiplet_idx, cluster_idx, core_idx);
                ready_queue_master[RQ_IDX] = new(local_ready_if[RQ_IDX], name);
                ready_queue_master[RQ_IDX].reset();
            end
        end
    end
end

// ---------------------------------------------------------------------------
// Chip IDs and task queue base addresses
// ---------------------------------------------------------------------------
chip_id_t [NUM_CHIPLET-1:0] chip_id;
for (genvar i = 0; i < NUM_CHIPLET; i++) begin
    assign chip_id[i] = chip_id_t'(i);
end

host_axi_lite_addr_t [NUM_CHIPLET-1:0] task_queue_base;
for (genvar i = 0; i < NUM_CHIPLET; i++) begin
    assign task_queue_base[i] = {chip_id[i], TASK_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]};
end

// ---------------------------------------------------------------------------
// DARTS Tier 1: Per-chiplet CERF control signals (driven by stimulus)
// ---------------------------------------------------------------------------
logic [NUM_CHIPLET-1:0]      cerf_write_en;
logic [31:0]                 cerf_write_data [NUM_CHIPLET];

initial begin
    cerf_write_en = '0;
    for (int i = 0; i < NUM_CHIPLET; i++) cerf_write_data[i] = '0;
end

task automatic cerf_write_bitmask(input int chip, input logic [31:0] mask);
    cerf_write_data[chip] <= mask;
    cerf_write_en[chip]   <= 1'b1;
    @(posedge clk_i);
    cerf_write_en[chip]   <= 1'b0;
    @(posedge clk_i);
endtask

// ---------------------------------------------------------------------------
// DUT Instantiation
// ---------------------------------------------------------------------------
for (genvar chiplet_idx = 0; chiplet_idx < NUM_CHIPLET; chiplet_idx++) begin : gen_dut
    bingo_hw_manager_top #(
        .READY_AND_DONE_QUEUE_INTERFACE_TYPE ( READY_AND_DONE_QUEUE_INTERFACE_TYPE ),
        .TASK_QUEUE_TYPE                     ( TASK_QUEUE_TYPE                     ),
        .NUM_CORES_PER_CLUSTER               ( NUM_CORES_PER_CLUSTER               ),
        .NUM_CLUSTERS_PER_CHIPLET            ( NUM_CLUSTERS_PER_CHIPLET            ),
        .EnableTaggedDeps                    ( ENABLE_TAGGED_DEPS                  ),
        .DepTagWidth                         ( DEP_TAG_WIDTH                       ),
        .HostAxiLiteAddrWidth                ( HOST_AW                             ),
        .HostAxiLiteDataWidth                ( HOST_DW                             ),
        .DeviceAxiLiteAddrWidth              ( DEV_AW                              ),
        .DeviceAxiLiteDataWidth              ( DEV_DW                              ),
        .host_axi_lite_req_t                 ( host_req_t                          ),
        .host_axi_lite_resp_t                ( host_resp_t                         ),
        .device_axi_lite_req_t               ( dev_req_t                           ),
        .device_axi_lite_resp_t              ( dev_resp_t                          ),
        .csr_req_t                           ( csr_req_t                           ),
        .csr_rsp_t                           ( csr_rsp_t                           )
    ) i_dut (
        .clk_i                                ( clk_i                                                       ),
        .rst_ni                               ( rst_ni                                                      ),
        .chip_id_i                            ( chip_id[chiplet_idx]                                        ),
        .task_queue_base_addr_i               ( {chip_id[chiplet_idx], TASK_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]}  ),
        .task_queue_axi_lite_req_i            ( local_task_queue_req[chiplet_idx]                            ),
        .task_queue_axi_lite_resp_o           ( local_task_queue_resp[chiplet_idx]                           ),
        .task_list_base_addr_i                ( '0                                                          ),
        .num_task_i                           ( '0                                                          ),
        .bingo_hw_manager_start_i             ( '0                                                          ),
        .bingo_hw_manager_reset_start_o       ( /* unused */                                                ),
        .bingo_hw_manager_reset_start_en_o    ( /* unused */                                                ),
        .task_queue_axi_lite_req_o            ( /* unused */                                                ),
        .task_queue_axi_lite_resp_i           ( '0                                                          ),
        .chiplet_mailbox_base_addr_i          ( {chip_id[chiplet_idx], H2H_DONE_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]} ),
        .to_remote_chiplet_axi_lite_req_o     ( h2h_axi_lite_xbar_in_req[chiplet_idx]                       ),
        .to_remote_chiplet_axi_lite_resp_i    ( h2h_axi_lite_xbar_in_resp[chiplet_idx]                      ),
        .from_remote_axi_lite_req_i           ( h2h_axi_lite_xbar_out_req[chiplet_idx]                      ),
        .from_remote_axi_lite_resp_o          ( h2h_axi_lite_xbar_out_resp[chiplet_idx]                     ),
        .done_queue_base_addr_i               ( {chip_id[chiplet_idx], DONE_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]}  ),
        .done_queue_axi_lite_req_i            ( local_done_queue_req[chiplet_idx]                            ),
        .done_queue_axi_lite_resp_o           ( local_done_queue_resp[chiplet_idx]                           ),
        .ready_queue_base_addr_i              ( {chip_id[chiplet_idx], READY_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]} ),
        .ready_queue_axi_lite_req_i           ( local_ready_queue_req[chiplet_idx]                           ),
        .ready_queue_axi_lite_resp_o          ( local_ready_queue_resp[chiplet_idx]                          ),
        .csr_req_i                            ( csr_req[chiplet_idx]                                        ),
        .csr_req_valid_i                      ( csr_req_valid[chiplet_idx]                                  ),
        .csr_req_ready_o                      ( csr_req_ready[chiplet_idx]                                  ),
        .csr_rsp_o                            ( csr_resp[chiplet_idx]                                       ),
        .csr_rsp_valid_o                      ( csr_resp_valid[chiplet_idx]                                 ),
        .csr_rsp_ready_i                      ( csr_resp_ready[chiplet_idx]                                 ),
        .bingo_hw_manager_enable_idle_pm_i    ( '0                                                          ),
        .bingo_hw_manager_idle_power_level_i  ( '0                                                          ),
        .bingo_hw_manager_normal_power_level_i( '0                                                          ),
        .bingo_hw_manager_pm_base_addr_i      ( '0                                                          ),
        .bingo_hw_manager_core_power_domain_i ( '0                                                          ),
        .pm_axi_lite_req_o                    ( /* unused */                                                ),
        .pm_axi_lite_resp_i                   ( '0                                                          ),
        // DARTS Tier 1: CERF interface (stimulus files can drive these)
        .cerf_write_en_i                      ( cerf_write_en[chiplet_idx]                                   ),
        .cerf_write_data_i                    ( cerf_write_data[chiplet_idx]                                 ),
        .cerf_state_o                         ( /* read-back, unused in standalone TB */                     ),
        // DARTS: Load monitor
        .load_total_pending_o                 ( /* unused */                                                )
    );
end

// ---------------------------------------------------------------------------
// CSR Helper Tasks
// ---------------------------------------------------------------------------
task automatic reset_csr_interface();
    for (int chip = 0; chip < NUM_CHIPLET; chip++) begin
        for (int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster++) begin
            for (int core = 0; core < NUM_CORES_PER_CLUSTER; core++) begin
                csr_req[chip][core][cluster]        <= '0;
                csr_req_valid[chip][core][cluster]  <= 1'b0;
                csr_resp_ready[chip][core][cluster] <= 1'b0;
            end
        end
    end
    @(posedge clk_i);
endtask

task automatic csr_read(
    input int chip, input int cluster, input int core,
    input device_axi_lite_addr_t addr,
    output device_axi_lite_data_t data
);
    csr_req[chip][core][cluster].addr  <= addr;
    csr_req[chip][core][cluster].write <= 1'b0;
    csr_req[chip][core][cluster].data  <= '0;
    csr_req_valid[chip][core][cluster] <= 1'b1;
    csr_resp_ready[chip][core][cluster] <= 1'b1;

    while (csr_req_ready[chip][core][cluster] !== 1'b1) @(posedge clk_i);
    while (csr_resp_valid[chip][core][cluster] !== 1'b1) @(posedge clk_i);

    data = csr_resp[chip][core][cluster].data;
    csr_req_valid[chip][core][cluster]  <= 1'b0;
    csr_resp_ready[chip][core][cluster] <= 1'b0;
endtask

task automatic csr_write(
    input int chip, input int cluster, input int core,
    input device_axi_lite_addr_t addr,
    input device_axi_lite_data_t data
);
    csr_req[chip][core][cluster].addr  <= addr;
    csr_req[chip][core][cluster].write <= 1'b1;
    csr_req[chip][core][cluster].data  <= data;
    csr_req_valid[chip][core][cluster] <= 1'b1;
    csr_resp_ready[chip][core][cluster] <= 1'b0;

    while (csr_req_ready[chip][core][cluster] !== 1'b1) @(posedge clk_i);
    csr_req_valid[chip][core][cluster] <= 1'b0;
endtask

// ---------------------------------------------------------------------------
// Progress Tracking
// ---------------------------------------------------------------------------
int unsigned completed_task_count = 0;
int unsigned last_progress_count  = 0;
logic [4095:0] task_completed_bitmap = '0;

// Per-chiplet done queue lock (for AXI-Lite mode)
logic [NUM_CHIPLET-1:0] done_queue_lock;

// ---------------------------------------------------------------------------
// Core Worker Task (with structured trace logging)
// ---------------------------------------------------------------------------
task automatic core_worker(
    input chip_id_t chip,
    input int cluster,
    input int core
);
    automatic axi_pkg::resp_t                  resp = '0;
    automatic device_axi_lite_data_t           data = '0;
    automatic device_axi_lite_addr_t           data_addr;
    automatic device_axi_lite_data_t           status = '1;
    automatic device_axi_lite_addr_t           status_addr;
    automatic device_axi_lite_addr_t           done_addr;
    automatic bingo_hw_manager_done_info_full_t done_info = '0;
    automatic device_axi_lite_data_t           done_payload = '0;
    automatic int idx = flat_id(chip, cluster, core);

    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth]   = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth]   = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE
        + device_axi_lite_addr_t'((core + cluster * NUM_CORES_PER_CLUSTER) * READY_QUEUE_STRIDE)
        + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE
        + device_axi_lite_addr_t'((core + cluster * NUM_CORES_PER_CLUSTER) * READY_QUEUE_STRIDE)
        + 32'd8;

    forever begin
        if (READY_AND_DONE_QUEUE_INTERFACE_TYPE == 0) begin
            // AXI Lite mode: poll status, then read
            ready_queue_master[idx].read(status_addr, '0, status, resp);
            repeat (5) @(posedge clk_i);
            if (status[0]) begin
                repeat (10) @(posedge clk_i);
                continue;
            end
            ready_queue_master[idx].read(data_addr, '0, data, resp);
        end else begin
            // CSR mode: blocking read from FIFO
            csr_read(chip, cluster, core, '0, data);
        end

        // Task dispatched
        $display("[TRACE] %0t,TASK_DISPATCHED,%0d,%0d,%0d,%0d",
                 $time, chip, cluster, core, data[TaskIdWidth-1:0]);

        // Simulate work with random delay
        repeat ($urandom_range(20, 50)) @(posedge clk_i);

        // Compose done info
        done_info.task_id            = data[TaskIdWidth-1:0];
        done_info.assigned_cluster_id = bingo_hw_manager_assigned_cluster_id_t'(cluster);
        done_info.assigned_core_id    = bingo_hw_manager_assigned_core_id_t'(core);
        done_info.reserved_bits       = '0;
        done_payload = device_axi_lite_data_t'(done_info);

        if (READY_AND_DONE_QUEUE_INTERFACE_TYPE == 0) begin
            wait (!done_queue_lock[chip]);
            done_queue_lock[chip] = 1'b1;
            done_queue_master[chip].write(done_addr, '0, done_payload, {DEV_DW/8{1'b1}}, resp);
            repeat ($urandom_range(20, 50)) @(posedge clk_i);
            done_queue_lock[chip] = 1'b0;
        end else begin
            csr_write(chip, cluster, core, '0, done_payload);
            repeat ($urandom_range(10, 20)) @(posedge clk_i);
        end

        // Record completion
        $display("[TRACE] %0t,TASK_DONE,%0d,%0d,%0d,%0d",
                 $time, chip, cluster, core, data[TaskIdWidth-1:0]);
        completed_task_count++;
        task_completed_bitmap[data[TaskIdWidth-1:0]] = 1'b1;
    end
endtask

// ---------------------------------------------------------------------------
// Ready Queue Pollers — fork core_worker for all cores
// ---------------------------------------------------------------------------
initial begin : ready_queue_pollers
    reset_csr_interface();
    wait (rst_ni);
    repeat (5) @(posedge clk_i);
    done_queue_lock = '0;

    for (int chip_idx = 0; chip_idx < NUM_CHIPLET; chip_idx++) begin
        for (int cluster_idx = 0; cluster_idx < NUM_CLUSTERS_PER_CHIPLET; cluster_idx++) begin
            for (int core_idx = 0; core_idx < NUM_CORES_PER_CLUSTER; core_idx++) begin
                fork
                    automatic int c  = chip_idx;
                    automatic int cl = cluster_idx;
                    automatic int co = core_idx;
                    core_worker(c, cl, co);
                join_none
            end
        end
    end
end

// ---------------------------------------------------------------------------
// Signal export from generate blocks — allows runtime indexing for monitoring
// ---------------------------------------------------------------------------
logic [7:0] dep_counter_state [NUM_CHIPLET][NUM_CLUSTERS_PER_CHIPLET][NUM_CORES_PER_CLUSTER][NUM_CORES_PER_CLUSTER];
logic [NUM_CORES_PER_CLUSTER-1:0] waiting_empty_export [NUM_CHIPLET];
logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_empty_export [NUM_CHIPLET];
logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_empty_export [NUM_CHIPLET];

for (genvar gi = 0; gi < NUM_CHIPLET; gi++) begin : gen_sig_export
    for (genvar gj = 0; gj < NUM_CLUSTERS_PER_CHIPLET; gj++) begin : gen_cl_export
        for (genvar gr = 0; gr < NUM_CORES_PER_CLUSTER; gr++) begin : gen_row_export
            for (genvar gc = 0; gc < NUM_CORES_PER_CLUSTER; gc++) begin : gen_col_export
                // The dep-matrix internals differ per mode: gen_legacy has a
                // saturating counter per cell; gen_tagged has a presence-bit
                // scoreboard. Probe whichever exists (monitor/dump only).
                if (ENABLE_TAGGED_DEPS) begin : g_tag_probe
                    assign dep_counter_state[gi][gj][gr][gc] =
                        8'(|gen_dut[gi].i_dut.gen_dep_matrix[gj].i_dep_matrix.gen_tagged.sb_q[gr][gc]);
                end else begin : g_legacy_probe
                    assign dep_counter_state[gi][gj][gr][gc] =
                        gen_dut[gi].i_dut.gen_dep_matrix[gj].i_dep_matrix.gen_legacy.counter_q[gr][gc];
                end
            end
        end
    end
    assign waiting_empty_export[gi] = gen_dut[gi].i_dut.waiting_dep_check_queue_empty;
    assign ready_empty_export[gi]   = gen_dut[gi].i_dut.ready_queue_empty;
    assign checkout_empty_export[gi] = gen_dut[gi].i_dut.checkout_queue_empty;
end

// ---------------------------------------------------------------------------
// Dependency Matrix Monitor — human-readable dump
// ---------------------------------------------------------------------------
task automatic dump_dep_matrix_state();
    $display("  ===== DEPENDENCY MATRIX STATE (counter-based) =====");
    for (int chip = 0; chip < NUM_CHIPLET; chip++) begin
        for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
            $display("  Chiplet %0d, Cluster %0d:", chip, cl);
            for (int r = 0; r < NUM_CORES_PER_CLUSTER; r++) begin
                $write("    Row %0d (Core %0d): [", r, r);
                for (int c = 0; c < NUM_CORES_PER_CLUSTER; c++) begin
                    if (c > 0) $write(", ");
                    $write("%0d", dep_counter_state[chip][cl][r][c]);
                end
                $display("]");
            end
        end
    end
endtask

task automatic dump_queue_state();
    $display("  ===== QUEUE STATE =====");
    for (int chip = 0; chip < NUM_CHIPLET; chip++) begin
        $display("  Chiplet %0d:", chip);
        for (int core = 0; core < NUM_CORES_PER_CLUSTER; core++) begin
            $display("    Core %0d: waiting_dep_check = %s",
                core,
                waiting_empty_export[chip][core] ? "EMPTY" : "HAS_TASKS");
            for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
                $display("      Cluster %0d: ready_q = %s, checkout_q = %s",
                    cl,
                    ready_empty_export[chip][core][cl] ? "EMPTY" : "HAS_TASKS",
                    checkout_empty_export[chip][core][cl] ? "EMPTY" : "HAS_TASKS");
            end
        end
    end
endtask

// ---------------------------------------------------------------------------
// Include stimulus file EARLY — defines EXPECTED_TASK_COUNT, DEADLOCK_THRESHOLD,
// DEP_MATRIX_LOG_INTERVAL, task descriptors, and push sequences.
// ---------------------------------------------------------------------------
`include `TB_STIMULUS_FILE

// ---------------------------------------------------------------------------
// Deadlock Detection Watchdog
// ---------------------------------------------------------------------------
initial begin : deadlock_watchdog
    wait (rst_ni);
    repeat (100) @(posedge clk_i);
    forever begin
        repeat (DEADLOCK_THRESHOLD) @(posedge clk_i);
        if (completed_task_count == EXPECTED_TASK_COUNT) begin
            // Already done, let completion_monitor handle it
            break;
        end
        if (completed_task_count == last_progress_count) begin
            $display("");
            $display("+===============================================+");
            $display("|           DEADLOCK DETECTED                   |");
            $display("+===============================================+");
            $display("  No progress for %0d cycles at time %0t", DEADLOCK_THRESHOLD, $time);
            $display("  Completed: %0d / %0d tasks", completed_task_count, EXPECTED_TASK_COUNT);
            $display("  -----------------------------------------------");
            $display("  Uncompleted tasks:");
            for (int t = 1; t <= EXPECTED_TASK_COUNT; t++)
                if (!task_completed_bitmap[t])
                    $display("    Task %0d: NOT completed", t);
            $display("  -----------------------------------------------");
            dump_dep_matrix_state();
            dump_queue_state();
            $display("+===============================================+");
            $display("|           SIMULATION ABORTED                  |");
            $display("+===============================================+");
            $fatal(1, "Deadlock detected: no progress for %0d cycles", DEADLOCK_THRESHOLD);
        end
        last_progress_count = completed_task_count;
    end
end

// ---------------------------------------------------------------------------
// Completion Monitor
// ---------------------------------------------------------------------------
initial begin : completion_monitor
    wait (completed_task_count == EXPECTED_TASK_COUNT);
    repeat (50) @(posedge clk_i);
    $display("");
    $display("+===============================================+");
    $display("|           SIMULATION PASSED                   |");
    $display("+===============================================+");
    $display("  All %0d tasks completed at time %0t", EXPECTED_TASK_COUNT, $time);
    $display("  -----------------------------------------------");
    $display("  Final dependency matrix state (should be all zeros):");
    dump_dep_matrix_state();
    $finish;
end

// ---------------------------------------------------------------------------
// Periodic Dependency Matrix Snapshot Logger
// ---------------------------------------------------------------------------
initial begin : dep_matrix_periodic_logger
    if (DEP_MATRIX_LOG_INTERVAL > 0) begin
        wait (rst_ni);
        forever begin
            repeat (DEP_MATRIX_LOG_INTERVAL) @(posedge clk_i);
            if (completed_task_count < EXPECTED_TASK_COUNT) begin
                $display("");
                $display("[DEP_MATRIX_SNAPSHOT] t=%0t, completed=%0d/%0d",
                         $time, completed_task_count, EXPECTED_TASK_COUNT);
                dump_dep_matrix_state();
            end
        end
    end
end

// ---------------------------------------------------------------------------
// Stimulus file was included above (before deadlock watchdog)
// ---------------------------------------------------------------------------

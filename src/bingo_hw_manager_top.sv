// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Xiaoling Yi  <xiaoling.yi@kuleuven.be>
// - Yunhao Deng  <yunhao.deng@kuleuven.be>

module bingo_hw_manager_top #(
    // Top-level parameters can be defined here
    parameter int unsigned READY_AND_DONE_QUEUE_INTERFACE_TYPE = 1, // 1: CSR Req/Resp 0: Default AXi Lite Slave
    parameter int unsigned TASK_QUEUE_TYPE = 1,                     // 1: AXI Lite Master 0: Default AXI Lite Slave
    parameter int unsigned NUM_CORES_PER_CLUSTER = 4,
    parameter int unsigned NUM_CLUSTERS_PER_CHIPLET = 2,
    // Dedicated host DVFS doorbell bit inside the shared CLINT MSIP word. Injected from
    // the HeMAiA level (occamygen hw_manager_ipi_idx) and forwarded to the PM so it is
    // never hardcoded; must match HW_MANAGER_DVFS_MSIP_BIT / occamy_soc.sv ipi_i.
    parameter int unsigned HOST_DVFS_MSIP_BIT = 3,
    parameter int unsigned ChipIdWidth = 8,
    parameter int unsigned TaskIdWidth = 12,
    // Identity-aware dependency tracking (per-edge tags), DEFAULT ON. The
    // mini-compiler's per-edge tags are plumbed to the tagged dep-matrix scoreboard
    // so a consumer drains only ITS producer's increment. Set to 0 for the legacy
    // identity-blind matrix (no counter-sharing mitigation; the SW serialize
    // workaround has been removed -- tags supersede it).
    parameter bit          EnableTaggedDeps = 1'b1,
    parameter int unsigned DepTagWidth = 4,
    // AXI interface types
    // The task queue holds tasks to be scheduled to the devices
    // Host writes the task queue via 64bit AXI Lite
    parameter int unsigned HostAxiLiteAddrWidth = 48,
    parameter int unsigned HostAxiLiteDataWidth = 64,
    // Device writes the done queue via 32bit AXI Lite
    parameter int unsigned DeviceAxiLiteAddrWidth = 48,
    parameter int unsigned DeviceAxiLiteDataWidth = 32,
    // AXI Lite Interface types for host and device
    parameter type host_axi_lite_req_t = logic,
    parameter type host_axi_lite_resp_t = logic,
    parameter type device_axi_lite_req_t = logic,
    parameter type device_axi_lite_resp_t = logic,
    parameter type csr_req_t = logic,
    parameter type csr_rsp_t = logic,
    // FIFO Depths
    parameter int unsigned TaskQueueDepth = 32,
    parameter int unsigned ChipletDoneQueueDepth = 32,
    parameter int unsigned DoneQueueDepth = 32,
    parameter int unsigned CheckoutQueueDepth = 8,
    parameter int unsigned ReadyQueueDepth = 8,
    // Address Offsets
    parameter int unsigned ReadyQueueAddrOffset = 4096,
    // Dependent parameters, DO NOT OVERRIDE!
    parameter type chip_id_t = logic [ChipIdWidth-1:0],
    parameter type host_axi_lite_addr_t = logic [HostAxiLiteAddrWidth-1:0],
    parameter type host_axi_lite_data_t = logic [HostAxiLiteDataWidth-1:0],
    parameter type device_axi_lite_addr_t = logic [DeviceAxiLiteAddrWidth-1:0],
    parameter type device_axi_lite_data_t = logic [DeviceAxiLiteDataWidth-1:0]
) (
    /// Clock
    input logic clk_i,
    /// Asynchronous reset, active low
    input logic rst_ni,
    /// Chip ID for multi-chip addressing
    input chip_id_t chip_id_i,
    /// Interface to the system
    // For the task queue, we have two interfaces:
    // 1. Host writes to the task queue via 64bit AXI Lite interface
    // Host -----> Task Queue
    // Here this queue holds all the tasks to be scheduled to the devices
    // Hence this is a slave AXI Lite interface
    input  host_axi_lite_addr_t                 task_queue_base_addr_i,
    input  host_axi_lite_req_t                  task_queue_axi_lite_req_i,
    output host_axi_lite_resp_t                 task_queue_axi_lite_resp_o,
    // 2. The Hw Manager issues the read request to the address specified by the host via the following inputs
    // Hence this is a master AXI Lite interface
    input host_axi_lite_addr_t                  task_list_base_addr_i, // The task list base address specified by the host
    input device_axi_lite_data_t                num_task_i,            // The number of tasks specified by the host
    // Control signals to start the HW Manager
    // The start signals are from the reg gen modules
    input  device_axi_lite_data_t               bingo_hw_manager_start_i,
    output device_axi_lite_data_t               bingo_hw_manager_reset_start_o,
    output logic                                bingo_hw_manager_reset_start_en_o,
    output host_axi_lite_req_t                  task_queue_axi_lite_req_o,
    input  host_axi_lite_resp_t                 task_queue_axi_lite_resp_i,
    /// The chiplet set interface to other chiplets
    // HW Manager -----> Other chiplets
    input  host_axi_lite_addr_t                 chiplet_mailbox_base_addr_i,
    output host_axi_lite_req_t                  to_remote_chiplet_axi_lite_req_o,
    input  host_axi_lite_resp_t                 to_remote_chiplet_axi_lite_resp_i,
    /// The chiplet done interface from other chiplets
    input  host_axi_lite_req_t                  from_remote_axi_lite_req_i,
    output host_axi_lite_resp_t                 from_remote_axi_lite_resp_o,
    /// The done queue interface to the devices
    // Devices -----> Done Queue
    // Here this queue holds all the completed tasks info from the devices
    // The device cores will write completed tasks into this queue via 32bit AXI Lite
    input  device_axi_lite_addr_t               done_queue_base_addr_i,
    input  device_axi_lite_req_t                done_queue_axi_lite_req_i,
    output device_axi_lite_resp_t               done_queue_axi_lite_resp_o,
    /// The ready queue interface to the devices
    // HW scheduler -----> Ready Queue
    // Here the ready queue holds the tasks that are ready to be executed by the devices
    // The device cores will read tasks from this queue via 32bit AXI Lite
    // Each core has its own ready queue interface
    input  device_axi_lite_addr_t               ready_queue_base_addr_i,
    input  device_axi_lite_req_t                [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    ready_queue_axi_lite_req_i,
    output device_axi_lite_resp_t               [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    ready_queue_axi_lite_resp_o,
    /// CSR Req/Resp Interface for ready queue and the done queue
    // CSR Will Read from the ready queue and write to the done queue
    input  csr_req_t                            [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    csr_req_i,
    input  logic                                [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    csr_req_valid_i,
    output logic                                [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    csr_req_ready_o,
    output csr_rsp_t                            [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    csr_rsp_o,
    output logic                                [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    csr_rsp_valid_o,
    input  logic                                [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    csr_rsp_ready_i,
    /// The interface to the Power Management Module
    // Host configuration interface
    input device_axi_lite_data_t                bingo_hw_manager_enable_idle_pm_i,
    input device_axi_lite_data_t                bingo_hw_manager_idle_power_level_i,
    input device_axi_lite_data_t                bingo_hw_manager_normal_power_level_i,
    input device_axi_lite_addr_t                bingo_hw_manager_pm_base_addr_i,
    input device_axi_lite_data_t                [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    bingo_hw_manager_core_power_domain_i,
    // DVFS: mode select, CLINT doorbell address, host ack, and published request
    input  device_axi_lite_data_t               bingo_hw_manager_pm_mode_i,
    input  device_axi_lite_addr_t               bingo_hw_manager_dvfs_clint_msip_addr_i,
    input  device_axi_lite_data_t               bingo_hw_manager_dvfs_ack_i,
    output device_axi_lite_data_t               bingo_hw_manager_dvfs_request_o,
    // AXI Lite Master Interface
    output host_axi_lite_req_t                  pm_axi_lite_req_o,
    input  host_axi_lite_resp_t                 pm_axi_lite_resp_i,
    // DARTS: CERF (Conditional Execution Register File) interface
    input  logic                                cerf_write_en_i,
    input  logic [31:0]                         cerf_write_data_i,
    output logic [31:0]                         cerf_state_o,
    // DARTS: Load Monitor output (CSR readable)
    output logic [10:0]                         load_total_pending_o
);
    // --------Type definitions and signal declarations--------------------//
    // ---- Start of Type definitions -------------------------------------//
    // Task Type (DARTS: expanded to 2 bits for gating support)
    // 2'b00: Normal Task
    // 2'b01: Dummy Task (set/check synchronization)
    // 2'b10: Gating Task (executes on core, writes CERF on completion)
    // 2'b11: Reserved
    typedef logic [1:0]                                  bingo_hw_manager_task_type_t;
    // Task ID
    typedef logic [TaskIdWidth-1:0                     ] bingo_hw_manager_task_id_t;
    // Assigned Chiplet ID
    typedef logic [ChipIdWidth-1:0                     ] bingo_hw_manager_assigned_chiplet_id_t;
    // Assigned Cluster ID
    typedef logic [cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET)-1:0] bingo_hw_manager_assigned_cluster_id_t;
    // Assigned Core ID
    typedef logic [cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER)-1:0   ] bingo_hw_manager_assigned_core_id_t;
    // Dependency check info struct
    typedef logic [NUM_CORES_PER_CLUSTER-1:0]            bingo_hw_manager_dep_code_t;
    // Per-edge identity tag (EnableTaggedDeps). Carried alongside the dep code so
    // it flows through every existing dep_check_info / dep_set_info copy unchanged.
    typedef logic [DepTagWidth-1:0]                      bingo_hw_manager_dep_tag_t;
    typedef struct packed{
        bingo_hw_manager_dep_tag_t                   dep_check_tag;
        bingo_hw_manager_dep_code_t                  dep_check_code;
        logic                                        dep_check_en;
    } bingo_hw_manager_dep_check_info_t;
    // Dependency set info struct
    typedef struct packed{
        bingo_hw_manager_dep_tag_t                   dep_set_tag;
        bingo_hw_manager_dep_code_t                  dep_set_code;
        bingo_hw_manager_assigned_cluster_id_t       dep_set_cluster_id;
        bingo_hw_manager_assigned_chiplet_id_t       dep_set_chiplet_id;
        logic                                        dep_set_all_chiplet;
        logic                                        dep_set_en;
    } bingo_hw_manager_dep_set_info_t;

    // Task info struct (DARTS: includes conditional execution fields)
    typedef struct packed{
        bingo_hw_manager_dep_set_info_t              dep_set_info;
        bingo_hw_manager_dep_check_info_t            dep_check_info;
        bingo_hw_manager_assigned_core_id_t          assigned_core_id;
        bingo_hw_manager_assigned_cluster_id_t       assigned_cluster_id;
        bingo_hw_manager_assigned_chiplet_id_t       assigned_chiplet_id;
        bingo_hw_manager_task_id_t                   task_id;
        bingo_hw_manager_task_type_t                 task_type;
        // DARTS Tier 1: Conditional Execution
        logic                                        cond_exec_en;
        logic [4:0]                                  cond_exec_group_id;
        logic                                        cond_exec_invert;
    } bingo_hw_manager_task_desc_t;

    localparam int unsigned TaskDescWidth = $bits(bingo_hw_manager_task_desc_t);
    localparam int unsigned ReservedBitsForTaskDesc = HostAxiLiteDataWidth - TaskDescWidth;
    if (TaskDescWidth>HostAxiLiteDataWidth) begin : gen_task_desc_width_check
        initial begin
        $error("Task Decriptor width (%0d) exceeds Host AXI Lite Data Width (%0d)! Please adjust the parameters accordingly.", TaskDescWidth, HostAxiLiteDataWidth);
        $finish;
        end
    end
    // 64bit Task Descriptor with reserved bits
    typedef struct packed{
        logic [ReservedBitsForTaskDesc-1:0]          reserved_bits;
        bingo_hw_manager_dep_set_info_t              dep_set_info;
        bingo_hw_manager_dep_check_info_t            dep_check_info;
        bingo_hw_manager_assigned_core_id_t          assigned_core_id;
        bingo_hw_manager_assigned_cluster_id_t       assigned_cluster_id;
        bingo_hw_manager_assigned_chiplet_id_t       assigned_chiplet_id;
        bingo_hw_manager_task_id_t                   task_id;
        bingo_hw_manager_task_type_t                 task_type;
        // DARTS Tier 1: Conditional Execution
        logic                                        cond_exec_en;
        logic [4:0]                                  cond_exec_group_id;
        logic                                        cond_exec_invert;
    } bingo_hw_manager_task_desc_full_t;

    // Done info struct
    typedef struct packed{
        bingo_hw_manager_assigned_cluster_id_t     assigned_cluster_id;
        bingo_hw_manager_assigned_core_id_t        assigned_core_id;
        bingo_hw_manager_task_id_t                 task_id;
    } bingo_hw_manager_done_info_t;

    localparam int unsigned DoneInfoWidth = $bits(bingo_hw_manager_done_info_t);
    localparam int unsigned ReservedBitsForDoneInfo = DeviceAxiLiteDataWidth - DoneInfoWidth;
    if (DoneInfoWidth>DeviceAxiLiteDataWidth) begin : gen_done_info_width_check
        initial begin
        $error("Task Decriptor width (%0d) exceeds Device AXI Lite Data Width (%0d)! Please adjust the parameters accordingly.", DoneInfoWidth, DeviceAxiLiteDataWidth);
        $finish;
        end
    end

    typedef struct packed{
        logic [ReservedBitsForDoneInfo-1:0]        reserved_bits;
        bingo_hw_manager_assigned_cluster_id_t     assigned_cluster_id;
        bingo_hw_manager_assigned_core_id_t        assigned_core_id;
        bingo_hw_manager_task_id_t                 task_id;
    } bingo_hw_manager_done_info_full_t;

    typedef struct packed{
        bingo_hw_manager_assigned_cluster_id_t     dep_matrix_id;
        bingo_hw_manager_assigned_core_id_t        dep_matrix_col;
        bingo_hw_manager_dep_tag_t                 dep_matrix_set_tag;
        bingo_hw_manager_dep_code_t                dep_set_code;
    } bingo_hw_manager_dep_matrix_set_meta_t;

    typedef struct packed{
        bingo_hw_manager_task_id_t           task_id;
    } bingo_hw_manager_ready_task_desc_t;
    // Check the width
    localparam int unsigned ReadyTaskDescWidth = $bits(bingo_hw_manager_ready_task_desc_t);
    localparam int unsigned ReservedBitsForReadyTaskDesc = DeviceAxiLiteDataWidth - ReadyTaskDescWidth;
    if (ReadyTaskDescWidth>DeviceAxiLiteDataWidth) begin : gen_ready_task_desc_width_check
        initial begin
        $error("Ready Task Decriptor width (%0d) exceeds Device AXI Lite Data Width (%0d)! Please adjust the parameters accordingly.", ReadyTaskDescWidth, DeviceAxiLiteDataWidth);
        $finish;
        end
    end
    typedef struct packed{
        logic [ReservedBitsForReadyTaskDesc-1:0] reserved_bits;
        bingo_hw_manager_task_id_t           task_id;
    } bingo_hw_manager_ready_task_desc_full_t;
    //----- End of Type definitions ------------------------------------//

    //----- Start of Signal declarations -------------------------------//

    /////////////////////////////////////////////////////////
    // Task Queue Signals
    /////////////////////////////////////////////////////////
    // The task queue holds the tasks to be scheduled to the devices
    bingo_hw_manager_task_desc_full_t  cur_task_desc_full;
    bingo_hw_manager_task_desc_t       cur_task_desc;
    logic [HostAxiLiteDataWidth-1:0]   task_queue_mbox_data;
    logic                              task_queue_mbox_empty;
    logic                              task_queue_mbox_pop;


    /////////////////////////////////////////////////////////
    // Chiplet Dep Set Issue
    /////////////////////////////////////////////////////////
    // This module is to send the chiplet dep set signal to other chiplets
    // It will receive the chiplet dep set task from the wait dep check queues
    bingo_hw_manager_task_desc_full_t chiplet_dep_set_task_desc;
    logic                             chiplet_dep_set_task_desc_valid;
    logic                             chiplet_dep_set_task_desc_ready;

    //////////////////////////////////////////////////////////
    // Stream Arbiter Chiplet Dep Set Issue Signals
    //////////////////////////////////////////////////////////
    // The inputs are from the checkout queues of all cores in the chiplet
    bingo_hw_manager_task_desc_full_t [NUM_CORES_PER_CLUSTER*NUM_CLUSTERS_PER_CHIPLET-1:0] stream_arbiter_chiplet_dep_set_inp_task_desc;
    logic                             [NUM_CORES_PER_CLUSTER*NUM_CLUSTERS_PER_CHIPLET-1:0] stream_arbiter_chiplet_dep_set_inp_valid;
    logic                             [NUM_CORES_PER_CLUSTER*NUM_CLUSTERS_PER_CHIPLET-1:0] stream_arbiter_chiplet_dep_set_inp_ready;
    bingo_hw_manager_task_desc_full_t                                                      stream_arbiter_chiplet_dep_set_oup_task_desc;
    logic                                                                                  stream_arbiter_chiplet_dep_set_oup_valid;
    logic                                                                                  stream_arbiter_chiplet_dep_set_oup_ready;


    //////////////////////////////////////////////////////////
    // Chiplet Done Queue
    //////////////////////////////////////////////////////////
    logic [HostAxiLiteDataWidth-1:0]   chiplet_done_queue_mbox_data;
    logic                              chiplet_done_queue_mbox_empty;
    logic                              chiplet_done_queue_mbox_pop;
    bingo_hw_manager_task_desc_full_t  cur_chiplet_done_queue_task_desc;
    /////////////////////////////////////////////////////////
    // Stream demux core type
    /////////////////////////////////////////////////////////
    logic                                           stream_demux_core_type_inp_valid;
    logic                                           stream_demux_core_type_inp_ready;
    logic [cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER)-1:0]       stream_demux_core_type_oup_sel;
    logic [NUM_CORES_PER_CLUSTER-1:0]               stream_demux_core_type_oup_valid;
    logic [NUM_CORES_PER_CLUSTER-1:0]               stream_demux_core_type_oup_ready;

    ///////////////////////////////////
    // Waiting dep check queue signals
    ///////////////////////////////////
    bingo_hw_manager_task_desc_t      [NUM_CORES_PER_CLUSTER-1:0] waiting_dep_check_task_desc;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] waiting_dep_check_queue_push;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] waiting_dep_check_queue_full;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] waiting_dep_check_queue_empty;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] waiting_dep_check_queue_pop;

    ////////////////////////////////
    // Dep Check Manager Signals
    ////////////////////////////////
    logic                             [NUM_CORES_PER_CLUSTER-1:0] dep_check_manager_inp_wait_dep_check_queue_valid;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] dep_check_manager_inp_wait_dep_check_queue_ready;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] dep_check_manager_oup_dep_check_valid;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] dep_check_manager_oup_dep_check_ready;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] dep_check_manager_oup_ready_and_checkout_queue_valid;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] dep_check_manager_oup_ready_and_checkout_queue_ready;
    ////////////////////////////////
    // Dep matrix demux signals
    ////////////////////////////////
    typedef logic [NUM_CLUSTERS_PER_CHIPLET-1:0] dep_matrix_demux_oup_t;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] demux_dep_matrix_inp_valid;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] demux_dep_matrix_inp_ready;
    dep_matrix_demux_oup_t            [NUM_CORES_PER_CLUSTER-1:0] demux_dep_matrix_oup_valid;
    dep_matrix_demux_oup_t            [NUM_CORES_PER_CLUSTER-1:0] demux_dep_matrix_oup_ready;

    ////////////////////////////////
    // Ready and Checkout queue demux signals
    ////////////////////////////////
    typedef logic [NUM_CLUSTERS_PER_CHIPLET-1:0] ready_and_checkout_queue_demux_oup_t;
    logic                                          [NUM_CORES_PER_CLUSTER-1:0] demux_ready_and_checkout_queue_inp_valid;
    logic                                          [NUM_CORES_PER_CLUSTER-1:0] demux_ready_and_checkout_queue_inp_ready;
    ready_and_checkout_queue_demux_oup_t           [NUM_CORES_PER_CLUSTER-1:0] demux_ready_and_checkout_queue_oup_valid;
    ready_and_checkout_queue_demux_oup_t           [NUM_CORES_PER_CLUSTER-1:0] demux_ready_and_checkout_queue_oup_ready;

    ////////////////////////////////
    // Ready Queue Filter Signals
    ////////////////////////////////
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_filter_inp_valid;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_filter_inp_ready;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_filter_drop;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_filter_oup_valid;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_filter_oup_ready;

    //////////////////////
    // Dep matrix signals
    //////////////////////
    typedef logic [NUM_CORES_PER_CLUSTER-1:0] dep_check_code_t;
    typedef logic [NUM_CORES_PER_CLUSTER-1:0] dep_set_code_t;

    logic [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0]            dep_check_valid;
    logic [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0]            dep_check_result;
    dep_check_code_t [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0] dep_check_code;
    bingo_hw_manager_dep_tag_t [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0] dep_check_tag;
    logic [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0]            dep_set_valid;
    logic [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0]            dep_set_ready;
    dep_set_code_t [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0]   dep_set_code;
    bingo_hw_manager_dep_tag_t [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0] dep_set_tag;

    ///////////////////////////////////////
    // Stream Arbiter Dep Matrix Set
    ///////////////////////////////////////
    // There are two types input streams to set the dep matrix
    // Type 1: From Checkout queues (NUM_CORE * NUM_Cluster) for normal and dummy set dep
    // Type 2: From Chiplet Dep Set Recv Queue for chiplet dep set queues
    // In total we have (NUM_CORE * NUM_Cluster) + 1 inputs for the dep matrix set
    localparam int unsigned STREAM_ARBITER_DEP_MATRIX_SET_NUM_INP = NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET + 1;
    bingo_hw_manager_dep_matrix_set_meta_t    [STREAM_ARBITER_DEP_MATRIX_SET_NUM_INP-1:0] stream_arbiter_dep_matrix_set_inp_data;
    logic                                     [STREAM_ARBITER_DEP_MATRIX_SET_NUM_INP-1:0] stream_arbiter_dep_matrix_set_inp_valid;
    logic                                     [STREAM_ARBITER_DEP_MATRIX_SET_NUM_INP-1:0] stream_arbiter_dep_matrix_set_inp_ready;
    bingo_hw_manager_dep_matrix_set_meta_t                                                stream_arbiter_dep_matrix_set_oup_data;
    logic                                                                                 stream_arbiter_dep_matrix_set_oup_valid;
    logic                                                                                 stream_arbiter_dep_matrix_set_oup_ready;
 
    ///////////////////////////////////////
    // Stream Demux Set Dep Matrix Cluster ID
    ///////////////////////////////////////
    // Possbile to move the demux before the arbiter to support more parallelism
    logic                                                          stream_demux_set_dep_matrix_cluster_id_inp_valid;
    logic                                                          stream_demux_set_dep_matrix_cluster_id_inp_ready;
    logic  [cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET)-1:0]  stream_demux_set_dep_matrix_cluster_id_oup_sel;
    logic  [NUM_CLUSTERS_PER_CHIPLET-1:0]                          stream_demux_set_dep_matrix_cluster_id_oup_valid;
    logic  [NUM_CLUSTERS_PER_CHIPLET-1:0]                          stream_demux_set_dep_matrix_cluster_id_oup_ready;
    ///////////////////////////////////////
    // Stream Demux Set Dep Matrix Core ID
    ///////////////////////////////////////
    typedef logic [cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER)-1:0]             stream_demux_set_dep_matrix_core_id_oup_sel_t;
    typedef logic [NUM_CORES_PER_CLUSTER-1:0]                                     stream_demux_set_dep_matrix_core_id_oup_t;
    logic                                          [NUM_CLUSTERS_PER_CHIPLET-1:0] stream_demux_set_dep_matrix_core_id_inp_valid;
    logic                                          [NUM_CLUSTERS_PER_CHIPLET-1:0] stream_demux_set_dep_matrix_core_id_inp_ready;
    stream_demux_set_dep_matrix_core_id_oup_sel_t  [NUM_CLUSTERS_PER_CHIPLET-1:0] stream_demux_set_dep_matrix_core_id_oup_sel;
    stream_demux_set_dep_matrix_core_id_oup_t      [NUM_CLUSTERS_PER_CHIPLET-1:0] stream_demux_set_dep_matrix_core_id_oup_valid;
    stream_demux_set_dep_matrix_core_id_oup_t      [NUM_CLUSTERS_PER_CHIPLET-1:0] stream_demux_set_dep_matrix_core_id_oup_ready;


    //////////////////////
    // Ready queue signals
    //////////////////////
    // Ready task info
    device_axi_lite_addr_t                  [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_base_addr;
    bingo_hw_manager_ready_task_desc_full_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_data_in;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_push;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_full;
    // ready queue data_o/empty_o/pop_i signals are only for CSR interface
    logic                                    [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_pop;
    bingo_hw_manager_ready_task_desc_full_t  [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_data_out;
    logic                                    [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_empty;


    //////////////////////
    // Checkout queue signals
    //////////////////////
    bingo_hw_manager_task_desc_t   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_queue_data_out;
    bingo_hw_manager_task_desc_t   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_queue_data_in;
    logic                          [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_queue_push;
    logic                          [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_queue_pop;
    logic                          [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_queue_full;
    logic                          [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_queue_empty;

    ///////////////////////////////////////////
    // Stream Demux Checkout Queue Chiplet Set
    ///////////////////////////////////////////
    // After each checkout queue, we need to demux the chiplet dep set tasks
    // There are two types of outputs from the checkout queue
    // [0]: Local dep set
    // [1]: Chiplet dep set
    typedef logic [1:0] stream_demux_checkout_queue_chiplet_dep_set_oup_t;
    logic                                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] stream_demux_checkout_queue_chiplet_dep_set_inp_valid;
    logic                                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] stream_demux_checkout_queue_chiplet_dep_set_inp_ready;
    logic                                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] stream_demux_checkout_queue_chiplet_dep_set_oup_sel;
    stream_demux_checkout_queue_chiplet_dep_set_oup_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] stream_demux_checkout_queue_chiplet_dep_set_oup_valid;
    stream_demux_checkout_queue_chiplet_dep_set_oup_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] stream_demux_checkout_queue_chiplet_dep_set_oup_ready;

    ///////////////////////////////////////////
    // Stream Filter Checkout Queue Dep Set Enable
    ///////////////////////////////////////////    
    logic                                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] stream_filter_checkout_queue_dep_set_enable_inp_valid;
    logic                                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] stream_filter_checkout_queue_dep_set_enable_inp_ready;
    logic                                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] stream_filter_checkout_queue_dep_set_enable_drop;
    logic                                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] stream_filter_checkout_queue_dep_set_enable_oup_valid;
    logic                                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] stream_filter_checkout_queue_dep_set_enable_oup_ready;
    ///////////////////////////////////////
    // Per (Core, Cluster) Done Queue signals
    // Each (core, cluster) pair has its own done queue FIFO.
    // This fully eliminates HOL blocking: completions for different
    // cores AND different clusters drain independently.
    ///////////////////////////////////////
    bingo_hw_manager_done_info_full_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] done_q_info;
    logic                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] done_q_pop;
    logic                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] done_q_empty;
    bingo_hw_manager_done_info_full_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] done_q_data_in;
    logic                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] done_q_push;
    logic                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] done_q_full;
    // Legacy single-queue signals for AXI-Lite mailbox mode (TYPE==0)
    // In AXI-Lite mode, we still use a single mailbox + internal demux
    device_axi_lite_data_t               done_queue_mbox_data;
    logic                                done_queue_mbox_pop;
    logic                                done_queue_mbox_empty;
    bingo_hw_manager_done_info_full_t    cur_done_queue_info_axi;
    ///////////////////////////////////////
    // DARTS Tier 1: CERF state and per-core conditional skip signals
    logic [31:0] cerf_state;
    assign cerf_state_o = cerf_state;  // read-back for SW
    logic [NUM_CORES_PER_CLUSTER-1:0] cond_exec_skip;

    // DARTS CERF: per-core conditional skip evaluation.
    // Only valid when there IS a task being processed (queue not empty).
    // When cond_exec_en==0 (default), this is always 0 regardless of CERF state.
    for (genvar c = 0; c < NUM_CORES_PER_CLUSTER; c++) begin: gen_cerf_skip
        logic cerf_group_active_for_core;
        assign cerf_group_active_for_core = cerf_state[waiting_dep_check_task_desc[c].cond_exec_group_id];
        assign cond_exec_skip[c] = !waiting_dep_check_queue_empty[c] &&
                                    waiting_dep_check_task_desc[c].cond_exec_en &&
                                    (waiting_dep_check_task_desc[c].cond_exec_invert ?
                                        cerf_group_active_for_core : !cerf_group_active_for_core);
    end

    // PM signals
    ///////////////////////////////////////
    logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] core_status_waiting_task;
    // --------Finish Type definitions and signal declarations--------------------//

    // --------Module initializations---------------------------------------------//

    //////////////////////////////////////////////////////////////////////
    // Task Queue
    /////////////////////////////////////////////////////////////////////
    if (TASK_QUEUE_TYPE == 0 ) begin : gen_bingo_hw_manager_task_queue_default_slave
        // Default AXI Lite Slave Task Queue
        bingo_hw_manager_write_mailbox #(
            .MailboxDepth(TaskQueueDepth               ),
            .IrqEdgeTrig (1'b0                         ),
            .IrqActHigh  (1'b1                         ),
            .AxiAddrWidth(HostAxiLiteAddrWidth         ),
            .AxiDataWidth(HostAxiLiteDataWidth         ),
            .ChipIdWidth (ChipIdWidth                  ),
            .req_lite_t  (host_axi_lite_req_t          ),
            .resp_lite_t (host_axi_lite_resp_t         )
        ) i_bingo_hw_manager_task_queue_slave (
            .clk_i       (clk_i                     ),
            .rst_ni      (rst_ni                    ),
            .chip_id_i   (chip_id_i                 ),
            .test_i      (1'b0                      ),
            .req_i       (task_queue_axi_lite_req_i ),
            .resp_o      (task_queue_axi_lite_resp_o),
            .irq_o       (/*not used*/              ),
            .base_addr_i (task_queue_base_addr_i    ),
            .mbox_data_o (task_queue_mbox_data      ),
            .mbox_pop_i  (task_queue_mbox_pop       ),
            .mbox_empty_o(task_queue_mbox_empty     ),
            .mbox_flush_i('0                        )
        );
        // Tie off the unused master interface signals
        assign task_queue_axi_lite_req_o = '0;
        assign reset_start_o = 1'b0;
        assign reset_start_enable_o = 1'b0;
    end
    else begin : gen_bingo_hw_manager_task_queue_master
        // AXI Lite Master Task Queue
        // The Hw Manager issues the read request to the address specified by the host via the following inputs
        // Hence this is a master AXI Lite interface
        bingo_hw_manager_task_queue_master #(
            .TaskQueueDepth               (TaskQueueDepth               ),
            .TaskIdWidth                  (TaskIdWidth                  ),
            .req_lite_t                   (host_axi_lite_req_t          ),
            .resp_lite_t                  (host_axi_lite_resp_t         ),
            .addr_t                       (host_axi_lite_addr_t         ),
            .data_t                       (host_axi_lite_data_t         )
        ) i_bingo_hw_manager_task_queue_master (
            .clk_i                     (clk_i                                ),
            .rst_ni                    (rst_ni                               ),
            .task_list_base_addr_i     (task_list_base_addr_i                ),
            .num_task_i                (num_task_i                           ),
            .start_i                   (bingo_hw_manager_start_i             ),
            .reset_start_o             (bingo_hw_manager_reset_start_o       ),
            .reset_start_en_o          (bingo_hw_manager_reset_start_en_o    ),
            .task_queue_axi_lite_req_o (task_queue_axi_lite_req_o            ),
            .task_queue_axi_lite_resp_i(task_queue_axi_lite_resp_i           ),
            .task_queue_data_o         (task_queue_mbox_data                 ),
            .task_queue_pop_i          (task_queue_mbox_pop                  ),
            .task_queue_empty_o        (task_queue_mbox_empty                )
        );
        // Tie off the unused slave interface signals
        assign task_queue_axi_lite_resp_o = '0;
    end
    //////////////////////////////////////////////////////////////////////
    // Task queue → demux (direct connection, no mux needed)
    //////////////////////////////////////////////////////////////////////
    host_axi_lite_data_t muxed_task_data;
    logic                muxed_task_valid;

    assign muxed_task_data  = task_queue_mbox_data;
    assign muxed_task_valid = !task_queue_mbox_empty;
    assign task_queue_mbox_pop = stream_demux_core_type_inp_ready && !task_queue_mbox_empty;

    // Compose the current task descriptor from the muxed source
    assign cur_task_desc_full = bingo_hw_manager_task_desc_full_t'(muxed_task_data);
    assign cur_task_desc.task_id = cur_task_desc_full.task_id;
    assign cur_task_desc.task_type = cur_task_desc_full.task_type;
    assign cur_task_desc.assigned_chiplet_id = cur_task_desc_full.assigned_chiplet_id;
    assign cur_task_desc.assigned_cluster_id = cur_task_desc_full.assigned_cluster_id;
    assign cur_task_desc.assigned_core_id = cur_task_desc_full.assigned_core_id;
    assign cur_task_desc.dep_check_info = cur_task_desc_full.dep_check_info;
    assign cur_task_desc.dep_set_info = cur_task_desc_full.dep_set_info;
    // DARTS Tier 1: CERF fields
    assign cur_task_desc.cond_exec_en = cur_task_desc_full.cond_exec_en;
    assign cur_task_desc.cond_exec_group_id = cur_task_desc_full.cond_exec_group_id;
    assign cur_task_desc.cond_exec_invert = cur_task_desc_full.cond_exec_invert;


    /////////////////////////////////////////////////////////
    // H2H Dep Set Interface
    /////////////////////////////////////////////////////////       
    bingo_hw_manager_chiplet_dep_set #(
        .ChipIdWidth                                  (ChipIdWidth            ),
        .HostAxiLiteAddrWidth                         (HostAxiLiteAddrWidth   ),
        .HostAxiLiteDataWidth                         (HostAxiLiteDataWidth   ),
        .host_axi_lite_req_t                          (host_axi_lite_req_t    ),
        .host_axi_lite_resp_t                         (host_axi_lite_resp_t   ),
        .bingo_hw_manager_task_desc_full_t            (bingo_hw_manager_task_desc_full_t)
    ) i_bingo_hw_manager_chiplet_dep_set (
        .clk_i                             (clk_i                              ),
        .rst_ni                            (rst_ni                             ),
        .chiplet_mailbox_base_addr_i       (chiplet_mailbox_base_addr_i        ),
        .to_remote_chiplet_axi_lite_req_o  (to_remote_chiplet_axi_lite_req_o   ),
        .to_remote_chiplet_axi_lite_resp_i (to_remote_chiplet_axi_lite_resp_i  ),
        .chiplet_dep_set_task_desc_i       (chiplet_dep_set_task_desc          ),
        .chiplet_dep_set_task_desc_valid_i (chiplet_dep_set_task_desc_valid    ),
        .chiplet_dep_set_task_desc_ready_o (chiplet_dep_set_task_desc_ready    )
    );
    assign chiplet_dep_set_task_desc = stream_arbiter_chiplet_dep_set_oup_task_desc;
    assign chiplet_dep_set_task_desc_valid = stream_arbiter_chiplet_dep_set_oup_valid;

    /////////////////////////////////////////////////////////
    // Stream Arbiter for Chiplet Dep Set
    /////////////////////////////////////////////////////////     
    stream_arbiter #(
        .DATA_T (bingo_hw_manager_task_desc_full_t                             ),
        .N_INP  (NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET              )
    ) i_stream_arbiter_chiplet_dep_set (
        .clk_i      ( clk_i                                        ),
        .rst_ni     ( rst_ni                                       ),
        .inp_data_i ( stream_arbiter_chiplet_dep_set_inp_task_desc ),
        .inp_valid_i( stream_arbiter_chiplet_dep_set_inp_valid     ),
        .inp_ready_o( stream_arbiter_chiplet_dep_set_inp_ready     ),
        .oup_data_o ( stream_arbiter_chiplet_dep_set_oup_task_desc ),
        .oup_valid_o( stream_arbiter_chiplet_dep_set_oup_valid     ),
        .oup_ready_i( stream_arbiter_chiplet_dep_set_oup_ready     )
    );
    assign stream_arbiter_chiplet_dep_set_oup_ready = chiplet_dep_set_task_desc_ready;
    always_comb begin : compose_stream_arbiter_chiplet_dep_set_signals
        for (int unsigned cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin
            for (int unsigned core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
                stream_arbiter_chiplet_dep_set_inp_task_desc[core + cluster * NUM_CORES_PER_CLUSTER].reserved_bits = '0;
                stream_arbiter_chiplet_dep_set_inp_task_desc[core + cluster * NUM_CORES_PER_CLUSTER].dep_set_info = checkout_queue_data_out[core][cluster].dep_set_info;
                stream_arbiter_chiplet_dep_set_inp_task_desc[core + cluster * NUM_CORES_PER_CLUSTER].dep_check_info = checkout_queue_data_out[core][cluster].dep_check_info;
                stream_arbiter_chiplet_dep_set_inp_task_desc[core + cluster * NUM_CORES_PER_CLUSTER].assigned_core_id = checkout_queue_data_out[core][cluster].assigned_core_id;
                stream_arbiter_chiplet_dep_set_inp_task_desc[core + cluster * NUM_CORES_PER_CLUSTER].assigned_cluster_id = checkout_queue_data_out[core][cluster].assigned_cluster_id;
                stream_arbiter_chiplet_dep_set_inp_task_desc[core + cluster * NUM_CORES_PER_CLUSTER].assigned_chiplet_id = checkout_queue_data_out[core][cluster].assigned_chiplet_id;
                stream_arbiter_chiplet_dep_set_inp_task_desc[core + cluster * NUM_CORES_PER_CLUSTER].task_id = checkout_queue_data_out[core][cluster].task_id;
                stream_arbiter_chiplet_dep_set_inp_task_desc[core + cluster * NUM_CORES_PER_CLUSTER].task_type = checkout_queue_data_out[core][cluster].task_type;
                stream_arbiter_chiplet_dep_set_inp_valid[core + cluster * NUM_CORES_PER_CLUSTER] = stream_demux_checkout_queue_chiplet_dep_set_oup_valid[core][cluster][1];
            end           
        end
    end


    //////////////////////////////////////////////////////////////////////
    // Chiplet from remote Done Queue
    //////////////////////////////////////////////////////////////////////
    bingo_hw_manager_write_mailbox #(
        .MailboxDepth(ChipletDoneQueueDepth                    ),
        .IrqEdgeTrig (1'b0                                     ),
        .IrqActHigh  (1'b1                                     ),
        .AxiAddrWidth(HostAxiLiteAddrWidth                     ),
        .AxiDataWidth(HostAxiLiteDataWidth                     ),
        .ChipIdWidth (ChipIdWidth                              ),
        .req_lite_t  (host_axi_lite_req_t                      ),
        .resp_lite_t (host_axi_lite_resp_t                     )
    ) i_bingo_hw_manager_chiplet_done_queue (
        .clk_i       (clk_i                             ),
        .rst_ni      (rst_ni                            ),
        .chip_id_i   (chip_id_i                         ),
        .test_i      (1'b0                              ),
        .req_i       (from_remote_axi_lite_req_i        ),
        .resp_o      (from_remote_axi_lite_resp_o       ),
        .irq_o       (/*not used*/                      ),
        .base_addr_i (chiplet_mailbox_base_addr_i       ),
        .mbox_data_o (chiplet_done_queue_mbox_data      ),
        .mbox_pop_i  (chiplet_done_queue_mbox_pop       ),
        .mbox_empty_o(chiplet_done_queue_mbox_empty     ),
        .mbox_flush_i('0                                )
    );
    assign cur_chiplet_done_queue_task_desc = bingo_hw_manager_task_desc_full_t'(chiplet_done_queue_mbox_data);
    assign chiplet_done_queue_mbox_pop =  stream_arbiter_dep_matrix_set_inp_ready[NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET] && !chiplet_done_queue_mbox_empty;
    //////////////////////////////////////////////////////////////////////
    // Stream demux core type
    //////////////////////////////////////////////////////////////////////
    stream_demux #(
        .N_OUP ( NUM_CORES_PER_CLUSTER           )
    ) i_stream_demux_core_type (
        .inp_valid_i ( stream_demux_core_type_inp_valid ),
        .inp_ready_o ( stream_demux_core_type_inp_ready ),
        .oup_sel_i   ( stream_demux_core_type_oup_sel   ),
        .oup_valid_o ( stream_demux_core_type_oup_valid ),
        .oup_ready_i ( stream_demux_core_type_oup_ready )
    );
    always_comb begin: compose_stream_demux_core_type_signals
        stream_demux_core_type_inp_valid = muxed_task_valid;
        stream_demux_core_type_oup_sel = cur_task_desc.assigned_core_id;
        for (int unsigned core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
            stream_demux_core_type_oup_ready[core] = !waiting_dep_check_queue_full[core];
        end
    end


    for (genvar core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin: gen_waiting_dep_check_queue
        fifo_v3 #(
            .FALL_THROUGH ( 1'b0                               ),
            .DEPTH        ( 8                                  ),
            .dtype        ( bingo_hw_manager_task_desc_t       )
        ) i_waiting_dep_check_queue (
            .clk_i       ( clk_i                               ),
            .rst_ni      ( rst_ni                              ),
            .testmode_i  ( 1'b0                                ),
            .flush_i     ( 1'b0                                ),
            .full_o      ( waiting_dep_check_queue_full[core]  ),
            .empty_o     ( waiting_dep_check_queue_empty[core] ),
            .usage_o     ( /*not used*/                        ),
            .data_i      ( cur_task_desc                       ),
            .push_i      ( waiting_dep_check_queue_push[core]  ),
            .data_o      ( waiting_dep_check_task_desc[core]   ),
            .pop_i       ( waiting_dep_check_queue_pop[core]   )
        );
        assign waiting_dep_check_queue_push[core] = stream_demux_core_type_oup_valid[core] && !waiting_dep_check_queue_full[core];
        assign waiting_dep_check_queue_pop[core] = dep_check_manager_inp_wait_dep_check_queue_ready[core] && !waiting_dep_check_queue_empty[core];

        bingo_hw_manager_dep_check_manager i_dep_check_manager(
            .clk_i                       ( clk_i                        ),
            .rst_ni                      ( rst_ni                       ),
            .wait_dep_check_queue_valid_i(dep_check_manager_inp_wait_dep_check_queue_valid[core]),
            .wait_dep_check_queue_ready_o(dep_check_manager_inp_wait_dep_check_queue_ready[core]),
            .dep_check_valid_o           (dep_check_manager_oup_dep_check_valid[core]),
            .dep_check_ready_i           (dep_check_manager_oup_dep_check_ready[core]),
            .ready_and_checkout_queue_valid_o(dep_check_manager_oup_ready_and_checkout_queue_valid[core]),
            .ready_and_checkout_queue_ready_i(dep_check_manager_oup_ready_and_checkout_queue_ready[core])
        );
        assign dep_check_manager_inp_wait_dep_check_queue_valid[core] = ~waiting_dep_check_queue_empty[core];
        // To Dep Matrix
        // For the dep matrix, if the dep check is disable, we do not need to send the task to dep matrix
        stream_filter i_stream_filter_dep_check_en_to_dep_matrix (
            .valid_i ( dep_check_manager_oup_dep_check_valid[core]    ),
            .ready_o ( dep_check_manager_oup_dep_check_ready[core]    ),
            .drop_i  ( (!waiting_dep_check_task_desc[core].dep_check_info.dep_check_en) ),
            .valid_o ( demux_dep_matrix_inp_valid[core]  ),
            .ready_i ( demux_dep_matrix_inp_ready[core]  )
        );
        stream_demux #(
            .N_OUP ( NUM_CLUSTERS_PER_CHIPLET           )
        ) i_stream_demux_from_waiting_dep_check_queue_to_dep_matrix (
            .inp_valid_i ( demux_dep_matrix_inp_valid[core]    ),
            .inp_ready_o ( demux_dep_matrix_inp_ready[core]    ),
            .oup_sel_i   ( waiting_dep_check_task_desc[core].assigned_cluster_id ),
            .oup_valid_o ( demux_dep_matrix_oup_valid[core]    ),
            .oup_ready_i ( demux_dep_matrix_oup_ready[core]    )
        );
        // To Ready Queue and Checkout Queue
        // We need a filter to drop the dummy check tasks
        // The dummy check does not need to go to the ready and checkout queue
        stream_filter i_stream_filter_dummy_check_task_to_ready_and_checkout_queue (
            .valid_i ( dep_check_manager_oup_ready_and_checkout_queue_valid[core]    ),
            .ready_o ( dep_check_manager_oup_ready_and_checkout_queue_ready[core]    ),
            .drop_i  ( (waiting_dep_check_task_desc[core].task_type == 2'b01) && (waiting_dep_check_task_desc[core].dep_check_info.dep_check_en) ), // Drop if it is a dummy check task
            .valid_o ( demux_ready_and_checkout_queue_inp_valid[core]  ),
            .ready_i ( demux_ready_and_checkout_queue_inp_ready[core]  )
        );
        stream_demux #(
            .N_OUP ( NUM_CLUSTERS_PER_CHIPLET           )
        ) i_stream_demux_from_waiting_dep_check_queue_to_ready_and_checkout_queue (
            .inp_valid_i ( demux_ready_and_checkout_queue_inp_valid[core]    ),
            .inp_ready_o ( demux_ready_and_checkout_queue_inp_ready[core]    ),
            .oup_sel_i   ( waiting_dep_check_task_desc[core].assigned_cluster_id ),
            .oup_valid_o ( demux_ready_and_checkout_queue_oup_valid[core]    ),
            .oup_ready_i ( demux_ready_and_checkout_queue_oup_ready[core]    )
        );

        always_comb begin : connect_demux_ready_and_checkout_queue_ready_signals
            for ( int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin 
                demux_ready_and_checkout_queue_oup_ready[core][cluster] = ready_queue_filter_inp_ready[core][cluster] && !checkout_queue_full[core][cluster];
            end
        end
    end


    ////////////////////////////////////////////////////////////////////////
    // Dep Matrix
    //////////////////////////////////////////////////////////////////////

    for (genvar cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin: gen_dep_matrix
        bingo_hw_manager_dep_matrix #(
            .DEP_MATRIX_ROWS(NUM_CORES_PER_CLUSTER),
            .DEP_MATRIX_COLS(NUM_CORES_PER_CLUSTER),
            .EnableTaggedDeps(EnableTaggedDeps),
            .TagWidth(DepTagWidth)
        ) i_dep_matrix (
            .clk_i             (clk_i                    ),
            .rst_ni            (rst_ni                   ),
            .dep_check_valid_i (dep_check_valid[cluster] ),
            .dep_check_code_i  (dep_check_code[cluster]  ),
            .dep_check_tag_i   (dep_check_tag[cluster]   ),
            .dep_check_result_o(dep_check_result[cluster]),
            .dep_set_valid_i   (dep_set_valid[cluster]   ),
            .dep_set_ready_o   (dep_set_ready[cluster]   ),
            .dep_set_code_i    (dep_set_code[cluster]    ),
            .dep_set_tag_i     (dep_set_tag[cluster]     )
        );
    end

    always_comb begin : connect_dep_check_for_dep_matrix
        for ( int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin
            for ( int core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
                dep_check_valid[cluster][core] = demux_dep_matrix_oup_valid[core][cluster];
                demux_dep_matrix_oup_ready[core][cluster] = dep_check_result[cluster][core];
                dep_check_code[cluster][core] = waiting_dep_check_task_desc[core].dep_check_info.dep_check_code;
                dep_check_tag[cluster][core] = waiting_dep_check_task_desc[core].dep_check_info.dep_check_tag;
            end
        end
    end

    //////////////////////////////////////////////////////////////////////
    // Stream Arbiter Dep Matrix Set
    //////////////////////////////////////////////////////////////////////
    stream_arbiter #(
        .DATA_T(bingo_hw_manager_dep_matrix_set_meta_t),
        .N_INP (STREAM_ARBITER_DEP_MATRIX_SET_NUM_INP)
    ) i_stream_arbiter_dep_matrix_set(
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),
        .inp_data_i (stream_arbiter_dep_matrix_set_inp_data ),
        .inp_valid_i(stream_arbiter_dep_matrix_set_inp_valid),
        .inp_ready_o(stream_arbiter_dep_matrix_set_inp_ready),
        .oup_data_o (stream_arbiter_dep_matrix_set_oup_data ),
        .oup_valid_o(stream_arbiter_dep_matrix_set_oup_valid),
        .oup_ready_i(stream_arbiter_dep_matrix_set_oup_ready)
    );
    always_comb begin : compose_stream_arbiter_dep_matrix_set_inputs
        // For Checkout Queue
        int stream_arbiter_inp_idx;
        for ( int core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
            for ( int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin
                    stream_arbiter_inp_idx = core + cluster * NUM_CORES_PER_CLUSTER;
                    stream_arbiter_dep_matrix_set_inp_data[stream_arbiter_inp_idx].dep_matrix_id = checkout_queue_data_out[core][cluster].dep_set_info.dep_set_cluster_id;
                    stream_arbiter_dep_matrix_set_inp_data[stream_arbiter_inp_idx].dep_matrix_col= core;
                    stream_arbiter_dep_matrix_set_inp_data[stream_arbiter_inp_idx].dep_matrix_set_tag = checkout_queue_data_out[core][cluster].dep_set_info.dep_set_tag;
                    stream_arbiter_dep_matrix_set_inp_data[stream_arbiter_inp_idx].dep_set_code  = checkout_queue_data_out[core][cluster].dep_set_info.dep_set_code;
                    // Handshake from the checkout demux and the per-(core,cluster) done queue
                    // Dummy set: no done queue check needed
                    // Normal: per-(core,cluster) done queue must be non-empty
                    stream_arbiter_dep_matrix_set_inp_valid[stream_arbiter_inp_idx] = (checkout_queue_data_out[core][cluster].task_type == 2'b01) ?
                                                                                      stream_filter_checkout_queue_dep_set_enable_oup_valid[core][cluster] :
                                                                                      ((stream_filter_checkout_queue_dep_set_enable_oup_valid[core][cluster]) &&
                                                                                       (!done_q_empty[core][cluster]));
            end
        end
        // For Chiplet Set Queue
        stream_arbiter_dep_matrix_set_inp_data[NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET].dep_matrix_id  = cur_chiplet_done_queue_task_desc.dep_set_info.dep_set_cluster_id;
        stream_arbiter_dep_matrix_set_inp_data[NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET].dep_matrix_col = cur_chiplet_done_queue_task_desc.assigned_core_id;
        stream_arbiter_dep_matrix_set_inp_data[NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET].dep_matrix_set_tag = cur_chiplet_done_queue_task_desc.dep_set_info.dep_set_tag;
        stream_arbiter_dep_matrix_set_inp_data[NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET].dep_set_code   = cur_chiplet_done_queue_task_desc.dep_set_info.dep_set_code;
        stream_arbiter_dep_matrix_set_inp_valid[NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET] = !chiplet_done_queue_mbox_empty;
        stream_arbiter_dep_matrix_set_oup_ready = stream_demux_set_dep_matrix_cluster_id_inp_ready;
    end 
    //////////////////////////////////////////////////////////////////////
    // Stream Demux Set Dep Matrix Cluster ID
    //////////////////////////////////////////////////////////////////////
    stream_demux #(
        .N_OUP(NUM_CLUSTERS_PER_CHIPLET)
    ) i_stream_demux_set_dep_matrix_cluster_id (
        .inp_valid_i(stream_demux_set_dep_matrix_cluster_id_inp_valid),
        .inp_ready_o(stream_demux_set_dep_matrix_cluster_id_inp_ready),
        .oup_sel_i  (stream_demux_set_dep_matrix_cluster_id_oup_sel),
        .oup_valid_o(stream_demux_set_dep_matrix_cluster_id_oup_valid),
        .oup_ready_i(stream_demux_set_dep_matrix_cluster_id_oup_ready)
    );
    assign stream_demux_set_dep_matrix_cluster_id_inp_valid = stream_arbiter_dep_matrix_set_oup_valid;
    assign stream_demux_set_dep_matrix_cluster_id_oup_sel = stream_arbiter_dep_matrix_set_oup_data.dep_matrix_id;

    //////////////////////////////////////////////////////////////////////
    // Stream Demux Set Dep Matrix Core ID
    //////////////////////////////////////////////////////////////////////
    for (genvar cluster= 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin: gen_set_dep_matrix_core_id
        stream_demux #(
            .N_OUP(NUM_CORES_PER_CLUSTER)
        ) i_stream_demux_set_dep_matrix_core_id (
            .inp_valid_i(stream_demux_set_dep_matrix_core_id_inp_valid[cluster]),
            .inp_ready_o(stream_demux_set_dep_matrix_core_id_inp_ready[cluster]),
            .oup_sel_i  (stream_demux_set_dep_matrix_core_id_oup_sel[cluster]  ),
            .oup_valid_o(stream_demux_set_dep_matrix_core_id_oup_valid[cluster]),
            .oup_ready_i(stream_demux_set_dep_matrix_core_id_oup_ready[cluster])
        );
        assign stream_demux_set_dep_matrix_cluster_id_oup_ready[cluster] = stream_demux_set_dep_matrix_core_id_inp_ready[cluster];
        assign stream_demux_set_dep_matrix_core_id_inp_valid[cluster] = stream_demux_set_dep_matrix_cluster_id_oup_valid[cluster];
        assign stream_demux_set_dep_matrix_core_id_oup_sel[cluster] = stream_arbiter_dep_matrix_set_oup_data.dep_matrix_col;
    end

    always_comb begin : connect_dep_set_for_dep_matrix
        for ( int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin
            for ( int core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
                dep_set_valid[cluster][core] = stream_demux_set_dep_matrix_core_id_oup_valid[cluster][core];
                stream_demux_set_dep_matrix_core_id_oup_ready[cluster][core] = dep_set_ready[cluster][core];
                dep_set_code[cluster][core] = stream_arbiter_dep_matrix_set_oup_data.dep_set_code;
                dep_set_tag[cluster][core] = stream_arbiter_dep_matrix_set_oup_data.dep_matrix_set_tag;
            end
        end        
    end

    //////////////////////////////////////////////////////////////////////
    // Ready Queue
    //////////////////////////////////////////////////////////////////////
    // This is the ready queue interface
    // Device will read ready tasks info from this queue via 32bit AXI Lite
    // The information contains only task ID
    // Before each ready queue, there is a filter to filter out the dummy set tasks since it will not be run on the core
    for (genvar core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin: gen_ready_queue_per_core
        for (genvar cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin: gen_ready_queue_per_core_per_cluster
            stream_filter i_stream_filter_for_ready_queue_dummy_set (
                .valid_i (   ready_queue_filter_inp_valid[core][cluster]       ),
                .ready_o (   ready_queue_filter_inp_ready[core][cluster]       ),
                .drop_i  (   ready_queue_filter_drop[core][cluster]            ),
                .valid_o (   ready_queue_filter_oup_valid[core][cluster]       ),
                .ready_i (   ready_queue_filter_oup_ready[core][cluster]       )
            );
            assign ready_queue_filter_inp_valid[core][cluster] = demux_ready_and_checkout_queue_oup_valid[core][cluster];
            // Drop the dummy set tasks
            // Drop from ready queue if:
            // 1. Dummy set task (task_type==01, dep_set_en==1) — existing behavior
            // 2. DARTS CERF: conditionally skipped task — skip execution but propagate deps
            assign ready_queue_filter_drop[core][cluster] =
                ((waiting_dep_check_task_desc[core].task_type == 2'b01) &&
                 (waiting_dep_check_task_desc[core].dep_set_info.dep_set_en == 1'b1)) ||
                cond_exec_skip[core];
            assign ready_queue_filter_oup_ready[core][cluster] = ~ready_queue_full[core][cluster];
            if (READY_AND_DONE_QUEUE_INTERFACE_TYPE==0) begin: gen_ready_queue_axi_lite_mailbox                               
                bingo_hw_manager_read_mailbox #(
                    .MailboxDepth(ReadyQueueDepth                ),
                    .IrqEdgeTrig (1'b0                           ),
                    .IrqActHigh  (1'b1                           ),
                    .AxiAddrWidth(DeviceAxiLiteAddrWidth         ),
                    .AxiDataWidth(DeviceAxiLiteDataWidth         ),
                    .ChipIdWidth (ChipIdWidth                    ),
                    .req_lite_t  (device_axi_lite_req_t          ),
                    .resp_lite_t (device_axi_lite_resp_t         )
                ) i_bingo_hw_manager_ready_queue (
                    .clk_i       (clk_i                                                        ),
                    .rst_ni      (rst_ni                                                       ),
                    .chip_id_i   (chip_id_i                                                    ),
                    .test_i      (1'b0                                                         ),
                    .req_i       (ready_queue_axi_lite_req_i[core][cluster]                    ),
                    .resp_o      (ready_queue_axi_lite_resp_o[core][cluster]                   ),
                    .irq_o       (/*not used*/                                                 ),
                    .base_addr_i (ready_queue_base_addr[core][cluster]                         ),
                    .mbox_data_i (ready_queue_data_in[core][cluster]                           ),
                    .mbox_push_i (ready_queue_push[core][cluster]                              ),
                    .mbox_full_o (ready_queue_full[core][cluster]                              ),
                    .mbox_flush_i(1'b0                                                         )
                );
                // Connect to the core_status_waiting_task
                // This signal indicates whether the core is waiting for a task to be read from the ready queue
                // If ar_valid is high and r_ready is low, it means the core is waiting for a task
                assign core_status_waiting_task[core][cluster] = ready_queue_axi_lite_req_i[core][cluster].ar_valid && 
                                                                !ready_queue_axi_lite_req_i[core][cluster].r_ready;
                // Tie off the generic fifo read signals
                assign ready_queue_pop[core][cluster] = 1'b0;
                assign ready_queue_empty[core][cluster] = 1'b0;
                assign ready_queue_data_out[core][cluster] = '0;
            end else begin: gen_ready_queue_generic_fifo
                fifo_v3 #(
                    .FALL_THROUGH ( 1'b0                                      ),
                    .DEPTH        ( ReadyQueueDepth                           ),
                    .dtype        ( bingo_hw_manager_ready_task_desc_full_t   )
                ) i_ready_queue (
                    .clk_i       ( clk_i                                  ),
                    .rst_ni      ( rst_ni                                 ),
                    .testmode_i  ( 1'b0                                   ),
                    .flush_i     ( 1'b0                                   ),
                    .full_o      ( ready_queue_full[core][cluster]        ),
                    .empty_o     ( ready_queue_empty[core][cluster]       ),
                    .usage_o     ( /*not used*/                           ),
                    .data_i      ( ready_queue_data_in[core][cluster]     ),
                    .push_i      ( ready_queue_push[core][cluster]        ),
                    .data_o      ( ready_queue_data_out[core][cluster]    ),
                    .pop_i       ( ready_queue_pop[core][cluster]         )
                );
                // Connect to the core_status_waiting_task
                // Since we do not have the axi lite interface, we tie off the ready queue axi lite resp signals
                assign ready_queue_axi_lite_resp_o[core][cluster] = '0;
            end
            assign ready_queue_base_addr[core][cluster] = ready_queue_base_addr_i +
                                                        (core + cluster * NUM_CORES_PER_CLUSTER) * ReadyQueueAddrOffset;
            assign ready_queue_data_in[core][cluster].task_id = waiting_dep_check_task_desc[core].task_id;
            assign ready_queue_data_in[core][cluster].reserved_bits = '0;
            assign ready_queue_push[core][cluster] = ready_queue_filter_oup_valid[core][cluster] & ~ready_queue_full[core][cluster];
        end
    end


    //////////////////////////////////////////////////////////////////////
    // Checkout Queue
    //////////////////////////////////////////////////////////////////////
    // Check out queues are internal fifos
    // input is from the waiting dep check queue
    // after it has been checked by the dep matrix, it will be pushed to the checkout queue
    // and then wait the done queue to pop it
    for (genvar core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin: gen_checkout_queue_per_core
        for (genvar cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin: gen_checkout_queue_per_core_per_cluster
            fifo_v3 #(
                .FALL_THROUGH ( 1'b0                                  ),
                .DEPTH        ( CheckoutQueueDepth                    ),
                .dtype        ( bingo_hw_manager_task_desc_t          )
            ) i_checkout_queue (
                .clk_i       ( clk_i                                  ),
                .rst_ni      ( rst_ni                                 ),
                .testmode_i  ( 1'b0                                   ),
                .flush_i     ( 1'b0                                   ),
                .full_o      ( checkout_queue_full[core][cluster]     ),
                .empty_o     ( checkout_queue_empty[core][cluster]    ),
                .usage_o     ( /*not used*/                           ),
                .data_i      ( checkout_queue_data_in[core][cluster]  ),
                .push_i      ( checkout_queue_push[core][cluster]     ),
                .data_o      ( checkout_queue_data_out[core][cluster] ),
                .pop_i       ( checkout_queue_pop[core][cluster]      )
            );
            // DARTS CERF: if task is conditionally skipped, mark as dummy (2'b01)
            // so checkout logic fires dep_set without done_queue match
            always_comb begin
                checkout_queue_data_in[core][cluster] = waiting_dep_check_task_desc[core];
                if (cond_exec_skip[core]) begin
                    checkout_queue_data_in[core][cluster].task_type = 2'b01;
                end
            end
            assign checkout_queue_push[core][cluster] = demux_ready_and_checkout_queue_oup_valid[core][cluster] && !checkout_queue_full[core][cluster];
            assign checkout_queue_pop[core][cluster] = stream_demux_checkout_queue_chiplet_dep_set_inp_ready[core][cluster] && !checkout_queue_empty[core][cluster];

            stream_demux #(
                .N_OUP ( 2 )
            ) i_stream_demux_checkout_queue_chiplet_dep_set (
                .inp_valid_i ( stream_demux_checkout_queue_chiplet_dep_set_inp_valid[core][cluster]    ),
                .inp_ready_o ( stream_demux_checkout_queue_chiplet_dep_set_inp_ready[core][cluster]    ),
                .oup_sel_i   ( stream_demux_checkout_queue_chiplet_dep_set_oup_sel[core][cluster]      ),
                .oup_valid_o ( stream_demux_checkout_queue_chiplet_dep_set_oup_valid[core][cluster]    ),
                .oup_ready_i ( stream_demux_checkout_queue_chiplet_dep_set_oup_ready[core][cluster]    )
            );

            assign stream_demux_checkout_queue_chiplet_dep_set_inp_valid[core][cluster] = !checkout_queue_empty[core][cluster];
            assign stream_demux_checkout_queue_chiplet_dep_set_oup_sel[core][cluster] = 
                (checkout_queue_data_out[core][cluster].dep_set_info.dep_set_chiplet_id != chip_id_i);
            // To Chiplet Dep Set
            assign stream_demux_checkout_queue_chiplet_dep_set_oup_ready[core][cluster][1] = stream_arbiter_chiplet_dep_set_inp_ready[core + cluster * NUM_CORES_PER_CLUSTER];
            // To Local Dep Set
            assign stream_demux_checkout_queue_chiplet_dep_set_oup_ready[core][cluster][0] = stream_filter_checkout_queue_dep_set_enable_inp_ready[core][cluster];

            stream_filter i_stream_filter_checkout_queue_dep_set_enable (
                .valid_i ( stream_filter_checkout_queue_dep_set_enable_inp_valid[core][cluster]    ),
                .ready_o ( stream_filter_checkout_queue_dep_set_enable_inp_ready[core][cluster]    ),
                .drop_i  ( stream_filter_checkout_queue_dep_set_enable_drop[core][cluster]         ),
                .valid_o ( stream_filter_checkout_queue_dep_set_enable_oup_valid[core][cluster]    ),
                .ready_i ( stream_filter_checkout_queue_dep_set_enable_oup_ready[core][cluster]    )
            );
            assign stream_filter_checkout_queue_dep_set_enable_inp_valid[core][cluster] = stream_demux_checkout_queue_chiplet_dep_set_oup_valid[core][cluster][0];
            // Only drop the signal when dep set is disabled and the per-(core,cluster) done queue is non-empty
            assign stream_filter_checkout_queue_dep_set_enable_drop[core][cluster] =
                (checkout_queue_data_out[core][cluster].dep_set_info.dep_set_en == 1'b0) &&
                (!done_q_empty[core][cluster]);
            assign stream_filter_checkout_queue_dep_set_enable_oup_ready[core][cluster] = stream_arbiter_dep_matrix_set_inp_ready[core + cluster * NUM_CORES_PER_CLUSTER];

        end
    end

    //////////////////////////////////////////////////////////////////////
    // Local Per-Core Done Queues
    //////////////////////////////////////////////////////////////////////
    // Each core has its own done queue FIFO. This eliminates HOL blocking
    // where one core's completion stalls behind another core's entry in a
    // shared FIFO. Completions for different cores drain independently.

    if (READY_AND_DONE_QUEUE_INTERFACE_TYPE==0) begin: gen_done_queue_axi_lite_mailbox
        // AXI-Lite mailbox mode: single mailbox writes into a shared FIFO,
        // then we demux to per-(core,cluster) FIFOs based on done_info fields.
        bingo_hw_manager_write_mailbox #(
            .MailboxDepth(DoneQueueDepth               ),
            .IrqEdgeTrig (1'b0                         ),
            .IrqActHigh  (1'b1                         ),
            .AxiAddrWidth(DeviceAxiLiteAddrWidth       ),
            .AxiDataWidth(DeviceAxiLiteDataWidth       ),
            .ChipIdWidth (ChipIdWidth                  ),
            .req_lite_t  (device_axi_lite_req_t        ),
            .resp_lite_t (device_axi_lite_resp_t       )
        ) i_bingo_hw_manager_done_queue (
            .clk_i       (clk_i                     ),
            .rst_ni      (rst_ni                    ),
            .chip_id_i   (chip_id_i                 ),
            .test_i      (1'b0                      ),
            .req_i       (done_queue_axi_lite_req_i ),
            .resp_o      (done_queue_axi_lite_resp_o),
            .irq_o       (),
            .base_addr_i (done_queue_base_addr_i    ),
            .mbox_data_o (done_queue_mbox_data      ),
            .mbox_pop_i  (done_queue_mbox_pop       ),
            .mbox_empty_o(done_queue_mbox_empty     ),
            .mbox_flush_i(1'b0)
        );
        assign cur_done_queue_info_axi = bingo_hw_manager_done_info_full_t'(done_queue_mbox_data);
        // Pop the mailbox when the target per-(core,cluster) FIFO accepts it
        assign done_queue_mbox_pop = !done_queue_mbox_empty &&
                                     !done_q_full[cur_done_queue_info_axi.assigned_core_id][cur_done_queue_info_axi.assigned_cluster_id];
        // Route mailbox data to per-(core,cluster) FIFOs
        always_comb begin
            for (int c = 0; c < NUM_CORES_PER_CLUSTER; c++) begin
                for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
                    done_q_data_in[c][cl] = cur_done_queue_info_axi;
                    done_q_push[c][cl] = done_queue_mbox_pop &&
                        (cur_done_queue_info_axi.assigned_core_id == bingo_hw_manager_assigned_core_id_t'(c)) &&
                        (cur_done_queue_info_axi.assigned_cluster_id == bingo_hw_manager_assigned_cluster_id_t'(cl));
                end
            end
        end
    end else begin: gen_done_queue_generic_fifo
        // Generic FIFO mode: CSR writes go through arbiter, then demux to per-(core,cluster) FIFOs.
        assign done_queue_axi_lite_resp_o = '0;
        assign done_queue_mbox_empty = 1'b1;
        assign done_queue_mbox_data = '0;
        assign done_queue_mbox_pop = 1'b0;
    end

    // Per-(core, cluster) done queue FIFO instantiation
    for (genvar core = 0; core < NUM_CORES_PER_CLUSTER; core++) begin: gen_done_q_core
        for (genvar cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster++) begin: gen_done_q_cluster
            fifo_v3 #(
                .FALL_THROUGH ( 1'b0                               ),
                .DEPTH        ( DoneQueueDepth                     ),
                .dtype        ( bingo_hw_manager_done_info_full_t  )
            ) i_done_q (
                .clk_i       ( clk_i                            ),
                .rst_ni      ( rst_ni                           ),
                .testmode_i  ( 1'b0                             ),
                .flush_i     ( 1'b0                             ),
                .full_o      ( done_q_full[core][cluster]       ),
                .empty_o     ( done_q_empty[core][cluster]      ),
                .usage_o     ( /*not used*/                     ),
                .data_i      ( done_q_data_in[core][cluster]    ),
                .push_i      ( done_q_push[core][cluster]       ),
                .data_o      ( done_q_info[core][cluster]       ),
                .pop_i       ( done_q_pop[core][cluster]        )
            );
        end
    end

    // Per-(core, cluster) done queue pop logic:
    // Pop when the checkout queue head for this (core, cluster) is a normal task
    // AND the arbiter accepted the dep_set. No cross-core or cross-cluster blocking.
    always_comb begin
        for (int core = 0; core < NUM_CORES_PER_CLUSTER; core++) begin
            for (int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster++) begin
                // Normal (2'b00) and gating (2'b10) tasks need done_queue match
                done_q_pop[core][cluster] = !done_q_empty[core][cluster] &&
                    (checkout_queue_data_out[core][cluster].task_type == 2'b00 ||
                     checkout_queue_data_out[core][cluster].task_type == 2'b10) &&
                    stream_arbiter_dep_matrix_set_inp_ready[core + cluster * NUM_CORES_PER_CLUSTER];
            end
        end
    end

    // For generic FIFO done queue, we need to connect the CSR interface signals
    if (READY_AND_DONE_QUEUE_INTERFACE_TYPE==1) begin: gen_csr_to_fifo_intf
        localparam N_CORES_TOTAL = NUM_CLUSTERS_PER_CHIPLET * NUM_CORES_PER_CLUSTER;
        // 1D CSR Requests
        csr_req_t [N_CORES_TOTAL-1:0] csr_req_1d;
        logic     [N_CORES_TOTAL-1:0] csr_req_valid_1d;
        logic     [N_CORES_TOTAL-1:0] csr_req_ready_1d;
        csr_rsp_t [N_CORES_TOTAL-1:0] csr_rsp_1d;
        logic     [N_CORES_TOTAL-1:0] csr_rsp_valid_1d;
        logic     [N_CORES_TOTAL-1:0] csr_rsp_ready_1d;
        // 1D Ready Queue FIFO Interface
        device_axi_lite_data_t [N_CORES_TOTAL-1:0] read_ready_queue_data_1d;
        logic                  [N_CORES_TOTAL-1:0] read_ready_queue_valid_1d;
        logic                  [N_CORES_TOTAL-1:0] read_ready_queue_ready_1d;
        // 1D Done QUeue FIFO Interface
        device_axi_lite_data_t [N_CORES_TOTAL-1:0] write_done_queue_data_1d;
        logic                  [N_CORES_TOTAL-1:0] write_done_queue_valid_1d;
        logic                  [N_CORES_TOTAL-1:0] write_done_queue_ready_1d;
        device_axi_lite_data_t write_done_queue_data;
        logic                  write_done_queue_valid;
        logic                  write_done_queue_ready;


        bingo_hw_manager_csr_to_fifo #(
            .TaskIdWidth (TaskIdWidth),
            .N (N_CORES_TOTAL),
            .NUM_CORES_PER_CLUSTER (NUM_CORES_PER_CLUSTER),
            .NUM_CLUSTERS_PER_CHIPLET (NUM_CLUSTERS_PER_CHIPLET),
            .csr_req_t (csr_req_t),
            .csr_rsp_t (csr_rsp_t),
            .data_t    (device_axi_lite_data_t),
            .bingo_hw_manager_done_info_full_t (bingo_hw_manager_done_info_full_t)
        ) i_bingo_hw_manager_csr_to_fifo (
            .csr_req_i         (csr_req_1d               ),
            .csr_req_valid_i   (csr_req_valid_1d         ),
            .csr_req_ready_o   (csr_req_ready_1d         ),
            .csr_rsp_o         (csr_rsp_1d               ),
            .csr_rsp_valid_o   (csr_rsp_valid_1d         ),
            .csr_rsp_ready_i   (csr_rsp_ready_1d         ),
            // FIFO Read Interface
            .fifo_data_i       (read_ready_queue_data_1d ),
            .fifo_data_valid_i (read_ready_queue_valid_1d),
            .fifo_data_ready_o (read_ready_queue_ready_1d),
            // FIFO Write Interface
            .fifo_data_o       (write_done_queue_data_1d ),
            .fifo_data_valid_o (write_done_queue_valid_1d),
            .fifo_data_ready_i (write_done_queue_ready_1d)
        );
        always_comb begin : connect_ready_queue_1d_to_2d
            for (int unsigned core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
                for (int unsigned cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin
                    csr_req_1d[core + cluster * NUM_CORES_PER_CLUSTER] = csr_req_i[core][cluster];
                    csr_req_valid_1d[core + cluster * NUM_CORES_PER_CLUSTER] = csr_req_valid_i[core][cluster];
                    csr_req_ready_o[core][cluster] = csr_req_ready_1d[core + cluster * NUM_CORES_PER_CLUSTER];
                    csr_rsp_o[core][cluster] = csr_rsp_1d[core + cluster * NUM_CORES_PER_CLUSTER];
                    csr_rsp_valid_o[core][cluster] = csr_rsp_valid_1d[core + cluster * NUM_CORES_PER_CLUSTER];
                    csr_rsp_ready_1d[core + cluster * NUM_CORES_PER_CLUSTER] = csr_rsp_ready_i[core][cluster];
                    read_ready_queue_data_1d[core + cluster * NUM_CORES_PER_CLUSTER] = device_axi_lite_data_t'(ready_queue_data_out[core][cluster]);
                    read_ready_queue_valid_1d[core + cluster * NUM_CORES_PER_CLUSTER] = !ready_queue_empty[core][cluster];
                    ready_queue_pop[core][cluster] = read_ready_queue_ready_1d[core + cluster * NUM_CORES_PER_CLUSTER] && !ready_queue_empty[core][cluster];
                end
            end
        end
        // Connect to the core_status_waiting_task
        // This signal indicates whether the core is waiting for a task to be read from the ready queue
        // If csr_req_i.write==0 and csr_req_valid_i is high and csr_req_ready_o is low, it means the core is waiting for a task
        always_comb begin : connect_core_status_waiting_task_signals
            for ( int core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
                for ( int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin
                    core_status_waiting_task[core][cluster] = (csr_req_i[core][cluster].write == 1'b0) &&
                                                              csr_req_valid_i[core][cluster] &&
                                                              !csr_req_ready_o[core][cluster];
                end
            end
        end

        // For the Done Queue, we arbitrate all cores' write requests, then demux
        // the result to per-core FIFOs based on assigned_core_id in the data.
        stream_arbiter #(
            .DATA_T(device_axi_lite_data_t),
            .N_INP (N_CORES_TOTAL)
        ) i_stream_arbiter_done_queue_write (
            .clk_i      (clk_i),
            .rst_ni     (rst_ni),
            .inp_data_i (write_done_queue_data_1d),
            .inp_valid_i(write_done_queue_valid_1d),
            .inp_ready_o(write_done_queue_ready_1d),
            .oup_data_o (write_done_queue_data),
            .oup_valid_o(write_done_queue_valid),
            .oup_ready_i(write_done_queue_ready)
        );
        // Extract core_id + cluster_id from the arbitrated done_info to route to per-(core,cluster) FIFO
        bingo_hw_manager_done_info_full_t write_done_info;
        assign write_done_info = bingo_hw_manager_done_info_full_t'(write_done_queue_data);
        // Route to per-(core, cluster) done queue FIFOs
        always_comb begin
            for (int c = 0; c < NUM_CORES_PER_CLUSTER; c++) begin
                for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
                    done_q_data_in[c][cl] = write_done_info;
                    done_q_push[c][cl] = write_done_queue_valid &&
                        (write_done_info.assigned_core_id == bingo_hw_manager_assigned_core_id_t'(c)) &&
                        (write_done_info.assigned_cluster_id == bingo_hw_manager_assigned_cluster_id_t'(cl)) &&
                        !done_q_full[c][cl];
                end
            end
        end
        assign write_done_queue_ready = !done_q_full[write_done_info.assigned_core_id][write_done_info.assigned_cluster_id];


    end else begin: gen_no_csr_to_fifo_intf
        // If it is AXI Lite Mailbox interface, the ready queue and done queue interface are already connected
        // So we do not need to do anything here
        // Tie the csr signals to zero
        assign csr_req_ready_o = '0;
        assign csr_rsp_o = '0;
        assign csr_rsp_valid_o = '0;
    end

    //////////////////////////////////////////////////////////////////////
    // Power Manager
    //////////////////////////////////////////////////////////////////////
    bingo_hw_manager_pm #(
        .NUM_CLUSTERS_PER_CHIPLET ( NUM_CLUSTERS_PER_CHIPLET          ),
        .NUM_CORES_PER_CLUSTER    ( NUM_CORES_PER_CLUSTER             ),
        .CfgBusWidth              ( DeviceAxiLiteDataWidth            ),
        .HOST_DVFS_MSIP_BIT       ( HOST_DVFS_MSIP_BIT                ),
        .req_lite_t               ( host_axi_lite_req_t               ),
        .resp_lite_t              ( host_axi_lite_resp_t              ),
        .addr_t                   ( host_axi_lite_addr_t              ),
        .data_t                   ( host_axi_lite_data_t              )
    ) i_bingo_hw_manager_pm (
        .clk_i                 ( clk_i                                 ),
        .rst_ni                ( rst_ni                                ),
        // Configuration from the host
        .enable_idle_pm_i      ( bingo_hw_manager_enable_idle_pm_i      ),
        .idle_power_level_i    ( bingo_hw_manager_idle_power_level_i    ),
        .normal_power_level_i  ( bingo_hw_manager_normal_power_level_i  ),
        .pm_base_addr_i        ( bingo_hw_manager_pm_base_addr_i        ),
        .core_power_domain_i   ( bingo_hw_manager_core_power_domain_i   ),
        // Internal Core status
        .core_status_waiting_task_i ( core_status_waiting_task         ),
        // DVFS mode: monitor + notify host
        .pm_mode_i             ( bingo_hw_manager_pm_mode_i             ),
        .dvfs_clint_msip_addr_i( bingo_hw_manager_dvfs_clint_msip_addr_i),
        .dvfs_ack_i            ( bingo_hw_manager_dvfs_ack_i            ),
        .dvfs_request_o        ( bingo_hw_manager_dvfs_request_o        ),
        // Interface to Host AXI Lite
        .pm_axi_lite_req_o     (pm_axi_lite_req_o                      ),
        .pm_axi_lite_resp_i    (pm_axi_lite_resp_i                     )
    );

    //////////////////////////////////////////////////////////////////////
    // DARTS Tier 3: Load Monitor
    //////////////////////////////////////////////////////////////////////
    bingo_hw_manager_load_monitor #(
        .NumCores   (NUM_CORES_PER_CLUSTER),
        .NumClusters(NUM_CLUSTERS_PER_CHIPLET),
        .CounterWidth(8)
    ) i_load_monitor (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .task_dispatched_i  (ready_queue_pop),
        .task_done_i        (done_q_push),
        .pending_per_core_o (/* CSR readable — connect when needed */),
        .total_pending_o    (load_total_pending_o)
    );

    //////////////////////////////////////////////////////////////////////
    // DARTS Tier 1: Conditional Execution Register File (CERF)
    //////////////////////////////////////////////////////////////////////

    bingo_hw_manager_cond_exec_controller #(
        .NumGroups(32)
    ) i_cerf (
        .clk_i            ( clk_i                  ),
        .rst_ni           ( rst_ni                 ),
        .cerf_state_o     ( cerf_state             ),
        .cerf_write_data_i( cerf_write_data_i      ),
        .cerf_write_en_i  ( cerf_write_en_i        )
    );

endmodule
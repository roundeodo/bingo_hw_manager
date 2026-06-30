// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Xiaoling Yi  <xiaoling.yi@kuleuven.be>
// - Yunhao Deng  <yunhao.deng@kuleuven.be>


// This module issues the ar/r requests to read the task decriptor from the task_list_base_addr_i with num_task_i

module bingo_hw_manager_task_queue_master #(
    parameter int unsigned TaskQueueDepth = 16,
    parameter int unsigned TaskIdWidth = 12,
    parameter int unsigned CfgBusWidth = 32,
    parameter type     req_lite_t   = logic,
    parameter type     resp_lite_t  = logic,
    parameter type     addr_t       = logic,
    parameter type     data_t       = logic
) (
    input  logic       clk_i,   // Clock
    input  logic       rst_ni,  // Asynchronous reset active low
    input  addr_t                  task_list_base_addr_i,  // The task list base address specified by the host
    input  logic [CfgBusWidth-1:0] num_task_i,       // The number of tasks specified by the host
    input  logic [CfgBusWidth-1:0] start_i,          // Start signal
    input  logic                   flush_i,          // Phase flush signal
    output logic [CfgBusWidth-1:0] reset_start_o,    // Reset start signal to zero
    output logic                   reset_start_en_o, // Reset start enable signal
    // AXI Lite Master Interface to get task 
    output req_lite_t              task_queue_axi_lite_req_o,
    input  resp_lite_t             task_queue_axi_lite_resp_i,
    // Received task descriptor to internal Bingo HW Manager modules
    // Standard FIFO Interface
    output data_t                  task_queue_data_o,
    input  logic                   task_queue_pop_i,
    output logic                   task_queue_empty_o
);

    typedef enum logic [1:0]{
        IDLE,
        SEND_AR,
        WAIT_R,
        FINISH
    } task_queue_master_fsm_t;    
    task_queue_master_fsm_t cur_state, next_state;
    //////////////////////////////
    // Task Queue FIFO signals
    //////////////////////////////
    logic       task_queue_full;
    logic       task_queue_push;
    data_t      task_queue_data_in;

    //////////////////////////////
    // Counter signals
    //////////////////////////////
    logic                   task_counter_en;
    logic                   task_counter_clear;
    logic [TaskIdWidth-1:0] task_counter_q;
    counter #(
        .WIDTH ( TaskIdWidth )
    ) i_task_counter (
        .clk_i          ( clk_i                     ),
        .rst_ni         ( rst_ni                    ),
        .clear_i        ( task_counter_clear        ),
        .en_i           ( task_counter_en           ),
        .load_i         ( 1'b0                      ),
        .down_i         ( 1'b0                      ),
        .d_i            ( '0                        ),
        .q_o            ( task_counter_q            ),
        .overflow_o     ( /*not used*/              )
    );


    fifo_v3 #(
        .FALL_THROUGH ( 1'b0                   ),
        .DEPTH        ( TaskQueueDepth         ),
        .dtype        ( data_t                 )
    ) i_task_queue (
        .clk_i       ( clk_i                ),
        .rst_ni      ( rst_ni               ),
        .testmode_i  ( 1'b0                 ),
        .flush_i     ( flush_i              ),
        .full_o      ( task_queue_full      ),
        .empty_o     ( task_queue_empty_o   ),
        .usage_o     ( /*not used*/         ),
        .data_i      ( task_queue_data_in   ),
        .push_i      ( task_queue_push      ),
        .data_o      ( task_queue_data_o    ),
        .pop_i       ( task_queue_pop_i     )
    );
    // We do not need the write channels for the task queue master
    always_comb begin : tie_off_write_channels
        task_queue_axi_lite_req_o.w = '0;
        task_queue_axi_lite_req_o.w_valid = 1'b0;
        task_queue_axi_lite_req_o.aw = '0;
        task_queue_axi_lite_req_o.aw_valid = 1'b0;
        task_queue_axi_lite_req_o.b_ready = 1'b0;
    end

    // State Update
    always_ff @(posedge clk_i, negedge rst_ni) begin
        if (!rst_ni) begin
            cur_state <= IDLE;
        end else begin
            cur_state <= next_state;
        end
    end

    // Next State Logic
    always_comb begin : task_queue_master_fsm_next_state_logic
        // Default values
        next_state = cur_state;
        case (cur_state)
            IDLE: begin
                if (start_i) begin
                    next_state = SEND_AR;
                end
            end
            SEND_AR: begin
                if (task_queue_axi_lite_req_o.ar_valid && task_queue_axi_lite_resp_i.ar_ready) begin
                    next_state = WAIT_R;
                end
            end
            WAIT_R: begin
                if (task_queue_axi_lite_resp_i.r_valid && task_queue_axi_lite_req_o.r_ready) begin
                    if (task_counter_q == (num_task_i - 1)) begin
                        next_state = FINISH;
                    end else begin
                        next_state = SEND_AR;
                    end
                end
            end
            FINISH: begin
                next_state = IDLE;
            end
            default: begin
                next_state = IDLE;
            end
        endcase
    end

    // Output Logic
    always_comb begin : task_queue_master_fsm_output_logic
        // Default values
        task_queue_axi_lite_req_o.ar = '0;
        task_queue_axi_lite_req_o.ar_valid = 1'b0;
        task_counter_en = 1'b0;
        task_counter_clear = 1'b0;
        reset_start_o = '0;
        reset_start_en_o = 1'b0;
        case (cur_state)
            IDLE: begin
                task_queue_axi_lite_req_o.ar = '0;
                task_queue_axi_lite_req_o.ar_valid = 1'b0;
                task_counter_en = 1'b0;
                task_counter_clear = 1'b0;                
            end
            SEND_AR: begin
                task_queue_axi_lite_req_o.ar.addr = task_list_base_addr_i + (task_counter_q * $size(data_t)/8);
                task_queue_axi_lite_req_o.ar.prot = 3'b000;
                task_queue_axi_lite_req_o.ar_valid = 1'b1;
                task_counter_en = 1'b0;
                task_counter_clear = 1'b0;
                reset_start_o = '0;
                reset_start_en_o = 1'b0;
            end
            WAIT_R: begin
                task_counter_en = task_queue_axi_lite_resp_i.r_valid && task_queue_axi_lite_req_o.r_ready;
            end
            FINISH: begin
                task_queue_axi_lite_req_o.ar = '0;
                task_queue_axi_lite_req_o.ar_valid = 1'b0;
                task_counter_en = 1'b0;
                task_counter_clear = 1'b1;
                reset_start_o = '0;
                reset_start_en_o = 1'b1;
            end
        endcase
    end
    // Compose the R channel to the task queue fifo
    assign task_queue_axi_lite_req_o.r_ready = ~task_queue_full;
    assign task_queue_push = task_queue_axi_lite_resp_i.r_valid && ~task_queue_full;
    assign task_queue_data_in = task_queue_axi_lite_resp_i.r.data;
endmodule

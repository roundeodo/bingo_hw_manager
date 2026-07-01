// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Xiaoling Yi  <xiaoling.yi@kuleuven.be>
// - Yunhao Deng  <yunhao.deng@kuleuven.be>


// This module is the interface from the core CSR req/rsp to write the FIFO
module bingo_hw_manager_csr_to_fifo_write #(
    parameter type data_t = logic
) (
    // CSR req
    input  data_t           csr_req_data_i,
    input  logic            csr_req_valid_i,
    output logic            csr_req_ready_o,
    // FIFO interface
    output data_t           fifo_data_o,
    output logic            fifo_data_valid_o,
    input  logic            fifo_data_ready_i
);
    assign fifo_data_o = csr_req_data_i;
    assign fifo_data_valid_o = csr_req_valid_i;
    assign csr_req_ready_o = fifo_data_ready_i;
endmodule

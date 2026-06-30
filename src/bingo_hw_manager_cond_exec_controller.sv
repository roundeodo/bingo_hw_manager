// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>

// DARTS Tier 1: Conditional Execution Register File (CERF)
//
// A register file that stores activation status for up to NumGroups
// "conditional execution groups." Each group corresponds to a logical unit
// (e.g., one expert in MoE, one exit branch in early exit).
//
// The scheduler queries the CERF combinationally to decide whether a
// conditionally-annotated task should execute or be skipped. Skipped
// tasks still propagate their dependency signals (via the checkout queue)
// but are never dispatched to a core.
//
// Write interface: single 32-bit bitmask write. SW writes the full
// CERF_STATE CSR and pulses CERF_WRITE_EN to latch the value.
// Clearing is simply writing 0.

module bingo_hw_manager_cond_exec_controller #(
    parameter int unsigned NumGroups = 32
) (
    input  logic                          clk_i,
    input  logic                          rst_ni,
    // Full state output (combinational)
    output logic [NumGroups-1:0]          cerf_state_o,
    // Write port: 32-bit bitmask + enable
    input  logic [NumGroups-1:0]          cerf_write_data_i,
    input  logic                          cerf_write_en_i
);
    logic [NumGroups-1:0] cerf_q;

    // Combinational full-state output
    assign cerf_state_o = cerf_q;

    // Sequential write: latch entire bitmask on write_en.
    // DARTS default: all groups active until SW writes a new bitmask.
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            cerf_q <= '1;
        end else if (cerf_write_en_i) begin
            cerf_q <= cerf_write_data_i;
        end
    end
endmodule

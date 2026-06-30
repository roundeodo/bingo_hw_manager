module bingo_hw_manager_cond_exec_filter #(
    parameter int unsigned CerfWidth = 32,
    parameter int unsigned GroupIdWidth = 5,
    localparam int unsigned CerfIndexWidth = (CerfWidth <= 1) ? 1 : $clog2(CerfWidth)
) (
    input  logic                          task_valid_i,
    input  logic                          cond_exec_en_i,
    input  logic [GroupIdWidth-1:0]       cond_exec_group_id_i,
    input  logic                          cond_exec_invert_i,
    input  logic [CerfWidth-1:0]          cerf_state_i,
    output logic                          cond_exec_skip_o
);

    logic cerf_bit;
    logic condition_true;

    always_comb begin
        cerf_bit = 1'b0;
        if (cond_exec_group_id_i < CerfWidth) begin
            cerf_bit = cerf_state_i[cond_exec_group_id_i[CerfIndexWidth-1:0]];
        end

        condition_true = cond_exec_invert_i ? ~cerf_bit : cerf_bit;
        cond_exec_skip_o = task_valid_i && cond_exec_en_i && !condition_true;
    end

endmodule

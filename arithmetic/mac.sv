module mac #(
    parameter int A_WIDTH = 8,
    parameter int B_WIDTH = 8,
    parameter int ACC_WIDTH = 32,
    parameter bit PIPELINE = 1
)(
    input  logic clk,
    input  logic rst_n,
    input  logic en,
    input  logic clear,
    input  logic signed [A_WIDTH-1:0] a,
    input  logic signed [B_WIDTH-1:0] b,
    output logic signed [ACC_WIDTH-1:0] acc_out
);

    logic signed [A_WIDTH+B_WIDTH-1:0] mult_result;
    logic signed [ACC_WIDTH-1:0] acc_reg;
    logic signed [ACC_WIDTH-1:0] acc_next;

    assign mult_result = a * b;

    always_comb begin
        if (clear)
            acc_next = '0;
        else if (en)
            acc_next = acc_reg + mult_result;
        else
            acc_next = acc_reg;
    end

    generate
        if (PIPELINE) begin : PIPELINED
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    acc_reg <= '0;
                else
                    acc_reg <= acc_next;
            end
        end else begin : NON_PIPELINED
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    acc_reg <= '0;
                else if (en || clear)
                    acc_reg <= acc_next;
            end
        end
    endgenerate

    assign acc_out = acc_reg;

endmodule

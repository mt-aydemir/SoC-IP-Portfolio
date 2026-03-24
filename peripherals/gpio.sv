module gpio #(
    parameter WIDTH = 8
)(
    input  logic             clk,
    input  logic             rst_n,
    input  logic             wr_en,
    input  logic             wr_dir,
    input  logic [WIDTH-1:0] wr_data,
    input  logic [WIDTH-1:0] pin_in,
    output logic [WIDTH-1:0] pin_out,
    output logic [WIDTH-1:0] pin_oe
);

    logic [WIDTH-1:0] data_reg;
    logic [WIDTH-1:0] dir_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_reg <= '0;
            dir_reg  <= '0;
        end
        else if (wr_en) begin
            if (wr_dir) dir_reg  <= wr_data;
            else        data_reg <= wr_data;
        end
    end

    assign pin_out = data_reg & dir_reg;
    assign pin_oe  = dir_reg;

endmodule
module register_file #(
    parameter WIDTH = 32,
    parameter DEPTH = 8,
    parameter ADDR_WIDTH = $clog2(DEPTH)
)(
    input  logic                  clk,
    input  logic                  reset,

    input  logic [ADDR_WIDTH-1:0] waddr,
    input  logic [WIDTH-1:0]      wdata,
    input  logic                  we,

    input  logic [ADDR_WIDTH-1:0] raddr,
    output logic [WIDTH-1:0]      rdata,
    input  logic                  re
);

    logic [WIDTH-1:0] regs [0:DEPTH-1];

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            integer i;
            for (i = 0; i < DEPTH; i++) begin
                regs[i] <= '0;
            end
        end else if (we) begin
            regs[waddr] <= wdata;
        end
    end

    always_ff @(posedge clk) begin
        if (re) begin
            rdata <= regs[raddr];
        end else begin
            rdata <= '0;
        end
    end

endmodule
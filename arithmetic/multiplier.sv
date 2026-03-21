module multiplier #(
    parameter WIDTH = 8
)(
    input  logic [WIDTH-1:0]   a,
    input  logic [WIDTH-1:0]   b,
    output logic [2*WIDTH-1:0] product
);
 
    assign product = a * b;
 
endmodule
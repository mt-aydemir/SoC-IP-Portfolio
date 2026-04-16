module cordic #(
    parameter int WIDTH = 32,
    parameter int ITERATIONS = 16
) (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 valid_in,
    input  logic [WIDTH-1:0]     x_in,
    input  logic [WIDTH-1:0]     y_in,
    input  logic [WIDTH-1:0]     z_in,
    input  logic [1:0]           mode,
    output logic [WIDTH-1:0]     x_out,
    output logic [WIDTH-1:0]     y_out,
    output logic [WIDTH-1:0]     z_out,
    output logic                 valid_out
);

    localparam real K = 0.6072529350088812;
    
    logic [WIDTH-1:0] x [ITERATIONS+1];
    logic [WIDTH-1:0] y [ITERATIONS+1];
    logic [WIDTH-1:0] z [ITERATIONS+1];
    logic [ITERATIONS:0] valid;
    logic [1:0] mode_pipe [ITERATIONS];

    assign x[0] = x_in;
    assign y[0] = y_in;
    assign z[0] = z_in;
    assign valid[0] = valid_in;
    assign mode_pipe[0] = mode;

    genvar i;
    generate
        for (i = 0; i < ITERATIONS; i++) begin : cordic_stage
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    x[i+1] <= '0;
                    y[i+1] <= '0;
                    z[i+1] <= '0;
                    valid[i+1] <= '0;
                    if (i < ITERATIONS-1) mode_pipe[i+1] <= '0;
                end else if (valid[i]) begin
                    logic signed [WIDTH-1:0] x_shifted, y_shifted;
                    logic sigma;

                    x_shifted = x[i] >>> i;
                    y_shifted = y[i] >>> i;

                    if (mode_pipe[i] == 2'b00) begin
                        sigma = z[i][WIDTH-1];
                        x[i+1] <= sigma ? (x[i] + y_shifted) : (x[i] - y_shifted);
                        y[i+1] <= sigma ? (y[i] - x_shifted) : (y[i] + x_shifted);
                        z[i+1] <= sigma ? (z[i] + cordic_angle(i)) : (z[i] - cordic_angle(i));
                    end else begin
                        sigma = y[i][WIDTH-1];
                        x[i+1] <= sigma ? (x[i] - y_shifted) : (x[i] + y_shifted);
                        y[i+1] <= sigma ? (y[i] + x_shifted) : (y[i] - x_shifted);
                        z[i+1] <= sigma ? (z[i] + cordic_angle(i)) : (z[i] - cordic_angle(i));
                    end
                    valid[i+1] <= 1'b1;
                    if (i < ITERATIONS-1) mode_pipe[i+1] <= mode_pipe[i];
                end
            end
        end
    endgenerate

    assign x_out = x[ITERATIONS];
    assign y_out = y[ITERATIONS];
    assign z_out = z[ITERATIONS];
    assign valid_out = valid[ITERATIONS];

    function logic [WIDTH-1:0] cordic_angle(input int iteration);
        case (iteration)
            0:  cordic_angle = 32'h2_C8CB_F0E8;
            1:  cordic_angle = 32'h1_76D0_47C4;
            2:  cordic_angle = 32'h0_ADCB_F0E7;
            3:  cordic_angle = 32'h0_56F8_AC81;
            4:  cordic_angle = 32'h0_2B75_D85F;
            5:  cordic_angle = 32'h0_15BA_9796;
            6:  cordic_angle = 32'h0_0ADD_95DF;
            7:  cordic_angle = 32'h0_056E_1FB1;
            8:  cordic_angle = 32'h0_02B7_A0E0;
            default: cordic_angle = '0;
        endcase
    endfunction

endmodule
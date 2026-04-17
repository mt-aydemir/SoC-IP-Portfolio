module uart #(
    parameter CLK_FREQ   = 50_000_000,
    parameter BAUD_RATE  = 115200,       
    parameter DATA_BITS  = 8,
    parameter STOP_BITS  = 1,             
    parameter PARITY     = "NONE"
)(
    input  logic clk,
    input  logic reset,

    input  logic [DATA_BITS-1:0] tx_data,
    input  logic                 tx_valid,
    output logic                 tx_ready,
    output logic                 txd,

    output logic [DATA_BITS-1:0] rx_data,
    output logic                 rx_valid,
    input  logic                 rxd
);

    localparam integer BAUD_DIV = CLK_FREQ / BAUD_RATE;

    // TX
    logic [15:0] tx_cnt;
    logic [DATA_BITS+STOP_BITS:0] tx_shift;
    logic tx_busy;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            tx_cnt   <= 0;
            tx_shift <= {DATA_BITS+STOP_BITS+1{1'b1}};
            tx_busy  <= 0;
            tx_ready <= 1;
            txd      <= 1;
        end else begin
            if (tx_valid && tx_ready) begin
                tx_shift <= { {STOP_BITS{1'b1}}, tx_data, 1'b0 };
                tx_cnt   <= 0;
                tx_busy  <= 1;
                tx_ready <= 0;
            end else if (tx_busy) begin
                if (tx_cnt == BAUD_DIV-1) begin
                    tx_cnt   <= 0;
                    txd      <= tx_shift[0];
                    tx_shift <= {1'b1, tx_shift[DATA_BITS+STOP_BITS:1]};
                    if (tx_shift == {DATA_BITS+STOP_BITS+1{1'b1}}) begin
                        tx_busy  <= 0;
                        tx_ready <= 1;
                    end
                end else begin
                    tx_cnt <= tx_cnt + 1;
                end
            end
        end
    end

    // RX
    logic [15:0] rx_cnt;
    logic [DATA_BITS-1:0] rx_shift;
    logic [3:0]  rx_bitcnt;
    logic        rx_busy;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            rx_cnt    <= 0;
            rx_shift  <= 0;
            rx_bitcnt <= 0;
            rx_busy   <= 0;
            rx_valid  <= 0;
            rx_data   <= 0;
        end else begin
            rx_valid <= 0;
            if (!rx_busy) begin
                if (!rxd) begin
                    rx_busy   <= 1;
                    rx_cnt    <= BAUD_DIV/2;
                    rx_bitcnt <= 0;
                end
            end else begin
                if (rx_cnt == BAUD_DIV-1) begin
                    rx_cnt <= 0;
                    rx_shift <= {rxd, rx_shift[DATA_BITS-1:1]};
                    rx_bitcnt <= rx_bitcnt + 1;
                    if (rx_bitcnt == DATA_BITS) begin
                        rx_data  <= rx_shift;
                        rx_valid <= 1;
                        rx_busy  <= 0;
                    end
                end else begin
                    rx_cnt <= rx_cnt + 1;
                end
            end
        end
    end

endmodule
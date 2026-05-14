module spi_master #(
    parameter int unsigned DATA_WIDTH = 8,
    parameter int unsigned CLK_DIV    = 4,  // sys_clk cycles per half SCLK
    parameter bit          CPOL       = 1'b0,
    parameter bit          CPHA       = 1'b0,
    parameter bit          MSB_FIRST  = 1'b1
) (
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          start,
    input  logic [DATA_WIDTH-1:0]         tx_data,
    output logic [DATA_WIDTH-1:0]         rx_data,
    output logic                          busy,
    output logic                          done,
    output logic                          sclk,
    output logic                          mosi,
    input  logic                          miso,
    output logic                          cs_n
);
    localparam int unsigned LAST_BIT = DATA_WIDTH - 1;
    localparam int unsigned DIV_W    = (CLK_DIV > 1) ? $clog2(CLK_DIV) : 1;

    logic [DATA_WIDTH-1:0] tx_shift, rx_shift;
    logic [$clog2(DATA_WIDTH+1)-1:0] bit_cnt;
    logic [DIV_W-1:0] div_cnt;
    logic phase;
    logic [DATA_WIDTH-1:0] tx_shift_next;

    function automatic logic [DATA_WIDTH-1:0] shift_in(
        input logic [DATA_WIDTH-1:0] din,
        input logic                  bit_in
    );
        logic [DATA_WIDTH-1:0] tmp;
        begin
            if (MSB_FIRST) begin
                tmp = {din[DATA_WIDTH-2:0], bit_in};
            end else begin
                tmp = {bit_in, din[DATA_WIDTH-1:1]};
            end
            return tmp;
        end
    endfunction

    function automatic logic [DATA_WIDTH-1:0] shift_out(
        input logic [DATA_WIDTH-1:0] din
    );
        logic [DATA_WIDTH-1:0] tmp;
        begin
            if (MSB_FIRST) begin
                tmp = {din[DATA_WIDTH-2:0], 1'b0};
            end else begin
                tmp = {1'b0, din[DATA_WIDTH-1:1]};
            end
            return tmp;
        end
    endfunction

    always_comb begin
        tx_shift_next = shift_out(tx_shift);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy     <= 1'b0;
            done     <= 1'b0;
            cs_n     <= 1'b1;
            sclk     <= CPOL;
            mosi     <= 1'b0;
            tx_shift <= '0;
            rx_shift <= '0;
            rx_data  <= '0;
            bit_cnt  <= '0;
            div_cnt  <= '0;
            phase    <= 1'b0;
        end else begin
            done <= 1'b0;

            if (!busy) begin
                sclk <= CPOL;
                if (start) begin
                    busy     <= 1'b1;
                    cs_n     <= 1'b0;
                    tx_shift <= tx_data;
                    rx_shift <= '0;
                    bit_cnt  <= DATA_WIDTH[$clog2(DATA_WIDTH+1)-1:0];
                    div_cnt  <= '0;
                    phase    <= 1'b0;
                    mosi     <= MSB_FIRST ? tx_data[LAST_BIT] : tx_data[0];
                end
            end else begin
                if (div_cnt == CLK_DIV-1) begin
                    div_cnt <= '0;
                    sclk    <= ~sclk;

                    // phase==0: first edge in bit time, phase==1: second edge
                    phase <= ~phase;

                    if ((CPHA == 1'b0 && phase == 1'b0) || (CPHA == 1'b1 && phase == 1'b1)) begin
                        // Sample edge
                        rx_shift <= shift_in(rx_shift, miso);
                        bit_cnt  <= bit_cnt - 1'b1;

                        if (bit_cnt == 1) begin
                            busy    <= 1'b0;
                            cs_n    <= 1'b1;
                            sclk    <= CPOL;
                            rx_data <= shift_in(rx_shift, miso);
                            done    <= 1'b1;
                        end
                    end else begin
                        // Shift edge
                        tx_shift <= tx_shift_next;
                        mosi     <= MSB_FIRST ? tx_shift_next[LAST_BIT] : tx_shift_next[0];
                    end
                end else begin
                    div_cnt <= div_cnt + 1'b1;
                end
            end
        end
    end
endmodule

module spi_slave #(
    parameter int unsigned DATA_WIDTH = 8,
    parameter bit          CPOL       = 1'b0,
    parameter bit          CPHA       = 1'b0,
    parameter bit          MSB_FIRST  = 1'b1
) (
    input  logic                          rst_n,
    input  logic                          sclk,
    input  logic                          cs_n,
    input  logic                          mosi,
    output logic                          miso,
    input  logic [DATA_WIDTH-1:0]         tx_data,
    output logic [DATA_WIDTH-1:0]         rx_data,
    output logic                          rx_valid
);
    localparam int unsigned LAST_BIT = DATA_WIDTH - 1;
    localparam bit SAMPLE_POSEDGE = (CPHA == 1'b0) ? (CPOL == 1'b0) : (CPOL == 1'b1);
    localparam bit SHIFT_POSEDGE  = ~SAMPLE_POSEDGE;

    logic [DATA_WIDTH-1:0] tx_shift, rx_shift;
    logic [$clog2(DATA_WIDTH+1)-1:0] bit_cnt;
    logic [DATA_WIDTH-1:0] tx_shift_next;

    function automatic logic [DATA_WIDTH-1:0] shift_in(
        input logic [DATA_WIDTH-1:0] din,
        input logic                  bit_in
    );
        logic [DATA_WIDTH-1:0] tmp;
        begin
            if (MSB_FIRST) begin
                tmp = {din[DATA_WIDTH-2:0], bit_in};
            end else begin
                tmp = {bit_in, din[DATA_WIDTH-1:1]};
            end
            return tmp;
        end
    endfunction

    function automatic logic [DATA_WIDTH-1:0] shift_out(
        input logic [DATA_WIDTH-1:0] din
    );
        logic [DATA_WIDTH-1:0] tmp;
        begin
            if (MSB_FIRST) begin
                tmp = {din[DATA_WIDTH-2:0], 1'b0};
            end else begin
                tmp = {1'b0, din[DATA_WIDTH-1:1]};
            end
            return tmp;
        end
    endfunction

    always_comb begin
        tx_shift_next = shift_out(tx_shift);
    end

    always @(posedge cs_n or negedge rst_n) begin
        if (!rst_n) begin
            tx_shift <= '0;
            rx_shift <= '0;
            rx_data  <= '0;
            bit_cnt  <= '0;
            rx_valid <= 1'b0;
            miso     <= 1'b0;
        end else begin
            rx_valid <= 1'b0;
        end
    end

    always @(negedge cs_n or negedge rst_n) begin
        if (!rst_n) begin
            tx_shift <= '0;
            rx_shift <= '0;
            bit_cnt  <= '0;
            miso     <= 1'b0;
        end else begin
            tx_shift <= tx_data;
            rx_shift <= '0;
            bit_cnt  <= DATA_WIDTH[$clog2(DATA_WIDTH+1)-1:0];
            miso     <= MSB_FIRST ? tx_data[LAST_BIT] : tx_data[0];
        end
    end

    generate
        if (SAMPLE_POSEDGE) begin : g_sample_pos
            always @(posedge sclk or posedge cs_n or negedge rst_n) begin
                if (!rst_n || cs_n) begin
                    // no-op, frame init handled by CS blocks
                end else begin
                    rx_shift <= shift_in(rx_shift, mosi);
                    bit_cnt  <= bit_cnt - 1'b1;
                    if (bit_cnt == 1) begin
                        rx_data  <= shift_in(rx_shift, mosi);
                        rx_valid <= 1'b1;
                    end
                end
            end
        end else begin : g_sample_neg
            always @(negedge sclk or posedge cs_n or negedge rst_n) begin
                if (!rst_n || cs_n) begin
                    // no-op, frame init handled by CS blocks
                end else begin
                    rx_shift <= shift_in(rx_shift, mosi);
                    bit_cnt  <= bit_cnt - 1'b1;
                    if (bit_cnt == 1) begin
                        rx_data  <= shift_in(rx_shift, mosi);
                        rx_valid <= 1'b1;
                    end
                end
            end
        end
    endgenerate

    generate
        if (SHIFT_POSEDGE) begin : g_shift_pos
            always @(posedge sclk or posedge cs_n or negedge rst_n) begin
                if (!rst_n || cs_n) begin
                    // no-op, frame init handled by CS blocks
                end else begin
                    tx_shift <= tx_shift_next;
                    miso     <= MSB_FIRST ? tx_shift_next[LAST_BIT] : tx_shift_next[0];
                end
            end
        end else begin : g_shift_neg
            always @(negedge sclk or posedge cs_n or negedge rst_n) begin
                if (!rst_n || cs_n) begin
                    // no-op, frame init handled by CS blocks
                end else begin
                    tx_shift <= tx_shift_next;
                    miso     <= MSB_FIRST ? tx_shift_next[LAST_BIT] : tx_shift_next[0];
                end
            end
        end
    endgenerate
endmodule

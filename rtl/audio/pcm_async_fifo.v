`timescale 1ns/1ps

// Dual-clock FIFO with Gray-coded pointers. The storage lives in a plain
// simple-dual-port array so it maps to block RAM; only the two pointers cross
// clock domains. Both level outputs are conservative: each side sees the
// other pointer a few clocks late, so a level may read high on the write side
// and low on the read side, never the opposite.
//
// rd_data is the registered array word at rd_ptr. It becomes valid one read
// clock after the word is written (and visible through rd_level), and one
// read clock after a pop moves rd_ptr, so consumers must not pop on
// back-to-back clocks. The 48 kHz audio consumer pops about 500 clocks apart.
module pcm_async_fifo #(
    parameter integer DATA_WIDTH = 32,
    parameter integer ADDR_WIDTH = 11
) (
    input  wire                  wr_clk,
    input  wire                  wr_rst_n,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,
    output wire [ADDR_WIDTH:0]   wr_level,
    output wire                  wr_full,

    input  wire                  rd_clk,
    input  wire                  rd_rst_n,
    input  wire                  rd_en,
    output wire [DATA_WIDTH-1:0] rd_data,
    output wire [ADDR_WIDTH:0]   rd_level,
    output wire                  rd_empty
);
    localparam integer PTR_WIDTH = ADDR_WIDTH + 1;

    reg [DATA_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1] /* fehdl force_ram=1, ram_style="bram" */;
    reg [DATA_WIDTH-1:0] rd_q;

    reg [PTR_WIDTH-1:0] wr_ptr;
    reg [PTR_WIDTH-1:0] rd_ptr;
    reg [PTR_WIDTH-1:0] wr_gray_reg;
    reg [PTR_WIDTH-1:0] rd_gray_reg;
    // First stages of the pointer synchronisers are constrained by name in
    // the SDC (set_max_delay -datapath_only); keep the *_s1 / *_s2 names.
    (* async_reg = "true" *) reg [PTR_WIDTH-1:0] wr_gray_s1;
    (* async_reg = "true" *) reg [PTR_WIDTH-1:0] wr_gray_s2;
    (* async_reg = "true" *) reg [PTR_WIDTH-1:0] rd_gray_s1;
    (* async_reg = "true" *) reg [PTR_WIDTH-1:0] rd_gray_s2;

    function [PTR_WIDTH-1:0] to_gray;
        input [PTR_WIDTH-1:0] b;
        begin
            to_gray = b ^ (b >> 1);
        end
    endfunction

    function [PTR_WIDTH-1:0] from_gray;
        input [PTR_WIDTH-1:0] g;
        integer i;
        begin
            from_gray[PTR_WIDTH-1] = g[PTR_WIDTH-1];
            for (i = PTR_WIDTH-2; i >= 0; i = i - 1)
                from_gray[i] = from_gray[i+1] ^ g[i];
        end
    endfunction

    assign wr_level = wr_ptr - from_gray(rd_gray_s2);
    assign rd_level = from_gray(wr_gray_s2) - rd_ptr;
    assign wr_full = wr_level[ADDR_WIDTH];
    assign rd_empty = (rd_level == 0);
    assign rd_data = rd_q;

    always @(posedge wr_clk) begin
        if (wr_en && !wr_full)
            mem[wr_ptr[ADDR_WIDTH-1:0]] <= wr_data;
    end

    always @(posedge rd_clk) begin
        rd_q <= mem[rd_ptr[ADDR_WIDTH-1:0]];
    end

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_ptr <= {PTR_WIDTH{1'b0}};
            wr_gray_reg <= {PTR_WIDTH{1'b0}};
            rd_gray_s1 <= {PTR_WIDTH{1'b0}};
            rd_gray_s2 <= {PTR_WIDTH{1'b0}};
        end else begin
            if (wr_en && !wr_full)
                wr_ptr <= wr_ptr + 1'b1;
            wr_gray_reg <= to_gray(wr_ptr);
            rd_gray_s1 <= rd_gray_reg;
            rd_gray_s2 <= rd_gray_s1;
        end
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr <= {PTR_WIDTH{1'b0}};
            rd_gray_reg <= {PTR_WIDTH{1'b0}};
            wr_gray_s1 <= {PTR_WIDTH{1'b0}};
            wr_gray_s2 <= {PTR_WIDTH{1'b0}};
        end else begin
            if (rd_en && !rd_empty)
                rd_ptr <= rd_ptr + 1'b1;
            rd_gray_reg <= to_gray(rd_ptr);
            wr_gray_s1 <= wr_gray_reg;
            wr_gray_s2 <= wr_gray_s1;
        end
    end
endmodule

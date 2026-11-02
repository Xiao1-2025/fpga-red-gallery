`timescale 1ns/1ps

// One immutable error snapshot per epoch. This is NOT a general-purpose
// synchronizer for a changing multi-bit bus: src_code is captured on the first
// src_error and held until src_rst_n is asserted or src_clear starts a new
// epoch. src_clear must precede the next src_error by at least eight
// destination clocks, so the destination sees the valid level drop and takes
// a fresh snapshot (the storage retry loop clears at every new attempt, which
// is milliseconds before it can fail again).
// Every bit and the valid level cross two FFs; two further destination
// guard cycles precede the atomic publication of code + valid. Downstream
// logic never consumes the unsynchronized source bus or partial snapshot.
module sticky_error_cdc #(
    // 0: dst_valid/dst_code follow the latch directly. >0: once an error has
    // been published it stays published for this many dst_clk cycles after the
    // latch was last seen set, so a retry loop that clears the latch for a
    // short while between attempts shows one steady error, and the error drops
    // that long after the latch really stays clear.
    parameter integer HOLD_CYCLES = 0
) (
    input  wire       src_clk,
    input  wire       src_rst_n,
    input  wire       src_error,
    input  wire       src_clear,
    input  wire [7:0] src_code,
    output reg        src_latched,
    input  wire       dst_clk,
    input  wire       dst_rst_n,
    output wire       dst_valid,
    output wire [7:0] dst_code
);
    reg        raw_valid;
    reg  [7:0] raw_code;
    reg [7:0] source_code;
    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            src_latched <= 1'b0;
            source_code <= 8'd0;
        end else if (src_clear) begin
            src_latched <= 1'b0;
            source_code <= 8'd0;
        end else if (src_error && !src_latched) begin
            source_code <= (src_code != 0) ? src_code : 8'hfe;
            src_latched <= 1'b1;
        end
    end

    wire valid_sync;
    wire [7:0] code_sync;
    sync_2ff u_valid_sync (
        .clk(dst_clk), .rst_n(dst_rst_n),
        .async_in(src_latched), .sync_out(valid_sync)
    );
    genvar bit_index;
    generate
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin : g_code
            sync_2ff u_sync (
                .clk(dst_clk), .rst_n(dst_rst_n),
                .async_in(source_code[bit_index]), .sync_out(code_sync[bit_index])
            );
        end
    endgenerate

    reg valid_guard1;
    reg valid_guard2;
    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            valid_guard1 <= 1'b0;
            valid_guard2 <= 1'b0;
            raw_valid <= 1'b0;
            raw_code <= 8'd0;
        end else if (!valid_sync) begin
            valid_guard1 <= 1'b0;
            valid_guard2 <= 1'b0;
            raw_valid <= 1'b0;
            raw_code <= 8'd0;
        end else begin
            valid_guard1 <= 1'b1;
            valid_guard2 <= valid_guard1;
            if (valid_guard2 && !raw_valid) begin
                raw_code <= code_sync;
                raw_valid <= 1'b1;
            end
        end
    end

    generate
        if (HOLD_CYCLES == 0) begin : g_direct
            assign dst_valid = raw_valid;
            assign dst_code = raw_code;
        end else begin : g_hold
            reg        held_valid;
            reg  [7:0] held_code;
            reg [31:0] hold_count;
            always @(posedge dst_clk or negedge dst_rst_n) begin
                if (!dst_rst_n) begin
                    held_valid <= 1'b0;
                    held_code <= 8'd0;
                    hold_count <= 32'd0;
                end else if (raw_valid) begin
                    held_valid <= 1'b1;
                    held_code <= raw_code;
                    hold_count <= HOLD_CYCLES;
                end else if (hold_count != 0) begin
                    hold_count <= hold_count - 1'b1;
                end else begin
                    held_valid <= 1'b0;
                    held_code <= 8'd0;
                end
            end
            assign dst_valid = held_valid;
            assign dst_code = held_code;
        end
    endgenerate
endmodule

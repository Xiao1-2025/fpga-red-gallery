`timescale 1ns/1ps

// Audio waveform overlay.
//
// What is drawn: one display column per BIN_SAMPLES PCM samples (the sample
// with the largest magnitude in the bin, so peaks are never skipped), 128
// columns = 768 samples = 16 ms of audio, about one video frame, joined into a
// continuous one-pixel trace (LINE_THICK to thicken). The vertical scale follows the signal: after every
// captured window the shift that brings its peak to roughly 3/4 of the half
// height is selected for the next window, so quiet passages and low volume
// settings still draw a readable wave. The bar at the right edge is a plain
// level meter of the actual output (it does follow the volume). The trace is
// refreshed every UPDATE_FRAMES video frames instead of every frame, which
// keeps it calm.
//
// pcm_tap_valid must be a one-clock strobe per transferred sample (valid and
// ready), not a held "valid" level.
//
// Timing: rgb_out is a combinational mux behind registered pixel state, so the
// video bundle gets no extra clock of delay. The trace pixels are computed
// LOOKAHEAD clocks ahead of pixel_x (pixel_x is a free-running column counter
// of H_TOTAL columns) so the block-RAM read lines up with the current pixel.
module promax_audio_waveform #(
    parameter integer WAVE_X = 64,
    parameter integer WAVE_Y = 400,
    parameter integer WAVE_WIDTH = 512,
    parameter integer WAVE_HEIGHT = 64,
    parameter integer H_TOTAL = 800,
    parameter integer BIN_SAMPLES = 6,
    // Trace thickness in pixels (1..3): 1 = single pixel line, 2 = one extra
    // pixel below, 3 = one extra pixel above and below.
    parameter integer LINE_THICK = 1,
    parameter integer UPDATE_FRAMES = 3
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire [9:0]  pixel_x,
    input  wire        enable,
    input  wire        pcm_tap_valid,
    input  wire signed [15:0] pcm_tap_left,
    output wire [23:0] rgb_out,
    output wire        waveform_active
);
    localparam integer COLS = 128;
    localparam integer COL_SHIFT = 2;                 // 4 pixels per column
    localparam integer EXT_UP = (LINE_THICK >= 3) ? 1 : 0;
    localparam integer EXT_DN = (LINE_THICK >= 2) ? 1 : 0;
    localparam integer CENTER_Y = WAVE_Y + WAVE_HEIGHT/2;
    localparam integer LOOKAHEAD = 4;
    localparam [15:0] PEAK_FLOOR = 16'd64;

    // ------------------------------------------------------------- timing
    reg [11:0] line_y;
    reg de_q;
    reg vs_q;
    wire frame_start = vs_q && !vsync;

    // ----------------------------------------------------- capture / bins
    reg [11:0] wave_mem [0:2*COLS-1] /* fehdl force_ram=1, ram_style="bram" */;
    reg [11:0] rd_q;
    reg [7:0]  rd_addr;
    reg        wr_en;
    reg [7:0]  wr_addr;
    reg [11:0] wr_data;
    always @(posedge clk) begin
        if (wr_en)
            wave_mem[wr_addr] <= wr_data;
        rd_q <= wave_mem[rd_addr];
    end

    reg write_bank;
    reg display_bank;
    reg display_valid;
    reg window_full;
    reg [6:0]  col_count;
    reg [3:0]  bin_count;
    reg signed [15:0] bin_best;
    reg [15:0] bin_best_abs;
    reg [15:0] window_peak;
    reg [3:0]  gain_shift;
    reg [5:0]  prev_v;
    reg [7:0]  frames_since_swap;
    reg [6:0]  meter_h;

    wire [15:0] sample_abs = pcm_tap_left[15] ? (~pcm_tap_left + 1'b1) : pcm_tap_left;
    wire take_new = (bin_count == 0) || (sample_abs > bin_best_abs);
    wire signed [15:0] best_now = take_new ? pcm_tap_left : bin_best;
    wire [15:0] best_abs_now = take_new ? sample_abs : bin_best_abs;
    wire [15:0] peak_now = (best_abs_now > window_peak) ? best_abs_now : window_peak;

    // Shift that maps the window peak to roughly 24 of the 31 half-height steps.
    function [3:0] shift_for;
        input [15:0] peak;
        reg [15:0] p;
        begin
            p = (peak < PEAK_FLOOR) ? PEAK_FLOOR : peak;
            if      (p < 16'd48)    shift_for = 4'd1;
            else if (p < 16'd96)    shift_for = 4'd2;
            else if (p < 16'd192)   shift_for = 4'd3;
            else if (p < 16'd384)   shift_for = 4'd4;
            else if (p < 16'd768)   shift_for = 4'd5;
            else if (p < 16'd1536)  shift_for = 4'd6;
            else if (p < 16'd3072)  shift_for = 4'd7;
            else if (p < 16'd6144)  shift_for = 4'd8;
            else if (p < 16'd12288) shift_for = 4'd9;
            else if (p < 16'd24576) shift_for = 4'd10;
            else                    shift_for = 4'd11;
        end
    endfunction

    wire signed [15:0] scaled_full = best_now >>> gain_shift;
    wire signed [5:0] scaled_v = (scaled_full > 16'sd31)  ? 6'sd31 :
                                 (scaled_full < -16'sd31) ? -6'sd31 : scaled_full[5:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_y <= 12'd0;
            de_q <= 1'b0;
            vs_q <= 1'b1;
            write_bank <= 1'b0;
            display_bank <= 1'b1;
            display_valid <= 1'b0;
            window_full <= 1'b0;
            col_count <= 7'd0;
            bin_count <= 4'd0;
            bin_best <= 16'sd0;
            bin_best_abs <= 16'd0;
            window_peak <= 16'd0;
            gain_shift <= 4'd8;
            prev_v <= 6'd0;
            frames_since_swap <= 8'd0;
            meter_h <= 7'd0;
            wr_en <= 1'b0;
            wr_addr <= 8'd0;
            wr_data <= 12'd0;
        end else begin
            de_q <= de;
            vs_q <= vsync;
            wr_en <= 1'b0;
            if (!vsync)
                line_y <= 12'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;

            if (frame_start) begin
                if (frames_since_swap != 8'hff)
                    frames_since_swap <= frames_since_swap + 1'b1;
                if (window_full && frames_since_swap >= UPDATE_FRAMES - 1) begin
                    display_bank <= write_bank;
                    display_valid <= 1'b1;
                    write_bank <= ~write_bank;
                    window_full <= 1'b0;
                    col_count <= 7'd0;
                    bin_count <= 4'd0;
                    window_peak <= 16'd0;
                    frames_since_swap <= 8'd0;
                    // Level meter: window peak in 1/4096 steps of full scale
                    // would be too small to see; show it in 1/512 steps.
                    meter_h <= (window_peak[15:9] > 7'd64) ? 7'd64 : window_peak[15:9];
                end
            end

            if (pcm_tap_valid && !window_full) begin
                bin_best <= best_now;
                bin_best_abs <= best_abs_now;
                window_peak <= peak_now;
                if (bin_count == BIN_SAMPLES - 1) begin
                    bin_count <= 4'd0;
                    wr_en <= 1'b1;
                    wr_addr <= {write_bank, col_count};
                    wr_data <= {(col_count == 7'd0) ? scaled_v : prev_v, scaled_v};
                    prev_v <= scaled_v;
                    col_count <= col_count + 1'b1;
                    if (col_count == COLS - 1) begin
                        window_full <= 1'b1;
                        // The next window is scaled for this window's peak.
                        gain_shift <= shift_for(peak_now);
                    end
                end else begin
                    bin_count <= bin_count + 1'b1;
                end
            end
        end
    end

    // -------------------------------------------- display pipeline (x + 4)
    wire [9:0] xa_raw = pixel_x + LOOKAHEAD;
    wire [9:0] xa = (xa_raw >= H_TOTAL) ? (xa_raw - H_TOTAL) : xa_raw;
    wire in_x_a = (xa >= WAVE_X) && (xa < WAVE_X + WAVE_WIDTH);
    wire [9:0] off_a = xa - WAVE_X;
    wire [9:0] col_a = off_a >> COL_SHIFT;
    wire [COL_SHIFT-1:0] sub_a = off_a[COL_SHIFT-1:0];

    reg [6:0] col_s1;
    reg ix_s1, ix_s2, ix_s3, ix_s4;
    reg [COL_SHIFT-1:0] sub_s1, sub_s2, sub_s3;
    reg signed [12:0] row_lo_q, row_hi_q;
    wire signed [5:0] v_prev = rd_q[11:6];
    wire signed [5:0] v_cur = rd_q[5:0];
    wire signed [12:0] v_prev_x = v_prev;
    wire signed [12:0] v_cur_x = v_cur;
    wire signed [12:0] v_max = (v_prev > v_cur) ? v_prev_x : v_cur_x;
    wire signed [12:0] v_min = (v_prev > v_cur) ? v_cur_x : v_prev_x;
    always @(posedge clk) begin
        col_s1 <= col_a[6:0];
        ix_s1 <= in_x_a;
        sub_s1 <= sub_a;
        rd_addr <= {display_bank, col_s1};
        ix_s2 <= ix_s1;
        sub_s2 <= sub_s1;
        ix_s3 <= ix_s2;
        sub_s3 <= sub_s2;
        // Positive samples draw upwards (smaller line numbers). The first
        // pixel column of a cell also draws the vertical join to the previous
        // column's level; the other columns of the cell stay on this column's
        // own level, so the trace is a one-pixel line, not a filled band.
        row_lo_q <= CENTER_Y - ((sub_s3 == 0) ? v_max : v_cur_x) - EXT_UP;
        row_hi_q <= CENTER_Y - ((sub_s3 == 0) ? v_min : v_cur_x) + EXT_DN;
        ix_s4 <= ix_s3;
    end

    wire in_band_y = (line_y >= WAVE_Y) && (line_y < WAVE_Y + WAVE_HEIGHT);
    wire signed [12:0] line_s = {1'b0, line_y};
    wire wave_pixel = enable && de && display_valid && ix_s4 && in_band_y &&
                      (line_s >= row_lo_q) && (line_s <= row_hi_q);
    wire axis_pixel = enable && de && in_band_y && (line_y == CENTER_Y) &&
                      (pixel_x >= WAVE_X) && (pixel_x < WAVE_X + WAVE_WIDTH);
    wire peak_pixel = enable && de &&
                      (pixel_x >= WAVE_X + WAVE_WIDTH + 8) &&
                      (pixel_x < WAVE_X + WAVE_WIDTH + 16) &&
                      (line_y + meter_h >= WAVE_Y + WAVE_HEIGHT) &&
                      (line_y < WAVE_Y + WAVE_HEIGHT);

    assign waveform_active = wave_pixel || axis_pixel || peak_pixel;
    assign rgb_out = wave_pixel ? 24'h20ff90 :
                     peak_pixel ? 24'hffb020 :
                     axis_pixel ? 24'h406060 : rgb_in;
endmodule

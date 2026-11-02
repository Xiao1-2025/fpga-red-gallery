`timescale 1ns/1ps

// WAV music source for the HDMI audio chain. The streamer (mem_clk) writes
// 32-bit {right,left} frames into a dual-clock FIFO; this block (audio/pixel
// clock) pulls one frame per 48 kHz tick, applies the player volume and hands
// it to the same valid/ready PCM contract used by pcm_media_tone.
//
// While the FIFO is below PREFILL_FRAMES, or after it runs dry, silence frames
// are produced so the downstream HDMI packetiser never stalls; playback
// resumes once the prefill level is reached again.
module wav_pcm_source #(
    parameter integer CLOCK_HZ = 25000000,
    parameter integer SAMPLE_HZ = 48000,
    parameter integer FIFO_ADDR_WIDTH = 11,
    parameter integer PREFILL_FRAMES = 256,
    // Largest number of frames one SD sector can add (mono: 512 / 2).
    parameter integer SECTOR_FRAMES = 256
) (
    // Write side, mem_clk domain.
    input  wire        wr_clk,
    input  wire        wr_rst_n,
    input  wire        wr_en,
    input  wire [31:0] wr_data,
    output wire        wr_has_room,

    // Read side, audio/pixel clock domain.
    input  wire               clk,
    input  wire               rst_n,
    input  wire               enable,
    // Pause freezes the song: silence frames go out and the FIFO is not read,
    // so playback resumes at the same position. The SD streamer simply stops
    // when the FIFO fills up.
    input  wire               pause,
    input  wire [7:0]         volume,
    output wire               sample_valid,
    input  wire               sample_ready,
    output wire signed [15:0] sample_left,
    output wire signed [15:0] sample_right,
    output reg                overflow,
    output reg                underflow
);
    localparam integer DEPTH = 1 << FIFO_ADDR_WIDTH;

    wire [FIFO_ADDR_WIDTH:0] wr_level;
    wire [FIFO_ADDR_WIDTH:0] rd_level;
    wire [31:0] rd_frame;
    wire rd_empty;
    reg fifo_pop;

    pcm_async_fifo #(.DATA_WIDTH(32), .ADDR_WIDTH(FIFO_ADDR_WIDTH)) u_wav_fifo (
        .wr_clk(wr_clk), .wr_rst_n(wr_rst_n), .wr_en(wr_en), .wr_data(wr_data),
        .wr_level(wr_level), .wr_full(),
        .rd_clk(clk), .rd_rst_n(rst_n), .rd_en(fifo_pop), .rd_data(rd_frame),
        .rd_level(rd_level), .rd_empty(rd_empty)
    );

    assign wr_has_room = (wr_level <= DEPTH - SECTOR_FRAMES - 16);

    reg [24:0] rate_accumulator;
    reg playing;
    reg [31:0] out_fifo [0:7];
    reg [2:0] write_pointer;
    reg [2:0] read_pointer;
    reg [3:0] fifo_count;
    wire sample_pop;
    wire sample_tick;
    wire sample_push;

    assign sample_valid = fifo_count != 0;
    assign sample_left = out_fifo[read_pointer][15:0];
    assign sample_right = out_fifo[read_pointer][31:16];
    assign sample_pop = sample_valid && sample_ready;
    assign sample_tick = enable && (rate_accumulator >= CLOCK_HZ - SAMPLE_HZ);
    assign sample_push = sample_tick && (fifo_count != 8 || sample_pop);

    wire have_frame = (playing || rd_level >= PREFILL_FRAMES) && !rd_empty && !pause;
    wire signed [15:0] frame_left = rd_frame[15:0];
    wire signed [15:0] frame_right = rd_frame[31:16];
    wire signed [23:0] scaled_left = frame_left * $signed({1'b0, volume});
    wire signed [23:0] scaled_right = frame_right * $signed({1'b0, volume});
    wire [31:0] music_frame = {scaled_right[23:8], scaled_left[23:8]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rate_accumulator <= 25'd0;
            playing <= 1'b0;
            write_pointer <= 3'd0;
            read_pointer <= 3'd0;
            fifo_count <= 4'd0;
            fifo_pop <= 1'b0;
            overflow <= 1'b0;
            underflow <= 1'b0;
        end else begin
            fifo_pop <= 1'b0;

            if (rate_accumulator >= CLOCK_HZ - SAMPLE_HZ)
                rate_accumulator <= rate_accumulator + SAMPLE_HZ - CLOCK_HZ;
            else
                rate_accumulator <= rate_accumulator + SAMPLE_HZ;

            if (sample_push) begin
                out_fifo[write_pointer] <= have_frame ? music_frame : 32'd0;
                write_pointer <= write_pointer + 1'b1;
                if (have_frame) begin
                    fifo_pop <= 1'b1;
                    playing <= 1'b1;
                end else begin
                    // Ran dry after playing: wait for the prefill level again.
                    // A pause is not an underflow and keeps the playing state.
                    if (playing && !pause)
                        underflow <= 1'b1;
                    if (!pause)
                        playing <= 1'b0;
                end
            end else if (sample_tick) begin
                overflow <= 1'b1;
            end

            if (sample_pop)
                read_pointer <= read_pointer + 1'b1;

            case ({sample_push, sample_pop})
                2'b10: fifo_count <= fifo_count + 1'b1;
                2'b01: fifo_count <= fifo_count - 1'b1;
                default: fifo_count <= fifo_count;
            endcase
        end
    end
endmodule

`timescale 1ns/1ps

// Streams MUSIC.WAV from the FAT32 volume into the audio FIFO (mem_clk).
//
// The file is walked as a plain byte stream: RIFF header, then chunks until
// "fmt " and "data" have been seen, so LIST/INFO chunks before the audio are
// skipped. Supported payload is 48 kHz, 16-bit PCM, mono or stereo (mono is
// duplicated to both channels). Anything else raises format_bad and the
// player falls back to its built-in tones.
//
// Sector reads are paced by fifo_has_room at sector boundaries, so the SD
// card is only read as fast as the audio is consumed. When the data chunk is
// exhausted the file is simply started again, which loops the music; the FIFO
// holds tens of milliseconds, far longer than restarting takes.
module wav_stream_ingest (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        run,
    input  wire        music_valid,
    input  wire        fifo_has_room,
    output reg         fifo_wr_en,
    output reg  [31:0] fifo_wr_data,
    // Borrowed file streamer (media_ingest_pipeline). The caller selects the
    // MUSIC.WAV cluster/size for it while run is high.
    output reg         file_start,
    output wire        file_pause,
    input  wire        file_valid,
    input  wire [7:0]  file_byte,
    input  wire        file_done,
    input  wire [7:0]  file_error,
    output reg         format_bad,
    output reg         loop_pulse
);
    localparam [2:0] P_RIFF = 3'd0;
    localparam [2:0] P_HDR  = 3'd1;
    localparam [2:0] P_FMT  = 3'd2;
    localparam [2:0] P_SKIP = 3'd3;
    localparam [2:0] P_DATA = 3'd4;
    localparam [2:0] P_DONE = 3'd5;

    localparam [1:0] C_IDLE = 2'd0;
    localparam [1:0] C_RUN  = 2'd1;
    localparam [1:0] C_FAIL = 2'd2;

    reg [1:0] cstate;

    // The streamer is held at sector boundaries while the FIFO is full, the
    // player has not started, or the format was rejected (this parks it for
    // good instead of reading the rest of a file that cannot be played).
    assign file_pause = !run || !fifo_has_room || format_bad;

    reg [2:0] pstate;
    reg [4:0] cnt;
    reg [31:0] id;
    reg [31:0] csize;
    reg [31:0] remain;
    reg [31:0] data_remain;
    reg [15:0] fmt_tag;
    reg [15:0] fmt_channels;
    reg [31:0] fmt_rate;
    reg [7:0]  fmt_bits_lo;
    reg fmt_ok;
    reg mono;
    reg data_seen;
    reg [1:0] fb_cnt;
    reg [7:0] l_lo;
    reg [7:0] l_hi;
    reg [7:0] r_lo;
    // Length of the chunk whose 8-byte header ends with the current byte.
    wire [31:0] chunk_len = {file_byte, csize[31:8]};
    wire [31:0] padded_len = chunk_len + {31'd0, chunk_len[0]};

    task parser_reset;
        begin
            pstate <= P_RIFF;
            cnt <= 5'd0;
            fmt_ok <= 1'b0;
            mono <= 1'b0;
            data_seen <= 1'b0;
            fb_cnt <= 2'd0;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cstate <= C_IDLE;
            file_start <= 1'b0;
            fifo_wr_en <= 1'b0;
            fifo_wr_data <= 32'd0;
            format_bad <= 1'b0;
            loop_pulse <= 1'b0;
            pstate <= P_RIFF;
            cnt <= 5'd0;
            id <= 32'd0;
            csize <= 32'd0;
            remain <= 32'd0;
            data_remain <= 32'd0;
            fmt_tag <= 16'd0;
            fmt_channels <= 16'd0;
            fmt_rate <= 32'd0;
            fmt_bits_lo <= 8'd0;
            fmt_ok <= 1'b0;
            mono <= 1'b0;
            data_seen <= 1'b0;
            fb_cnt <= 2'd0;
            l_lo <= 8'd0;
            l_hi <= 8'd0;
            r_lo <= 8'd0;
        end else begin
            file_start <= 1'b0;
            fifo_wr_en <= 1'b0;
            loop_pulse <= 1'b0;

            case (cstate)
                C_IDLE: if (run && music_valid && !format_bad) begin
                    file_start <= 1'b1;
                    parser_reset;
                    cstate <= C_RUN;
                end
                C_RUN: begin
                    if (format_bad) begin
                        cstate <= C_FAIL;
                    end else if (file_done) begin
                        // A finished pass restarts the file (loop). A pass cut
                        // short by an SD error restarts the same way; one with
                        // no audio chunk at all is a bad file.
                        if (file_error == 8'd0 && !data_seen)
                            format_bad <= 1'b1;
                        else begin
                            loop_pulse <= (file_error == 8'd0);
                            cstate <= C_IDLE;
                        end
                    end
                end
                default: cstate <= C_FAIL;
            endcase

            if (cstate == C_RUN && file_valid && !format_bad) begin
                case (pstate)
                    P_RIFF: begin
                        case (cnt)
                            5'd0: if (file_byte != "R") format_bad <= 1'b1;
                            5'd1: if (file_byte != "I") format_bad <= 1'b1;
                            5'd2: if (file_byte != "F") format_bad <= 1'b1;
                            5'd3: if (file_byte != "F") format_bad <= 1'b1;
                            5'd8: if (file_byte != "W") format_bad <= 1'b1;
                            5'd9: if (file_byte != "A") format_bad <= 1'b1;
                            5'd10: if (file_byte != "V") format_bad <= 1'b1;
                            5'd11: if (file_byte != "E") format_bad <= 1'b1;
                            default: ;
                        endcase
                        if (cnt == 5'd11) begin
                            pstate <= P_HDR;
                            cnt <= 5'd0;
                        end else
                            cnt <= cnt + 1'b1;
                    end
                    P_HDR: begin
                        if (cnt < 5'd4)
                            id <= {id[23:0], file_byte};
                        else
                            csize <= {file_byte, csize[31:8]};
                        if (cnt == 5'd7) begin
                            cnt <= 5'd0;
                            if (id == "fmt ") begin
                                if (chunk_len < 32'd16)
                                    format_bad <= 1'b1;
                                else begin
                                    remain <= padded_len;
                                    pstate <= P_FMT;
                                end
                            end else if (id == "data") begin
                                if (!fmt_ok)
                                    format_bad <= 1'b1;
                                else begin
                                    data_seen <= 1'b1;
                                    fb_cnt <= 2'd0;
                                    // 0 / 0xFFFFFFFF mean "until end of file".
                                    data_remain <= (chunk_len == 32'd0 ||
                                                    chunk_len == 32'hffffffff) ?
                                                   32'hffffffff : chunk_len;
                                    pstate <= P_DATA;
                                end
                            end else if (padded_len != 32'd0) begin
                                remain <= padded_len;
                                pstate <= P_SKIP;
                            end
                        end else
                            cnt <= cnt + 1'b1;
                    end
                    P_FMT: begin
                        case (cnt)
                            5'd0: fmt_tag[7:0] <= file_byte;
                            5'd1: fmt_tag[15:8] <= file_byte;
                            5'd2: fmt_channels[7:0] <= file_byte;
                            5'd3: fmt_channels[15:8] <= file_byte;
                            5'd4: fmt_rate[7:0] <= file_byte;
                            5'd5: fmt_rate[15:8] <= file_byte;
                            5'd6: fmt_rate[23:16] <= file_byte;
                            5'd7: fmt_rate[31:24] <= file_byte;
                            5'd14: fmt_bits_lo <= file_byte;
                            5'd15: begin
                                if (fmt_tag == 16'd1 &&
                                    (fmt_channels == 16'd1 || fmt_channels == 16'd2) &&
                                    fmt_rate == 32'd48000 &&
                                    {file_byte, fmt_bits_lo} == 16'd16) begin
                                    fmt_ok <= 1'b1;
                                    mono <= (fmt_channels == 16'd1);
                                end else
                                    format_bad <= 1'b1;
                            end
                            default: ;
                        endcase
                        if (cnt != 5'd16)
                            cnt <= cnt + 1'b1;
                        remain <= remain - 1'b1;
                        if (remain == 32'd1) begin
                            pstate <= P_HDR;
                            cnt <= 5'd0;
                        end
                    end
                    P_SKIP: begin
                        remain <= remain - 1'b1;
                        if (remain == 32'd1) begin
                            pstate <= P_HDR;
                            cnt <= 5'd0;
                        end
                    end
                    P_DATA: begin
                        case (fb_cnt)
                            2'd0: begin
                                l_lo <= file_byte;
                                fb_cnt <= 2'd1;
                            end
                            2'd1: begin
                                l_hi <= file_byte;
                                if (mono) begin
                                    fifo_wr_data <= {file_byte, l_lo, file_byte, l_lo};
                                    fifo_wr_en <= 1'b1;
                                    fb_cnt <= 2'd0;
                                end else
                                    fb_cnt <= 2'd2;
                            end
                            2'd2: begin
                                r_lo <= file_byte;
                                fb_cnt <= 2'd3;
                            end
                            default: begin
                                fifo_wr_data <= {file_byte, r_lo, l_hi, l_lo};
                                fifo_wr_en <= 1'b1;
                                fb_cnt <= 2'd0;
                            end
                        endcase
                        data_remain <= data_remain - 1'b1;
                        if (data_remain == 32'd1)
                            pstate <= P_DONE;
                    end
                    default: ;
                endcase
            end
        end
    end
endmodule

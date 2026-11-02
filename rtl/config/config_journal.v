`timescale 1ns/1ps

module config_journal (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        load_start,
    input  wire        slot0_present,
    input  wire [31:0] slot0_version,
    input  wire [31:0] slot0_period,
    input  wire [7:0]  slot0_volume,
    input  wire [7:0]  slot0_mode,
    input  wire [15:0] slot0_crc,
    input  wire        slot1_present,
    input  wire [31:0] slot1_version,
    input  wire [31:0] slot1_period,
    input  wire [7:0]  slot1_volume,
    input  wire [7:0]  slot1_mode,
    input  wire [15:0] slot1_crc,
    output reg         load_done,
    output reg         config_valid,
    output reg  [31:0] active_version,
    output reg  [31:0] active_period,
    output reg  [7:0]  active_volume,
    output reg  [7:0]  active_mode,
    input  wire        save_start,
    input  wire [31:0] save_period,
    input  wire [7:0]  save_volume,
    input  wire [7:0]  save_mode,
    output reg         record_ready,
    output reg         target_slot,
    output reg  [31:0] record_version,
    output reg  [31:0] record_period,
    output reg  [7:0]  record_volume,
    output reg  [7:0]  record_mode,
    output reg  [15:0] record_crc
);
    function [15:0] crc16_word;
        input [79:0] payload;
        integer i;
        reg [15:0] crc;
        begin
            crc = 16'hffff;
            for (i = 79; i >= 0; i = i - 1) begin
                if (crc[15] ^ payload[i])
                    crc = {crc[14:0],1'b0} ^ 16'h1021;
                else
                    crc = {crc[14:0],1'b0};
            end
            crc16_word = crc;
        end
    endfunction

    // CRC-16/CCITT-FALSE continued over 40 payload bits (MSB first). Two calls
    // starting from 16'hffff give crc16_word; splitting them lets each half be
    // registered so no single clock sees the whole 80-bit XOR tree.
    function [15:0] crc_bits40;
        input [15:0] c_in;
        input [39:0] d;
        integer j;
        reg [15:0] c;
        begin
            c = c_in;
            for (j = 39; j >= 0; j = j - 1) begin
                if (c[15] ^ d[j])
                    c = {c[14:0],1'b0} ^ 16'h1021;
                else
                    c = {c[14:0],1'b0};
            end
            crc_bits40 = c;
        end
    endfunction

    function version_newer;
        input [31:0] candidate;
        input [31:0] reference;
        reg [31:0] delta;
        begin
            delta = candidate - reference;
            version_newer = (candidate != reference) && !delta[31];
        end
    endfunction

    // The slot images are captured shortly before load_start (slot 1 only one
    // clock earlier), so the CRC checks and the version comparison run into
    // registers every clock - the CRC in two halves, then the compare - and the
    // selection logic below only sees settled flags. load_start is delayed
    // LOAD_DELAY clocks so the flags can never lag the data they describe
    // (the flag pipeline is three clocks deep).
    localparam integer LOAD_DELAY = 5;
    reg [15:0] s0_part, s0_calc, s1_part, s1_calc;
    reg slot0_good;
    reg slot1_good;
    reg slot1_newer;
    always @(posedge clk) begin
        s0_part <= crc_bits40(16'hffff, {slot0_version, slot0_period[31:24]});
        s0_calc <= crc_bits40(s0_part, {slot0_period[23:0], slot0_volume, slot0_mode} );
        slot0_good <= slot0_present && slot0_crc == s0_calc;
        s1_part <= crc_bits40(16'hffff, {slot1_version, slot1_period[31:24]});
        s1_calc <= crc_bits40(s1_part, {slot1_period[23:0], slot1_volume, slot1_mode} );
        slot1_good <= slot1_present && slot1_crc == s1_calc;
        slot1_newer <= version_newer(slot1_version,slot0_version);
    end
    reg [LOAD_DELAY:1] load_pipe;

    // The record fields are captured on save_start and the CRC is computed from
    // them in two further clocks (half of the payload each), so neither the
    // version increment nor the 80-bit CRC is chained in a single clock.
    // record_ready follows the CRC.
    reg save_stage;
    reg save_stage2;
    reg [15:0] rec_part;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            save_stage<=0; save_stage2<=0; rec_part<=0;
            load_pipe<=0;
            load_done<=0; config_valid<=0; active_version<=0; active_period<=0;
            active_volume<=0; active_mode<=0; record_ready<=0; target_slot<=0;
            record_version<=0; record_period<=0; record_volume<=0; record_mode<=0;
            record_crc<=0;
        end else begin
            load_done<=0;
            record_ready<=0;
            save_stage<=0;
            save_stage2<=0;
            load_pipe<={load_pipe, load_start};   // shift left, oldest bit drops off the top
            if(load_pipe[LOAD_DELAY]) begin
                load_done<=1;
                if(slot0_good && (!slot1_good || !slot1_newer)) begin
                    config_valid<=1; active_version<=slot0_version; active_period<=slot0_period;
                    active_volume<=slot0_volume; active_mode<=slot0_mode;
                end else if(slot1_good) begin
                    config_valid<=1; active_version<=slot1_version; active_period<=slot1_period;
                    active_volume<=slot1_volume; active_mode<=slot1_mode;
                end else begin
                    config_valid<=0; active_version<=0; active_period<=0;
                    active_volume<=0; active_mode<=0;
                end
            end
            if(save_start) begin
                target_slot <= slot0_good && (!slot1_good || !slot1_newer) ? 1'b1 : 1'b0;
                record_version <= active_version + 1'b1;
                record_period <= save_period;
                record_volume <= save_volume;
                record_mode <= save_mode;
                save_stage <= 1'b1;
            end
            if(save_stage) begin
                rec_part <= crc_bits40(16'hffff, {record_version, record_period[31:24]});
                save_stage2 <= 1'b1;
            end
            if(save_stage2) begin
                record_crc <= crc_bits40(rec_part, {record_period[23:0], record_volume, record_mode});
                record_ready <= 1'b1;
            end
        end
    end
endmodule

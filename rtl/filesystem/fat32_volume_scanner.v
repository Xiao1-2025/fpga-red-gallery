`timescale 1ns/1ps

module fat32_volume_scanner #(
    parameter integer REQUIRE_TITLE = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        scan_start,
    output wire        scan_busy,
    output reg         scan_done,
    output reg  [7:0]  fs_error,
    output reg  [31:0] partition_lba,
    output reg  [7:0]  sectors_per_cluster,
    output reg  [31:0] fat_start_lba,
    output reg  [31:0] data_start_lba,
    output reg  [31:0] max_cluster,
    output reg  [3:0]  resource_valid,
    output reg         title_valid,
    output reg  [31:0] resource0_cluster,
    output reg  [31:0] resource1_cluster,
    output reg  [31:0] resource2_cluster,
    output reg  [31:0] resource3_cluster,
    output reg  [31:0] title_cluster,
    output reg  [31:0] resource0_size,
    output reg  [31:0] resource1_size,
    output reg  [31:0] resource2_size,
    output reg  [31:0] resource3_size,
    output reg  [31:0] title_size,
    output reg         music_valid,
    output reg  [31:0] music_cluster,
    output reg  [31:0] music_size,
    output reg         sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);

    localparam ERR_NONE            = 8'h00;
    localparam ERR_SECTOR          = 8'h10;
    localparam ERR_BOOT_SIGNATURE  = 8'h20;
    localparam ERR_UNSUPPORTED_BPB = 8'h21;
    localparam ERR_RESOURCE_MISSING= 8'h22;

    localparam ST_IDLE       = 4'd0;
    localparam ST_READ0_REQ  = 4'd1;
    localparam ST_READ0_WAIT = 4'd2;
    localparam ST_BOOT_PARSE = 4'd3;
    localparam ST_BOOT_REQ   = 4'd4;
    localparam ST_BOOT_WAIT  = 4'd5;
    localparam ST_ROOT_REQ   = 4'd6;
    localparam ST_ROOT_WAIT  = 4'd7;
    localparam ST_DIR_SCAN   = 4'd8;
    localparam ST_FINISH     = 4'd9;
    localparam ST_BOOT_LAYOUT= 4'd10;
    localparam ST_BOOT_ROOT  = 4'd11;
    localparam ST_DIR_NEXT   = 4'd12;
    localparam ST_DIR_CHECK  = 4'd13;
    localparam ST_DIR_FETCH  = 4'd14;

    reg [3:0] state;
    // The sector lives in a block RAM (registered read) instead of a 4096-flop
    // array behind a 512:1 byte mux. Boot-sector fields at fixed offsets are
    // captured into small registers while the sector streams in; a directory
    // entry is read back byte by byte and shifted into dir_entry.
    reg [7:0] sector_ram [0:511];
    reg [7:0] head [0:47];
    reg [7:0] b450, b454, b455, b456, b457, b510, b511;
    reg [8:0] rd_addr;
    reg [7:0] rd_q;
    reg [5:0] fetch_k;
    always @(posedge clk) begin
        if (sector_valid)
            sector_ram[sector_byte_index] <= sector_byte;
        rd_q <= sector_ram[rd_addr];
    end
    always @(posedge clk) begin
        if (sector_valid) begin
            if (sector_byte_index < 9'd48) head[sector_byte_index[5:0]] <= sector_byte;
            if (sector_byte_index == 9'd450) b450 <= sector_byte;
            if (sector_byte_index == 9'd454) b454 <= sector_byte;
            if (sector_byte_index == 9'd455) b455 <= sector_byte;
            if (sector_byte_index == 9'd456) b456 <= sector_byte;
            if (sector_byte_index == 9'd457) b457 <= sector_byte;
            if (sector_byte_index == 9'd510) b510 <= sector_byte;
            if (sector_byte_index == 9'd511) b511 <= sector_byte;
        end
    end
    wire [31:0] mbr_partition_lba = {b457, b456, b455, b454};
    reg [4:0] directory_entry_index;
    // One 32-byte directory entry is latched through a single wide mux so the
    // name/attribute checks read fixed offsets instead of 512-byte dynamic muxes.
    reg [255:0] dir_entry;
    reg [31:0] root_cluster;
    reg [31:0] total_sectors;
    reg [31:0] fat_sectors;
    reg [7:0] fat_count;
    reg [15:0] reserved_sectors;
    reg [31:0] root_lba;
    reg [31:0] data_sector_count;
    reg [31:0] fat_span;
    reg [2:0] sectors_per_cluster_shift;
    reg [6:0] root_sector_index;

    assign scan_busy = (state != ST_IDLE);

    function [15:0] le16;
        input integer offset;
        begin
            le16 = {head[offset+1], head[offset]};
        end
    endfunction

    function [31:0] le32;
        input integer offset;
        begin
            le32 = {head[offset+3], head[offset+2],
                    head[offset+1], head[offset]};
        end
    endfunction

    function valid_spc;
        input [7:0] value;
        begin
            valid_spc = value != 0 && ((value & (value - 1'b1)) == 0);
        end
    endfunction

    function [2:0] spc_shift;
        input [7:0] value;
        begin
            case (value)
                8'd2:   spc_shift = 3'd1;
                8'd4:   spc_shift = 3'd2;
                8'd8:   spc_shift = 3'd3;
                8'd16:  spc_shift = 3'd4;
                8'd32:  spc_shift = 3'd5;
                8'd64:  spc_shift = 3'd6;
                8'd128: spc_shift = 3'd7;
                default: spc_shift = 3'd0;
            endcase
        end
    endfunction

    function [2:0] matching_resource;
        input integer base;
        begin
            if (dir_entry[(base+0)*8 +: 8] == "P" && dir_entry[(base+1)*8 +: 8] == "I" &&
                dir_entry[(base+2)*8 +: 8] == "C" && dir_entry[(base+3)*8 +: 8] == "1" &&
                dir_entry[(base+8)*8 +: 8] == "B" && dir_entry[(base+9)*8 +: 8] == "M" &&
                dir_entry[(base+10)*8 +: 8] == "P")
                matching_resource = 3'd0;
            else if (dir_entry[(base+0)*8 +: 8] == "P" && dir_entry[(base+1)*8 +: 8] == "I" &&
                     dir_entry[(base+2)*8 +: 8] == "C" && dir_entry[(base+3)*8 +: 8] == "2" &&
                     dir_entry[(base+8)*8 +: 8] == "B" && dir_entry[(base+9)*8 +: 8] == "M" &&
                     dir_entry[(base+10)*8 +: 8] == "P")
                matching_resource = 3'd1;
            else if (dir_entry[(base+0)*8 +: 8] == "P" && dir_entry[(base+1)*8 +: 8] == "I" &&
                     dir_entry[(base+2)*8 +: 8] == "C" && dir_entry[(base+3)*8 +: 8] == "3" &&
                     dir_entry[(base+8)*8 +: 8] == "B" && dir_entry[(base+9)*8 +: 8] == "M" &&
                     dir_entry[(base+10)*8 +: 8] == "P")
                matching_resource = 3'd2;
            else if (dir_entry[(base+0)*8 +: 8] == "P" && dir_entry[(base+1)*8 +: 8] == "I" &&
                     dir_entry[(base+2)*8 +: 8] == "C" && dir_entry[(base+3)*8 +: 8] == "4" &&
                     dir_entry[(base+8)*8 +: 8] == "B" && dir_entry[(base+9)*8 +: 8] == "M" &&
                     dir_entry[(base+10)*8 +: 8] == "P")
                matching_resource = 3'd3;
            else
                matching_resource = 3'd4;
        end
    endfunction

    function is_title_entry;
        input integer base;
        begin
            is_title_entry =
                dir_entry[(base+0)*8 +: 8] == "T" && dir_entry[(base+1)*8 +: 8] == "I" &&
                dir_entry[(base+2)*8 +: 8] == "T" && dir_entry[(base+3)*8 +: 8] == "L" &&
                dir_entry[(base+4)*8 +: 8] == "E" && dir_entry[(base+5)*8 +: 8] == " " &&
                dir_entry[(base+6)*8 +: 8] == " " && dir_entry[(base+7)*8 +: 8] == " " &&
                dir_entry[(base+8)*8 +: 8] == "B" && dir_entry[(base+9)*8 +: 8] == "M" &&
                dir_entry[(base+10)*8 +: 8] == "P";
        end
    endfunction

    // Optional background music: MUSIC.WAV in the root directory.
    function is_music_entry;
        input integer base;
        begin
            is_music_entry =
                dir_entry[(base+0)*8 +: 8] == "M" && dir_entry[(base+1)*8 +: 8] == "U" &&
                dir_entry[(base+2)*8 +: 8] == "S" && dir_entry[(base+3)*8 +: 8] == "I" &&
                dir_entry[(base+4)*8 +: 8] == "C" && dir_entry[(base+5)*8 +: 8] == " " &&
                dir_entry[(base+6)*8 +: 8] == " " && dir_entry[(base+7)*8 +: 8] == " " &&
                dir_entry[(base+8)*8 +: 8] == "W" && dir_entry[(base+9)*8 +: 8] == "A" &&
                dir_entry[(base+10)*8 +: 8] == "V";
        end
    endfunction

    wire all_resources_valid = (resource_valid == 4'hf) &&
                               (!REQUIRE_TITLE || title_valid);

    task finish_with_error;
        input [7:0] code;
        begin
            fs_error <= code;
            state <= ST_FINISH;
        end
    endtask

    task accept_directory_entry;
        input integer base;
        reg [2:0] resource_index;
        reg [31:0] first_cluster;
        reg [31:0] file_size;
        begin
            resource_index = matching_resource(base);
            if (resource_index == 3'd4 && is_music_entry(base))
                resource_index = 3'd5;
            first_cluster = {dir_entry[(base+21)*8 +: 8], dir_entry[(base+20)*8 +: 8],
                             dir_entry[(base+27)*8 +: 8], dir_entry[(base+26)*8 +: 8]};
            file_size = dir_entry[(base+28)*8 +: 32];
            case (resource_index)
                3'd0: begin
                    resource0_cluster <= first_cluster;
                    resource0_size <= file_size;
                    resource_valid[0] <= 1'b1;
                end
                3'd1: begin
                    resource1_cluster <= first_cluster;
                    resource1_size <= file_size;
                    resource_valid[1] <= 1'b1;
                end
                3'd2: begin
                    resource2_cluster <= first_cluster;
                    resource2_size <= file_size;
                    resource_valid[2] <= 1'b1;
                end
                3'd3: begin
                    resource3_cluster <= first_cluster;
                    resource3_size <= file_size;
                    resource_valid[3] <= 1'b1;
                end
                3'd4: begin
                    title_cluster <= first_cluster;
                    title_size <= file_size;
                    title_valid <= 1'b1;
                end
                default: begin
                    music_cluster <= first_cluster;
                    music_size <= file_size;
                    music_valid <= 1'b1;
                end
            endcase
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            scan_done <= 1'b0;
            fs_error <= ERR_NONE;
            partition_lba <= 32'd0;
            sectors_per_cluster <= 8'd0;
            fat_start_lba <= 32'd0;
            data_start_lba <= 32'd0;
            max_cluster <= 32'd0;
            resource_valid <= 4'd0;
            title_valid <= 1'b0;
            music_valid <= 1'b0;
            music_cluster <= 32'd0;
            music_size <= 32'd0;
            resource0_cluster <= 32'd0;
            resource1_cluster <= 32'd0;
            resource2_cluster <= 32'd0;
            resource3_cluster <= 32'd0;
            title_cluster <= 32'd0;
            resource0_size <= 32'd0;
            resource1_size <= 32'd0;
            resource2_size <= 32'd0;
            resource3_size <= 32'd0;
            title_size <= 32'd0;
            sector_req <= 1'b0;
            sector_lba <= 32'd0;
            directory_entry_index <= 5'd0;
            rd_addr <= 9'd0;
            fetch_k <= 6'd0;
            root_cluster <= 32'd0;
            total_sectors <= 32'd0;
            fat_sectors <= 32'd0;
            fat_count <= 8'd0;
            reserved_sectors <= 16'd0;
            root_lba <= 32'd0;
            data_sector_count <= 32'd0;
            fat_span <= 32'd0;
            sectors_per_cluster_shift <= 3'd0;
            root_sector_index <= 7'd0;
        end else begin
            scan_done <= 1'b0;
            sector_req <= 1'b0;
            case (state)
                ST_IDLE: if (scan_start) begin
                    fs_error <= ERR_NONE;
                    partition_lba <= 32'd0;
                    resource_valid <= 4'd0;
                    title_valid <= 1'b0;
                    music_valid <= 1'b0;
                    state <= ST_READ0_REQ;
                end
                ST_READ0_REQ: if (!sector_busy) begin
                    sector_lba <= 32'd0;
                    sector_req <= 1'b1;
                    state <= ST_READ0_WAIT;
                end
                ST_READ0_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else if (b510 != 8'h55 || b511 != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else if (head[0] == 8'heb || head[0] == 8'he9) begin
                        partition_lba <= 32'd0;
                        state <= ST_BOOT_PARSE;
                    end else if (b450 == 8'h0b || b450 == 8'h0c) begin
                        partition_lba <= mbr_partition_lba;
                        sector_lba <= mbr_partition_lba;
                        state <= ST_BOOT_REQ;
                    end else begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end
                end
                ST_BOOT_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_BOOT_WAIT;
                end
                ST_BOOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else if (b510 != 8'h55 || b511 != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else
                        state <= ST_BOOT_PARSE;
                end
                ST_BOOT_PARSE: begin
                    if (le16(11) != 16'd512 || !valid_spc(head[13]) ||
                        le16(14) == 0 || (head[16] != 1 && head[16] != 2) ||
                        le16(17) != 0 || le16(22) != 0 || le32(32) == 0 ||
                        le32(36) == 0 || le32(44) < 2) begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end else begin
                        sectors_per_cluster <= head[13];
                        reserved_sectors <= le16(14);
                        fat_count <= head[16];
                        total_sectors <= le32(32);
                        fat_sectors <= le32(36);
                        root_cluster <= le32(44);
                        sectors_per_cluster_shift <= spc_shift(head[13]);
                        fat_span <= head[16] == 2 ? (le32(36) << 1) : le32(36);
                        fat_start_lba <= partition_lba + le16(14);
                        state <= ST_BOOT_LAYOUT;
                    end
                end
                ST_BOOT_LAYOUT: begin
                    data_start_lba <= partition_lba + reserved_sectors + fat_span;
                    data_sector_count <= total_sectors - reserved_sectors - fat_span;
                    state <= ST_BOOT_ROOT;
                end
                ST_BOOT_ROOT: begin
                    root_sector_index <= 7'd0;
                    max_cluster <= (data_sector_count >> sectors_per_cluster_shift) + 1'b1;
                    root_lba <= data_start_lba
                                + ((root_cluster - 2) << sectors_per_cluster_shift);
                    sector_lba <= data_start_lba
                                  + ((root_cluster - 2) << sectors_per_cluster_shift);
                    state <= ST_ROOT_REQ;
                end
                ST_ROOT_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_ROOT_WAIT;
                end
                ST_ROOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else begin
                        directory_entry_index <= 5'd0;
                        state <= ST_DIR_SCAN;
                    end
                end
                ST_DIR_SCAN: begin
                    fetch_k <= 6'd0;
                    state <= ST_DIR_FETCH;
                end
                // rd_addr is registered, then the RAM output is registered:
                // the byte requested in clock k arrives in rd_q in clock k+2.
                ST_DIR_FETCH: begin
                    rd_addr <= {directory_entry_index[3:0], fetch_k[4:0]};
                    if (fetch_k >= 6'd2)
                        dir_entry <= {rd_q, dir_entry[255:8]};
                    if (fetch_k == 6'd33)
                        state <= ST_DIR_CHECK;
                    else
                        fetch_k <= fetch_k + 1'b1;
                end
                ST_DIR_CHECK: begin
                    if (dir_entry[7:0] == 8'h00) begin
                        if (all_resources_valid)
                            state <= ST_FINISH;
                        else
                            finish_with_error(ERR_RESOURCE_MISSING);
                    end else begin
                        if (dir_entry[7:0] != 8'he5 &&
                            (dir_entry[11*8 +: 8] & 8'h18) == 0 &&
                            dir_entry[11*8 +: 8] != 8'h0f &&
                            ((dir_entry[7:0] == "P" &&
                              dir_entry[15:8] == "I" &&
                              dir_entry[23:16] == "C" &&
                              dir_entry[31:24] >= "1" &&
                              dir_entry[31:24] <= "4" &&
                              dir_entry[39:32] == " " &&
                              dir_entry[47:40] == " " &&
                              dir_entry[55:48] == " " &&
                              dir_entry[63:56] == " " &&
                              dir_entry[71:64] == "B" &&
                              dir_entry[79:72] == "M" &&
                              dir_entry[87:80] == "P") ||
                             is_title_entry(0) || is_music_entry(0)))
                            accept_directory_entry(0);

                        if (directory_entry_index == 5'd15) begin
                            state <= ST_DIR_NEXT;
                        end else begin
                            directory_entry_index <= directory_entry_index + 1'b1;
                            state <= ST_DIR_SCAN;
                        end
                    end
                end
                // Evaluate flags one clock after accepting the last entry.
                ST_DIR_NEXT: begin
                            // Keep walking the root cluster until MUSIC.WAV is
                            // found; it is optional, so its absence is not an
                            // error once the required files are present.
                            if (all_resources_valid && music_valid)
                                state <= ST_FINISH;
                            else if (dir_entry[7:0] != 8'h00 &&
                                     ({1'b0, root_sector_index} + 1'b1) <
                                     (8'd1 << sectors_per_cluster_shift)) begin
                                // Entries may continue in the next sector of
                                // the root cluster; keep scanning before
                                // declaring the resources missing.
                                root_sector_index <= root_sector_index + 1'b1;
                                sector_lba <= root_lba +
                                              {25'd0, root_sector_index} + 1'b1;
                                state <= ST_ROOT_REQ;
                            end else if (all_resources_valid)
                                state <= ST_FINISH;
                            else
                                finish_with_error(ERR_RESOURCE_MISSING);
                end
                ST_FINISH: begin
                    scan_done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule

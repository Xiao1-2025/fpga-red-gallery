`timescale 1ns/1ps
// Minimal SPI-mode SD/SDHC card for testbenches.
//
//  - present = 0: the card is not in the slot. MISO floats high (host pull-up),
//    so the host reads 0xFF for every byte: no response at all.
//  - present = 1: answers CMD0, CMD8, CMD55, ACMD41 (ready after a couple of
//    polls), CMD58 (OCR with CCS = SDHC) and CMD17 (single block read: R1,
//    token 0xFE, 512 data bytes, CRC-16/CCITT).
//  - Sector data comes from tb_sd_hotplug.card_byte(lba, pos).
//
// SPI mode 0, CS active low: MOSI is sampled on the rising SCLK edge, MISO is
// changed on the falling edge. The host byte boundary is tracked by counting
// rising edges, so every queued byte is shifted out aligned with the host's
// own byte, as a real card does. Responses start one byte after the command
// (NCR = 1).
module sd_card_spi_model #(
    parameter integer ACMD41_POLLS_BEFORE_READY = 2
) (
    input  wire sclk,
    input  wire cs_n,
    input  wire mosi,
    output wire miso,
    input  wire present
);
    reg miso_r = 1'b1;
    assign miso = (present && !cs_n) ? miso_r : 1'b1;

    reg [7:0] rx_shift = 0;
    integer rx_bits = 0;
    reg [47:0] cmd_buf = 0;
    integer cmd_bytes = 0;
    reg in_cmd = 0;

    reg [7:0] txq [0:1023];
    integer tx_head = 0, tx_tail = 0;
    reg [7:0] tx_byte = 8'hff;

    integer acmd41_polls = 0;
    reg initialized = 0;
    reg idle = 1;
    integer cmd_count = 0;
    integer reads_done = 0;

    function [15:0] crc16_step(input [15:0] c, input [7:0] d);
        integer i;
        reg [15:0] x;
        begin
            x = c;
            for (i = 7; i >= 0; i = i - 1) begin
                if (x[15] ^ d[i]) x = {x[14:0], 1'b0} ^ 16'h1021;
                else x = {x[14:0], 1'b0};
            end
            crc16_step = x;
        end
    endfunction

    task push(input [7:0] b);
        begin txq[tx_tail % 1024] = b; tx_tail = tx_tail + 1; end
    endtask

    task respond(input [5:0] idx, input [31:0] arg);
        integer k, lba;
        reg [15:0] crc;
        reg [7:0] d;
        begin
            cmd_count = cmd_count + 1;
            push(8'hff);                                  // NCR
            case (idx)
                6'd0:  begin push(8'h01); initialized = 0; idle = 1; acmd41_polls = 0; end
                6'd8:  begin push(8'h01); push(8'h00); push(8'h00); push({4'h0, arg[11:8]}); push(arg[7:0]); end
                6'd55: push(idle ? 8'h01 : 8'h00);
                6'd41: begin
                    if (acmd41_polls < ACMD41_POLLS_BEFORE_READY) begin
                        push(8'h01); acmd41_polls = acmd41_polls + 1;
                    end else begin
                        push(8'h00); idle = 0; initialized = 1;
                    end
                end
                6'd58: begin push(8'h00); push(8'hc0); push(8'hff); push(8'h80); push(8'h00); end
                6'd17: begin
                    if (!initialized) push(8'h04);
                    else begin
                        push(8'h00);
                        push(8'hff); push(8'hff);        // a little busy time
                        push(8'hfe);
                        lba = arg;                       // SDHC: block address
                        crc = 16'h0000;
                        for (k = 0; k < 512; k = k + 1) begin
                            d = tb_sd_hotplug.card_byte(lba, k);
                            push(d);
                            crc = crc16_step(crc, d);
                        end
                        push(crc[15:8]); push(crc[7:0]);
                        reads_done = reads_done + 1;
                    end
                end
                default: push(8'h04);                    // illegal command
            endcase
        end
    endtask

    // Load the next queued byte (or idle 0xFF) at a host byte boundary.
    task load_tx;
        begin
            if (tx_head != tx_tail) begin
                tx_byte = txq[tx_head % 1024]; tx_head = tx_head + 1;
            end else tx_byte = 8'hff;
        end
    endtask

    // Host byte reception (rising SCLK edge).
    always @(posedge sclk) begin
        if (present && !cs_n) begin
            rx_shift = {rx_shift[6:0], mosi};
            rx_bits = rx_bits + 1;
            if (rx_bits == 8) begin
                rx_bits = 0;
                if (!in_cmd) begin
                    if (rx_shift[7:6] == 2'b01) begin
                        in_cmd = 1; cmd_bytes = 1; cmd_buf = {40'd0, rx_shift};
                    end
                end else begin
                    cmd_buf = {cmd_buf[39:0], rx_shift};
                    cmd_bytes = cmd_bytes + 1;
                    if (cmd_bytes == 6) begin
                        in_cmd = 0;
                        respond(cmd_buf[45:40], cmd_buf[39:8]);
                    end
                end
            end
        end
    end

    // MISO for the next rising edge, set on every falling edge: bit number
    // rx_bits of the byte the host is shifting in. Position 0 starts a new byte.
    always @(negedge sclk) begin
        if (present && !cs_n) begin
            if (rx_bits == 0) load_tx;
            miso_r <= tx_byte[7 - rx_bits];
        end
    end

    // The first bit of the first byte after CS falls must already be on MISO
    // before the first rising edge.
    always @(negedge cs_n) begin
        rx_bits = 0; in_cmd = 0;
        tx_head = tx_tail;
        if (present) begin
            load_tx;
            miso_r <= tx_byte[7];
        end
    end

    always @(posedge cs_n) begin
        rx_bits = 0; in_cmd = 0; tx_head = tx_tail;
    end
endmodule

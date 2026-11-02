#!/usr/bin/env python3
"""Generate rtl/display/subtitle_scroll_24.v and tests/subtitle_expected.mem.

One caption per picture; the caption of the picture on screen scrolls in from
the right and restarts whenever the picture changes. Text is GLYPH_SIZE x GLYPH_SIZE SimSun
bitmaps; each distinct character is stored once (glyph 0 is blank) and every
caption is a list of glyph ids.

Edit CAPTIONS below and re-run:  python build_subtitles.py
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

CAPTIONS = [
    "一九二一年，革命理想从南湖红船启航，中国共产党由此登上历史舞台。",
    "井冈山上星火初燃，革命先辈在探索中开辟符合中国实际的革命道路。",
    "长征途中，红军勇士飞夺泸定桥，以坚定信念和英勇斗争突破重重险阻。",
    "从红船启航到新中国成立，改变的是时代，不变的是代代传承的理想与信念。",
]
MAX_CHARS = 40          # per caption (a 6-bit index, 64 would also fit)
GLYPH_SIZE = 24         # SimSun pixel size: 12, 16 or 24
GLYPH_W = GLYPH_SIZE
GLYPH_H = GLYPH_SIZE
assert GLYPH_SIZE in (12, 16, 24)
STRIDE = 24 if GLYPH_SIZE == 24 else 16     # horizontal cell per character

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_V = os.path.join(HERE, "..", "rtl", "display", "subtitle_scroll_24.v")
OUT_MEM = os.path.join(HERE, "..", "tests", "subtitle_expected.mem")
FONT_CANDIDATES = [
    r"C:/Windows/Fonts/simsun.ttc",
    "/c/Windows/Fonts/simsun.ttc",
    "/mnt/c/Windows/Fonts/simsun.ttc",
]


def load_font():
    path = next((p for p in FONT_CANDIDATES if os.path.exists(p)), None)
    if path is None:
        sys.exit("SimSun (simsun.ttc) not found")
    return ImageFont.truetype(path, GLYPH_SIZE)


def render(font, ch):
    im = Image.new("1", (GLYPH_W, GLYPH_H), 0)
    d = ImageDraw.Draw(im)
    d.fontmode = "1"
    d.text((0, -1 if GLYPH_SIZE == 12 else 0), ch, font=font, fill=1)
    rows = []
    for y in range(GLYPH_H):
        v = 0
        for x in range(GLYPH_W):
            v = (v << 1) | (1 if im.getpixel((x, y)) else 0)
        rows.append(v)
    return rows


def main():
    font = load_font()
    missing = render(font, "\uffff")          # the font's "no glyph" box
    glyphs = [[0] * GLYPH_H]                   # id 0 = blank
    ids = {}
    for cap in CAPTIONS:
        if len(cap) > MAX_CHARS:
            sys.exit("caption too long: %d chars" % len(cap))
        for ch in cap:
            if ch in ids:
                continue
            rows = render(font, ch)
            if rows == missing or not any(rows):
                sys.exit("font has no usable glyph for %r (U+%04X)" % (ch, ord(ch)))
            ids[ch] = len(glyphs)
            glyphs.append(rows)
    if len(glyphs) > 128:
        sys.exit("too many distinct glyphs: %d" % len(glyphs))

    # ---- glyph ROM
    rom = []
    for gid, rows in enumerate(glyphs):
        if gid == 0:
            continue
        ch = next(c for c, i in ids.items() if i == gid)
        rom.append("        // U+%04X" % ord(ch))
        for r in range(0, GLYPH_H, 2):
            hexw = (GLYPH_W + 3) // 4
            rom.append("        glyph_rom[%d]=%d'h%0*X; glyph_rom[%d]=%d'h%0*X;" %
                       (gid * GLYPH_H + r, GLYPH_W, hexw, rows[r],
                        gid * GLYPH_H + r + 1, GLYPH_W, hexw, rows[r + 1]))
    rom_text = "\n".join(rom)

    # ---- caption (char index -> glyph id) ROM
    case_lines = []
    for c, cap in enumerate(CAPTIONS):
        for i, ch in enumerate(cap):
            case_lines.append("            8'd%d: caption_glyph = 7'd%d;" % (c * 64 + i, ids[ch]))
    case_text = "\n".join(case_lines)
    len_text = "\n".join("    localparam integer LEN%d = %d;" % (c, len(cap))
                         for c, cap in enumerate(CAPTIONS))
    len_case = "\n".join("            2'd%d: text_w_of = LEN%d * CELL;" % (c, c)
                         for c in range(len(CAPTIONS)))

    text = TEMPLATE
    for k, v in {
        "@LENS@": len_text,
        "@LEN_CASE@": len_case,
        "@CASES@": case_text,
        "@ROMINIT@": rom_text,
        "@NGLYPH@": str(len(glyphs)),
        "@GW@": str(GLYPH_W),
        "@GH@": str(GLYPH_H),
        "@GWBITS@": str(GLYPH_W - 1),
        "@STRIDE@": str(STRIDE),
        "@ADDR@": {16: "{1'b0, gid3, glyph_row[3:0]}",
                   24: "({5'b0, gid3} << 4) + ({5'b0, gid3} << 3) + {7'b0, glyph_row}",
                   12: "({5'b0, gid3} << 3) + ({5'b0, gid3} << 2) + {7'b0, glyph_row}"}[GLYPH_H],
        # character index and its start offset for one cell of STRIDE pixels
        "@IDX@": {16: "d1[10:4]", 24: "(d1[10:0] * 683) >> 14"}[STRIDE],
        "@IDXMUL@": {16: "({5'b0, idx2} << 4)",
                     24: "(({5'b0, idx2} << 4) + ({5'b0, idx2} << 3))"}[STRIDE],
        "@ROMWORDS@": str(len(glyphs) * GLYPH_H),
    }.items():
        text = text.replace(k, v)
    with open(OUT_V, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)

    # ---- expected bitmaps for the testbench: 640 pixel columns per row
    lines = []
    for cap in CAPTIONS:
        for r in range(GLYPH_H):
            bits = []
            for i in range(MAX_CHARS):
                if i < len(cap):
                    row = glyphs[ids[cap[i]]][r]
                    bits.extend("1" if (row >> (GLYPH_W - 1 - x)) & 1 else "0"
                                for x in range(GLYPH_W))
                    bits.extend("0" * (STRIDE - GLYPH_W))
                else:
                    bits.extend("0" * STRIDE)
            lines.append("".join(bits))
    with open(OUT_MEM, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")

    print("wrote %s (%d glyphs, %d captions)" % (os.path.abspath(OUT_V), len(glyphs) - 1, len(CAPTIONS)))
    print("wrote %s" % os.path.abspath(OUT_MEM))


TEMPLATE = r"""`timescale 1ns/1ps

// Bottom scrolling subtitle banner, one caption per picture.
// GENERATED by assets/build_subtitles.py - edit CAPTIONS there, not this file.
//
// The caption of the picture on screen (caption_sel) scrolls right-to-left by
// SCROLL_STEP pixels per frame and wraps around; when the picture changes the
// scroll restarts from the right edge. Every output (RGB and all video timing
// signals consumed downstream) is delayed by the same single clock, so
// DE/X/sync alignment is preserved when chained after other overlay stages.
//
// Text is @GW@x@GH@ bitmaps (one @STRIDE@ px cell per character). The characters of a
// caption are glyph ids in a small ROM. Which character is under a pixel, the
// column inside it and the glyph id are worked out LOOKAHEAD clocks ahead in a
// three-stage pipeline (pixel_x is a free-running column counter, H_TOTAL
// columns per line), so the glyph RAM read still lines up with the registered
// output and the bundle gets exactly one clock of delay.
module subtitle_scroll_24 #(
    parameter integer SUB_Y = 438,
    parameter integer SCROLL_STEP = 2,
    parameter integer H_ACT = 640,
    parameter integer H_TOTAL = 800,
    parameter [23:0] TEXT_COLOR = 24'h8B0000     // dark red
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        hsync,
    input  wire        vsync,
    input  wire        de,
    input  wire [9:0]  pixel_x,
    input  wire [23:0] rgb_in,
    input  wire [1:0]  caption_sel,
    output reg         hsync_out,
    output reg         vsync_out,
    output reg         de_out,
    output reg  [9:0]  pixel_x_out,
    output wire [23:0] rgb_out,
    output wire        subtitle_active
);
    localparam integer GLYPH_W = @GW@;
    localparam integer GLYPH_H = @GH@;
@LENS@
    localparam [9:0] H_ACT_R = H_ACT;
    localparam [9:0] H_LAST = H_TOTAL - 1;
    localparam [11:0] SUB_Y_R = SUB_Y;
    localparam [11:0] GLYPH_H_R = GLYPH_H;
    localparam [10:0] STEP_R = SCROLL_STEP;
    localparam integer CELL = @STRIDE@;
    localparam integer LOOKAHEAD = 3;

    function [10:0] text_w_of;
        input [1:0] sel;
        begin
            case (sel)
@LEN_CASE@
                default: text_w_of = LEN0 * CELL;
            endcase
        end
    endfunction

    // {caption, char index} -> glyph id (0 = blank).
    function [6:0] caption_glyph;
        input [7:0] addr;
        begin
            case (addr)
@CASES@
                default: caption_glyph = 7'd0;
            endcase
        end
    endfunction

    // @NGLYPH@ glyphs including the blank one.
    reg [@GWBITS@:0] glyph_rom [0:@ROMWORDS@-1] /* fehdl force_ram=1, ram_style="bram" */;
    integer init_index;
    initial begin
        for (init_index = 0; init_index < @ROMWORDS@; init_index = init_index + 1)
            glyph_rom[init_index] = {GLYPH_W{1'b0}};

@ROMINIT@
    end

    // Scroll state: banner_x = H_ACT - scroll_pos walks from +H_ACT (off right)
    // down to -text_w (off left), then wraps. Signed math keeps the partially
    // off-screen frames correct.
    reg [10:0] scroll_pos;
    reg [1:0] caption_q;
    reg [10:0] text_w_q;
    reg [10:0] span_q;
    reg [11:0] line_y;
    reg de_q;
    reg vs_q;
    wire frame_start = vs_q && !vsync;

    wire signed [11:0] banner_x = $signed({2'b00, H_ACT_R}) - $signed({1'b0, scroll_pos});
    wire signed [11:0] text_w_s = $signed({1'b0, text_w_q});
    wire y_band = de && (line_y >= SUB_Y_R) && (line_y < SUB_Y_R + GLYPH_H_R);
    wire [4:0] glyph_row = line_y - SUB_Y_R;

    // Pipeline for the pixel LOOKAHEAD clocks ahead of pixel_x.
    wire [9:0] xa_raw = pixel_x + LOOKAHEAD;
    wire [9:0] xa = (xa_raw >= H_TOTAL) ? (xa_raw - H_TOTAL) : xa_raw;
    reg signed [11:0] d1;                    // offset of that pixel inside the text
    always @(posedge clk)
        d1 <= $signed({2'b00, xa}) - banner_x;

    reg v2;                                  // inside the text
    reg [10:0] d2;
    reg [5:0] idx2;                          // character index
    always @(posedge clk) begin
        v2 <= (d1 >= 0) && (d1 < text_w_s);
        d2 <= d1[10:0];
        idx2 <= @IDX@;
    end

    reg v3;
    reg [4:0] col3;                          // column inside the character
    reg [6:0] gid3;                          // glyph id (0 = blank)
    always @(posedge clk) begin
        v3 <= v2;
        col3 <= d2 - @IDXMUL@;
        gid3 <= v2 ? caption_glyph({caption_q, idx2}) : 7'd0;
    end

    wire [11:0] glyph_address = @ADDR@;

    reg [23:0] rgb_q;
    reg [@GWBITS@:0] glyph_row_q;
    reg [4:0] glyph_col_q;
    reg text_bounds_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hsync_out <= 1'b1;
            vsync_out <= 1'b1;
            de_out <= 1'b0;
            pixel_x_out <= 10'd0;
            rgb_q <= 24'd0;
            glyph_row_q <= {GLYPH_W{1'b0}};
            glyph_col_q <= 5'd0;
            text_bounds_q <= 1'b0;
            scroll_pos <= 11'd0;
            caption_q <= 2'd0;
            text_w_q <= LEN0 * CELL;
            span_q <= H_ACT + LEN0 * CELL;
            line_y <= 12'd0;
            de_q <= 1'b0;
            vs_q <= 1'b1;
        end else begin
            hsync_out <= hsync;
            vsync_out <= vsync;
            de_out <= de;
            pixel_x_out <= pixel_x;
            rgb_q <= rgb_in;
            de_q <= de;
            vs_q <= vsync;
            if (!vsync)
                line_y <= 12'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;
            if (frame_start) begin
                caption_q <= caption_sel;
                text_w_q <= text_w_of(caption_sel);
                span_q <= H_ACT + text_w_of(caption_sel);
                if (caption_sel != caption_q)
                    scroll_pos <= 11'd0;                // new picture: start over
                else if (scroll_pos >= span_q - STEP_R)
                    scroll_pos <= 11'd0;
                else
                    scroll_pos <= scroll_pos + STEP_R;
            end
            text_bounds_q <= y_band && v3 && (col3 < GLYPH_W);
            if (y_band && v3 && (col3 < GLYPH_W))
                glyph_row_q <= glyph_rom[glyph_address];
            else
                glyph_row_q <= {GLYPH_W{1'b0}};
            glyph_col_q <= col3;
        end
    end

    wire subtitle_hit = text_bounds_q && glyph_row_q[GLYPH_W - 1 - glyph_col_q];
    assign rgb_out = subtitle_hit ? TEXT_COLOR : rgb_q;
    assign subtitle_active = subtitle_hit;
endmodule
"""

if __name__ == "__main__":
    main()

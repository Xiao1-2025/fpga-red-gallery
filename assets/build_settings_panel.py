#!/usr/bin/env python3
"""Generate rtl/display/settings_panel_overlay.v.

The panel text uses 16 px SimSun bitmaps. Every glyph is stored as 8x16
"half glyphs": an ASCII character is one half glyph, a Chinese character is
two consecutive ones (left half, right half). The panel then only has to deal
with 8-pixel text slots. The generator emits the font ROM and the constant
string vectors (8 slots x 7 bits per string); the logic around them is the
template below.

Run:  python build_settings_panel.py [output.v]
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

FONT_CANDIDATES = [
    r"C:\Windows\Fonts\simsun.ttc",
    "/c/Windows/Fonts/simsun.ttc",
    "/mnt/c/Windows/Fonts/simsun.ttc",
]
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, "..", "rtl", "display", "settings_panel_overlay.v")

# ----------------------------------------------------------------- text ----
TITLE = "设置"
LABELS = ["当前画面", "音量", "亮度", "自动轮播", "轮播间隔", "转场效果", "背景音乐"]
VOLUME = ["0%", "25%", "50%", "75%", "100%"]          # volume code 0..4
BRIGHT = ["25%", "50%", "75%", "100%"]                # brightness code 0..3
AUTO = ["关", "开"]
PERIOD = ["2 秒", "5 秒", "10 秒", "30 秒"]           # period code 0..3
TRANSITION = "淡入淡出"
MUSIC = ["提示音", "播放中", "已暂停"]                # tone / playing / paused
ROWS = len(LABELS)

SLOTS = 8  # slots per label / value string


class Font:
    def __init__(self):
        path = next((p for p in FONT_CANDIDATES if os.path.exists(p)), None)
        if path is None:
            sys.exit("SimSun (simsun.ttc) not found")
        self.font = ImageFont.truetype(path, 16)
        self.halves = [[0] * 16]          # index 0: blank
        self.index = {" ": 0}

    def _render(self, ch, width):
        im = Image.new("1", (width, 16), 0)
        d = ImageDraw.Draw(im)
        d.fontmode = "1"
        d.text((0, 0), ch, font=self.font, fill=1)
        rows = []
        for y in range(16):
            v = 0
            for x in range(width):
                v = (v << 1) | (1 if im.getpixel((x, y)) else 0)
            rows.append(v)
        return rows

    def add(self, ch):
        if ch in self.index:
            return self.index[ch]
        if ord(ch) < 256:
            rows = self._render(ch, 8)
            self.index[ch] = len(self.halves)
            self.halves.append(rows)
        else:
            rows = self._render(ch, 16)
            self.index[ch] = len(self.halves)
            self.halves.append([r >> 8 for r in rows])
            self.halves.append([r & 0xFF for r in rows])
        return self.index[ch]

    def slots(self, text):
        out = []
        for ch in text:
            h = self.add(ch)
            out.append(h)
            if ord(ch) >= 256:
                out.append(h + 1)
        return out


def vec_right(slots, width=SLOTS):
    """Right-aligned 8-slot vector, slot 0 is the leftmost cell."""
    if len(slots) > width:
        sys.exit("string too long for %d slots" % width)
    cells = [0] * (width - len(slots)) + slots
    return cells


def vec_left(slots, width=SLOTS):
    if len(slots) > width:
        sys.exit("string too long for %d slots" % width)
    return slots + [0] * (width - len(slots))


def verilog_vec(cells):
    """{slot7, ..., slot0} as a 56-bit concatenation."""
    return "{" + ", ".join("7'd%d" % c for c in reversed(cells)) + "}"


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_OUT
    f = Font()
    for ch in " 0123456789/%":
        f.add(ch)

    consts = []   # (name, comment, cells)

    def const(name, comment, text, align):
        cells = (vec_right if align == "right" else vec_left)(f.slots(text))
        consts.append((name, comment, cells))
        return name

    title_name = const("TITLE_VEC", TITLE, TITLE, "left")
    label_names = [const("LBL%d_VEC" % i, t, t, "left") for i, t in enumerate(LABELS)]
    vol_names = [const("VOL%d_VEC" % i, t, t, "right") for i, t in enumerate(VOLUME)]
    bri_names = [const("BRI%d_VEC" % i, t, t, "right") for i, t in enumerate(BRIGHT)]
    auto_names = [const("AUTO%d_VEC" % i, t, t, "right") for i, t in enumerate(AUTO)]
    per_names = [const("PER%d_VEC" % i, t, t, "right") for i, t in enumerate(PERIOD)]
    trans_name = const("TRANS_VEC", TRANSITION, TRANSITION, "right")
    music_names = [const("MUS%d_VEC" % i, t, t, "right") for i, t in enumerate(MUSIC)]

    h_digit0 = f.index["0"]
    h_slash = f.index["/"]
    h_four = f.index["4"]
    if len(f.halves) > 128:
        sys.exit("font has %d halves, 7-bit index overflows" % len(f.halves))

    # ---- ROM init
    rom_lines = []
    for h, rows in enumerate(f.halves):
        for r, v in enumerate(rows):
            if v:
                rom_lines.append("        font_rom[%d] = 8'h%02X;" % (h * 16 + r, v))
    rom_text = "\n".join(rom_lines)

    const_text = []
    for name, comment, cells in consts:
        const_text.append("    localparam [55:0] %s = %s;  // %s" %
                          (name, verilog_vec(cells), comment))
    const_text = "\n".join(const_text)

    def pick(names, sel, default_last=True):
        """Nested conditional picking names[sel_value]."""
        expr = names[-1]
        for i in reversed(range(len(names) - 1)):
            expr = "(%s == %d) ? %s : %s" % (sel, i, names[i], expr)
        return expr

    text = TEMPLATE
    repl = {
        "@ROM_INIT@": rom_text,
        "@CONSTS@": const_text,
        "@TITLE_VEC@": title_name,
        "@LABEL_CASES@": "\n".join(
            "            3'd%d: label_vec = %s;" % (i, n) for i, n in enumerate(label_names)),
        "@VOL_EXPR@": pick(vol_names, "vol_code"),
        "@BRI_EXPR@": pick(bri_names, "bri_code"),
        "@AUTO_EXPR@": "auto_enabled ? %s : %s" % (auto_names[1], auto_names[0]),
        "@PER_EXPR@": pick(per_names, "period_code"),
        "@TRANS_VEC@": trans_name,
        "@MUSIC_EXPR@": "music_paused ? %s : (music_on ? %s : %s)" %
                        (music_names[2], music_names[1], music_names[0]),
        "@H_DIGIT0@": str(h_digit0),
        "@H_SLASH@": str(h_slash),
        "@H_FOUR@": str(h_four),
        "@NHALVES@": str(len(f.halves)),
    }
    for k, v in repl.items():
        text = text.replace(k, v)
    with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    print("wrote", os.path.abspath(out_path), "(%d half glyphs)" % len(f.halves))


TEMPLATE = r"""`timescale 1ns/1ps

// Settings panel shown for a few seconds after a parameter changes.
// GENERATED by assets/build_settings_panel.py - edit the generator, not this
// file. The text font is 16 px SimSun stored as 8x16 half glyphs (@NHALVES@ used).
//
//   当前画面  1 / 4
//   音量      75%        <- the row that just changed is highlighted
//   亮度      100%
//   自动轮播  开
//   轮播间隔  10 秒
//   转场效果  淡入淡出
//   背景音乐  播放中
//
// Trigger: any change of volume, brightness, auto-play, slideshow period or the
// SW4 audio pause switch
// (compared once per frame) starts the SHOW_FRAMES timer and highlights that
// row; another change while it is showing restarts the timer. Changes are
// ignored while the boot title is shown and for ARM_FRAMES afterwards, so the
// values loaded from Flash at power-up never pop the panel. The current-image
// row follows the slideshow but does not trigger the panel.
//
// Timing contract: rgb_in is the registered output of the previous stage and
// pixel_x/de/vsync belong to the same bundle. The panel pixels are computed
// LOOKAHEAD pixel clocks ahead (pixel_x is a free-running column counter) so
// the registered result lines up with rgb_in without delaying the video, and
// rgb_out is only a combinational mux behind that registered result.
module settings_panel_overlay #(
    parameter integer PANEL_X = 120,
    parameter integer PANEL_Y = 114,
    parameter integer SHOW_FRAMES = 210,   // ~3.5 s at 59.5 Hz
    parameter integer ARM_FRAMES = 60
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,              // active low
    input  wire        de,
    input  wire [9:0]  pixel_x,
    input  wire [23:0] rgb_in,
    input  wire        suppress,           // boot title on screen
    input  wire [1:0]  active_index,
    input  wire [7:0]  volume,
    input  wire [7:0]  brightness,
    input  wire        auto_enabled,
    input  wire [1:0]  period_code,        // 0..3 = 2 / 5 / 10 / 30 s
    input  wire        music_on,
    input  wire        music_paused,       // SW4 audio pause
    output wire [23:0] rgb_out,
    output wire        panel_visible
);
    localparam integer LOOKAHEAD = 5;      // pixel pipeline depth (P1..P5)
    localparam integer PW = 400;
    localparam integer TITLE_H = 44;
    localparam integer ROW_H = 28;
    localparam integer ROW_N = 7;
    localparam integer PH = TITLE_H + ROW_N * ROW_H + 12;
    localparam integer LBL_X = 24;         // label text, relative to the panel
    localparam integer VAL_X = PW - 24 - 64;
    localparam integer TITLE_X = 24;

@CONSTS@

    // ------------------------------------------------------------ font ROM
    reg [7:0] font_rom [0:2047] /* fehdl force_ram=1, ram_style="bram" */;
    integer rom_i;
    initial begin
        for (rom_i = 0; rom_i < 2048; rom_i = rom_i + 1)
            font_rom[rom_i] = 8'h00;
@ROM_INIT@
    end

    // ----------------------------------------- parameter codes and trigger
    wire [2:0] vol_code = (volume >= 8'd224) ? 3'd4 :
                          (volume >= 8'd160) ? 3'd3 :
                          (volume >= 8'd96)  ? 3'd2 :
                          (volume >= 8'd32)  ? 3'd1 : 3'd0;
    // 0..3 = 25 / 50 / 75 / 100 %
    wire [1:0] bri_code = (brightness >= 8'd224) ? 2'd3 :
                          (brightness >= 8'd160) ? 2'd2 :
                          (brightness >= 8'd96)  ? 2'd1 : 2'd0;

    reg vs_q;
    wire frame_start = vs_q && !vsync;
    reg [2:0] vol_q;
    reg [1:0] bri_q;
    reg auto_q;
    reg [1:0] period_q;
    reg paused_q;
    reg [7:0] arm_count;
    reg [8:0] show_count;
    reg [2:0] hl_row;              // 1 volume, 2 brightness, 3 auto, 4 period

    assign panel_visible = (show_count != 0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_q <= 1'b1;
            vol_q <= 3'd0;
            bri_q <= 2'd0;
            auto_q <= 1'b0;
            period_q <= 2'd0;
            paused_q <= 1'b0;
            arm_count <= ARM_FRAMES;
            show_count <= 9'd0;
            hl_row <= 3'd7;
        end else begin
            vs_q <= vsync;
            if (frame_start) begin
                vol_q <= vol_code;
                bri_q <= bri_code;
                auto_q <= auto_enabled;
                period_q <= period_code;
                paused_q <= music_paused;

                if (suppress)
                    arm_count <= ARM_FRAMES;
                else if (arm_count != 0)
                    arm_count <= arm_count - 1'b1;

                if (suppress || arm_count != 0) begin
                    show_count <= 9'd0;
                end else if (vol_code != vol_q) begin
                    hl_row <= 3'd1;
                    show_count <= SHOW_FRAMES;
                end else if (bri_code != bri_q) begin
                    hl_row <= 3'd2;
                    show_count <= SHOW_FRAMES;
                end else if (auto_enabled != auto_q) begin
                    hl_row <= 3'd3;
                    show_count <= SHOW_FRAMES;
                end else if (period_code != period_q) begin
                    hl_row <= 3'd4;
                    show_count <= SHOW_FRAMES;
                end else if (music_paused != paused_q) begin
                    hl_row <= 3'd6;
                    show_count <= SHOW_FRAMES;
                end else if (show_count != 0) begin
                    show_count <= show_count - 1'b1;
                end
            end
        end
    end

    // -------------------------------------------------------- line tracking
    reg [11:0] line_y;
    reg de_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_y <= 12'd0;
            de_q <= 1'b0;
        end else begin
            de_q <= de;
            if (!vsync)
                line_y <= 12'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;
        end
    end

    // Per-line row decode. line_y only changes at the end of an active line,
    // so these quasi-static stages settle long before the next line starts.
    wire [11:0] ly_rel = line_y - PANEL_Y;
    reg [8:0] py_q;              // line in_panel the panel
    reg in_py_q;
    reg [8:0] by_q;              // line in_panel the row area
    reg [2:0] row_q;             // 0..6, 7 = below the last row
    reg [4:0] row_y_q;           // 0..27 in_panel the row
    always @(posedge clk) begin
        py_q <= ly_rel[8:0];
        in_py_q <= (ly_rel < PH);
        by_q <= py_q - TITLE_H;
        row_q <= (by_q >= 9'd196) ? 3'd7 :
                 (by_q >= 9'd168) ? 3'd6 :
                 (by_q >= 9'd140) ? 3'd5 :
                 (by_q >= 9'd112) ? 3'd4 :
                 (by_q >= 9'd84)  ? 3'd3 :
                 (by_q >= 9'd56)  ? 3'd2 :
                 (by_q >= 9'd28)  ? 3'd1 : 3'd0;
        case (row_q)
            3'd0: row_y_q <= by_q[4:0];
            3'd1: row_y_q <= by_q - 9'd28;
            3'd2: row_y_q <= by_q - 9'd56;
            3'd3: row_y_q <= by_q - 9'd84;
            3'd4: row_y_q <= by_q - 9'd112;
            3'd5: row_y_q <= by_q - 9'd140;
            default: row_y_q <= by_q - 9'd168;
        endcase
    end
    wire body_q = (py_q >= TITLE_H);

    // ------------------------------------------------------ pixel pipeline
    // P1: panel-relative column of the pixel LOOKAHEAD clocks ahead.
    reg [9:0] xr_p1;
    reg in_px_p1;
    wire [9:0] nx = pixel_x + LOOKAHEAD;
    wire [9:0] xr_now = nx - PANEL_X;
    always @(posedge clk) begin
        xr_p1 <= xr_now;
        in_px_p1 <= (xr_now < PW);
    end

    // P2: classify the pixel and locate its text slot.
    localparam [2:0] CLS_NONE = 3'd0, CLS_BORDER = 3'd1, CLS_TITLE = 3'd2,
                     CLS_BODY = 3'd3, CLS_HLBAR = 3'd4, CLS_STRIPE = 3'd5,
                     CLS_DIVIDER = 3'd6;
    reg [2:0] cls_p2;
    reg [1:0] kind_p2;           // 0 none, 1 label, 2 value, 3 title
    reg [2:0] slot_p2;
    reg [2:0] gcol_p2;
    reg [3:0] grow_p2;
    reg hl_p2;
    wire in_panel = in_px_p1 && in_py_q;
    wire [9:0] lx = xr_p1 - LBL_X;
    wire [9:0] vx = xr_p1 - VAL_X;
    wire [9:0] tx = xr_p1 - TITLE_X;
    wire [8:0] row_text_y = {4'b0, row_y_q} - 9'd6;
    wire [8:0] title_text_y = py_q - 9'd6;
    wire row_hl = (row_q == hl_row) && (row_q != 3'd7);
    always @(posedge clk) begin
        cls_p2 <= CLS_NONE;
        kind_p2 <= 2'd0;
        slot_p2 <= 3'd0;
        gcol_p2 <= 3'd0;
        grow_p2 <= 4'd0;
        hl_p2 <= row_hl;
        if (in_panel) begin
            if (xr_p1 < 10'd2 || xr_p1 >= PW - 2 || py_q < 9'd2 || py_q >= PH - 2)
                cls_p2 <= CLS_BORDER;
            else if (!body_q)
                cls_p2 <= CLS_TITLE;
            else if (py_q == TITLE_H)
                cls_p2 <= CLS_DIVIDER;
            else if (row_hl && row_y_q >= 5'd1 && row_y_q < 5'd27 &&
                     xr_p1 >= 10'd8 && xr_p1 < PW - 8)
                cls_p2 <= (xr_p1 < 10'd12) ? CLS_STRIPE : CLS_HLBAR;
            else
                cls_p2 <= CLS_BODY;

            if (!body_q) begin
                // Title text is drawn at 2x.
                if (tx < 10'd64 && py_q >= 9'd6 && py_q < 9'd38) begin
                    kind_p2 <= 2'd3;
                    slot_p2 <= {1'b0, tx[5:4]};
                    gcol_p2 <= tx[3:1];
                    grow_p2 <= title_text_y[4:1];
                end
            end else if (row_q != 3'd7 && row_y_q >= 5'd6 && row_y_q < 5'd22) begin
                if (lx < 10'd64) begin
                    kind_p2 <= 2'd1;
                    slot_p2 <= lx[5:3];
                    gcol_p2 <= lx[2:0];
                    grow_p2 <= row_text_y[3:0];
                end else if (vx < 10'd64) begin
                    kind_p2 <= 2'd2;
                    slot_p2 <= vx[5:3];
                    gcol_p2 <= vx[2:0];
                    grow_p2 <= row_text_y[3:0];
                end
            end
        end
    end

    // Text strings for the current row. They only change with the row (once
    // per line) or with a parameter, so they are registered in two quasi-static
    // stages ahead of the pixel pipeline: codes first, then the string vectors.
    reg [2:0] vol_r, bri_r;
    reg [1:0] per_r;
    reg auto_r, music_r;
    reg [1:0] idx_r;
    always @(posedge clk) begin
        vol_r <= vol_code;
        bri_r <= {1'b0, bri_code};
        per_r <= period_code;
        auto_r <= auto_enabled;
        music_r <= music_on;
        idx_r <= active_index;
    end

    reg [55:0] label_vec;
    always @(posedge clk) begin
        case (row_q)
@LABEL_CASES@
            default: label_vec <= 56'd0;
        endcase
    end
    wire [6:0] cur_digit = @H_DIGIT0@ + 7'd1 + {5'd0, idx_r};
    reg [55:0] vol_vec, bri_vec, auto_vec, per_vec, music_vec;
    always @(posedge clk) begin
        vol_vec <= @VOL_EXPR@;
        bri_vec <= @BRI_EXPR@;
        auto_vec <= @AUTO_EXPR@;
        per_vec <= @PER_EXPR@;
        music_vec <= @MUSIC_EXPR@;
    end
    reg [55:0] value_vec;
    always @(posedge clk) begin
        case (row_q)
            3'd0: value_vec <= {7'd@H_FOUR@, 7'd0, 7'd@H_SLASH@, 7'd0, cur_digit, 7'd0, 7'd0, 7'd0};
            3'd1: value_vec <= vol_vec;
            3'd2: value_vec <= bri_vec;
            3'd3: value_vec <= auto_vec;
            3'd4: value_vec <= per_vec;
            3'd5: value_vec <= @TRANS_VEC@;
            default: value_vec <= music_vec;
        endcase
    end

    // P3: pick the half glyph for the slot.
    wire [55:0] pick_vec = (kind_p2 == 2'd3) ? @TITLE_VEC@ :
                           (kind_p2 == 2'd2) ? value_vec : label_vec;
    reg [6:0] half_p3;
    reg [2:0] cls_p3;
    reg [1:0] kind_p3;
    reg [2:0] gcol_p3;
    reg [3:0] grow_p3;
    reg hl_p3;
    always @(posedge clk) begin
        half_p3 <= (kind_p2 == 2'd0) ? 7'd0 : pick_vec[slot_p2 * 7 +: 7];
        cls_p3 <= cls_p2;
        kind_p3 <= kind_p2;
        gcol_p3 <= gcol_p2;
        grow_p3 <= grow_p2;
        hl_p3 <= hl_p2;
    end

    // P4: font ROM read.
    reg [7:0] glyph_p4;
    reg [2:0] cls_p4;
    reg [1:0] kind_p4;
    reg [2:0] gcol_p4;
    reg hl_p4;
    always @(posedge clk) begin
        glyph_p4 <= font_rom[{half_p3, grow_p3}];
        cls_p4 <= cls_p3;
        kind_p4 <= kind_p3;
        gcol_p4 <= gcol_p3;
        hl_p4 <= hl_p3;
    end

    // P5: resolve the colour. mode 0 = pass through, 1 = solid, 2 = dim the
    // picture to a quarter and add the colour (panel body stays translucent).
    localparam [23:0] COL_GOLD = 24'hC9A24D;
    reg [1:0] mode_p5;
    reg [23:0] col_p5;
    wire text_bit = (kind_p4 != 2'd0) && glyph_p4[~gcol_p4];
    wire show = panel_visible && !suppress;
    always @(posedge clk) begin
        mode_p5 <= 2'd0;
        col_p5 <= 24'd0;
        if (show && cls_p4 != CLS_NONE) begin
            mode_p5 <= 2'd1;
            if (text_bit) begin
                if (kind_p4 == 2'd3)
                    col_p5 <= 24'hF0C060;
                else if (kind_p4 == 2'd2 && hl_p4)
                    col_p5 <= 24'hF2C25A;
                else if (kind_p4 == 2'd2)
                    col_p5 <= 24'hFFFFFF;
                else
                    col_p5 <= 24'hE2DDD6;
            end else begin
                case (cls_p4)
                    CLS_BORDER:  col_p5 <= COL_GOLD;
                    CLS_DIVIDER: col_p5 <= COL_GOLD;
                    CLS_STRIPE:  col_p5 <= 24'hE0B04A;
                    CLS_HLBAR:   col_p5 <= 24'h6B1B22;
                    CLS_TITLE: begin
                        mode_p5 <= 2'd2;
                        col_p5 <= 24'h2A1618;
                    end
                    default: begin
                        mode_p5 <= 2'd2;
                        col_p5 <= 24'h121216;
                    end
                endcase
            end
        end
    end

    wire [23:0] dimmed = {2'b00, rgb_in[23:18], 2'b00, rgb_in[15:10], 2'b00, rgb_in[7:2]};
    wire [23:0] blended = {dimmed[23:16] + col_p5[23:16],
                           dimmed[15:8] + col_p5[15:8],
                           dimmed[7:0] + col_p5[7:0]};
    assign rgb_out = (mode_p5 == 2'd1) ? col_p5 :
                     (mode_p5 == 2'd2) ? blended : rgb_in;
endmodule
"""

if __name__ == "__main__":
    main()

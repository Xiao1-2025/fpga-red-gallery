`timescale 1ns/1ps

// Resize during loading: one output-width accumulator line, no source frame.
// Downscaling averages every source pixel in each integer rectangular bin.
// Magnification retains the nearest-neighbour path. BOX_FILTER=0 is baseline.
// The byte FIFO absorbs an entire in-flight sector; file_pause stops NEW
// data-sector requests. Input must observe pause before issuing each sector.
module bmp24_fit_decoder #(
    parameter integer OUTPUT_WIDTH = 640,
    parameter integer OUTPUT_HEIGHT = 480,
    parameter integer BOX_FILTER = 1
) (
    input wire clk, rst_n, file_start,
    input wire [31:0] file_size,
    input wire file_valid,
    input wire [7:0] file_byte,
    input wire file_end,
    input wire [7:0] upstream_error,
    output wire file_pause,
    input wire pixel_ready,
    output reg pixel_valid,
    output reg [23:0] pixel_rgb,
    output wire top_down,
    output reg frame_commit,
    output wire [7:0] bmp_error
);
    localparam HEADER=0, GEOMETRY=1, PREPARE=2, RECEIVE=3,
               FILL=4, ROW_DONE=5, OUT_READ=6, OUT_SEND=7,
               DRAIN=8, FINISHED=9, AREA_READ=10, AREA_WRITE=11,
               AREA_DIV_SETUP=12, AREA_DIV_ROUND=13, AREA_DIV=14;
    reg [3:0] state;
    (* ram_style = "bram" *) reg [7:0] byte_mem [0:1023];
    reg [9:0] wr_ptr, rd_ptr;
    reg [10:0] byte_count;
    reg raw_valid;
    reg [7:0] raw_byte;
    reg [31:0] raw_offset, read_offset;
    reg end_pending, end_sent, raw_end;
    reg overflow;
    wire header_accepted, source_valid, source_commit;
    wire [23:0] source_rgb;
    wire [15:0] source_x, source_width, source_height;
    wire [7:0] decode_error;
    reg commit_seen;
    wire byte_pop = byte_count != 0 && !source_valid &&
                    (state == HEADER || state == RECEIVE || state == DRAIN);
    assign file_pause = byte_count >= 256;
    assign bmp_error = overflow ? 8'h39 : decode_error;

    bmp24_decoder #(.ALLOW_VARIABLE_SIZE(1)) u_decode (
        .clk(clk), .rst_n(rst_n), .file_start(file_start), .file_size(file_size),
        .file_valid(raw_valid), .file_byte(raw_byte), .file_byte_offset(raw_offset),
        .file_end(raw_end), .upstream_error(upstream_error),
        .header_accepted(header_accepted), .pixel_valid(source_valid),
        .pixel_rgb(source_rgb), .pixel_x(source_x), .pixel_y(),
        .frame_commit(source_commit), .bmp_done(), .bmp_error(decode_error),
        .top_down(top_down), .pixel_offset(), .row_stride(),
        .image_width(source_width), .image_height(source_height)
    );

    // Registered read permits block RAM inference. At most one extra B byte
    // reaches the decoder after an RGB pixel; it cannot emit another pixel.
    always @(posedge clk) begin
        if (file_valid && byte_count < 1024)
            byte_mem[wr_ptr] <= file_byte;
        if (byte_pop)
            raw_byte <= byte_mem[rd_ptr];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr<=0; rd_ptr<=0; byte_count<=0; raw_valid<=0;
            raw_offset<=0; read_offset<=0; end_pending<=0;
            end_sent<=0; raw_end<=0; overflow<=0;
        end else if (file_start) begin
            wr_ptr<=0; rd_ptr<=0; byte_count<=0; raw_valid<=0;
            raw_offset<=0; read_offset<=0; end_pending<=0;
            end_sent<=0; raw_end<=0; overflow<=0;
        end else begin
            raw_valid <= byte_pop;
            raw_end <= 0;
            if (file_end) end_pending <= 1;
            if (file_valid) begin
                wr_ptr <= wr_ptr + 1'b1;
                if (byte_count == 1024) overflow <= 1;
            end
            if (byte_pop) begin
                rd_ptr <= rd_ptr + 1'b1;
                raw_offset <= read_offset;
                read_offset <= read_offset + 1'b1;
            end
            case ({file_valid,byte_pop})
                2'b10: byte_count <= byte_count + 1'b1;
                2'b01: byte_count <= byte_count - 1'b1;
                default: ;
            endcase
            if (end_pending && !end_sent && byte_count == 0 &&
                !raw_valid && !source_valid && (state == HEADER || state == RECEIVE || state == DRAIN ||
                                              decode_error != 0)) begin
                raw_end <= 1;
                end_sent <= 1;
            end
        end
    end

    localparam LINE_ADDR_WIDTH = OUTPUT_WIDTH <= 1 ? 1 : $clog2(OUTPUT_WIDTH);
    (* ram_style = "bram" *) reg [23:0] line_mem [0:(1<<LINE_ADDR_WIDTH)-1];
    reg [23:0] line_q, held_rgb;
    reg [15:0] fit_width, fit_height, pad_x, lead_rows;
    reg [15:0] target_x, output_x, output_rows, interior_rows;
    reg [31:0] sample_x, threshold_x, sample_y, threshold_y;
    reg [31:0] numerator;
    reg [15:0] divisor, quotient;
    reg width_limited, last_pixel, row_black, trailing;
    reg area_mode;
    reg [12:0] h_phase, v_phase, h_count, v_count, group_rows;
    reg [19:0] h_red, h_green, h_blue;
    // Full-precision sums: 4096*4096*255 fits in an unsigned 32-bit value.
    // Store horizontal sample count beside each column to normalize only once.
    (* ram_style = "bram" *) reg [108:0] area_mem [0:(1<<LINE_ADDR_WIDTH)-1];
    reg [108:0] area_q;
    wire [15:0] line_read_x = output_x >= pad_x && output_x < pad_x+fit_width ?
                              output_x-pad_x : 16'd0;
    wire area_write = state == AREA_WRITE;
    wire [LINE_ADDR_WIDTH-1:0] area_addr =
        state == AREA_READ || area_write ? target_x[LINE_ADDR_WIDTH-1:0] :
                                         line_read_x[LINE_ADDR_WIDTH-1:0];
    wire [31:0] area_red = (v_count == 0 ? 32'd0 : area_q[95:64]) + h_red;
    wire [31:0] area_green = (v_count == 0 ? 32'd0 : area_q[63:32]) + h_green;
    wire [31:0] area_blue = (v_count == 0 ? 32'd0 : area_q[31:0]) + h_blue;
    always @(posedge clk) begin
        if (area_write) area_mem[area_addr] <= {h_count,area_red,area_green,area_blue};
        area_q <= area_mem[area_addr];
    end

    // Three parallel restoring dividers share the bin's sample count. Fixed
    // 32-cycle division avoids large combinational / operators and extra DSPs.
    reg [25:0] area_divisor, rem_red, rem_green, rem_blue;
    reg [31:0] div_red, div_green, div_blue;
    reg [5:0] div_step;
    wire [26:0] trial_red = {rem_red,div_red[31]};
    wire [26:0] trial_green = {rem_green,div_green[31]};
    wire [26:0] trial_blue = {rem_blue,div_blue[31]};
    wire line_write = state == FILL && target_x < fit_width && sample_x < threshold_x;
    wire [LINE_ADDR_WIDTH-1:0] line_addr = line_write ?
        target_x[LINE_ADDR_WIDTH-1:0] : line_read_x[LINE_ADDR_WIDTH-1:0];
    always @(posedge clk) begin
        if (line_write) line_mem[line_addr] <= held_rgb;
        line_q <= line_mem[line_addr];
    end

    // Geometry division is repeated subtraction, <= max(W,H) iterations,
    // once per image. No variable divider or per-pixel multiplier is needed.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=HEADER; pixel_valid<=0; pixel_rgb<=0; frame_commit<=0;
            fit_width<=0; fit_height<=0; pad_x<=0; lead_rows<=0;
            target_x<=0; output_x<=0; output_rows<=0; interior_rows<=0;
            sample_x<=0; threshold_x<=0; sample_y<=0; threshold_y<=0;
            numerator<=0; divisor<=0; quotient<=0; width_limited<=0;
            held_rgb<=0; last_pixel<=0; row_black<=0; trailing<=0;
            commit_seen<=0;
            area_mode<=0; h_phase<=0; v_phase<=0; h_count<=0; v_count<=0;
            group_rows<=0; h_red<=0; h_green<=0; h_blue<=0;
            area_divisor<=0; rem_red<=0; rem_green<=0; rem_blue<=0;
            div_red<=0; div_green<=0; div_blue<=0; div_step<=0;
        end else if (file_start) begin
            state<=HEADER; pixel_valid<=0; frame_commit<=0; commit_seen<=0;
            output_rows<=0; interior_rows<=0; target_x<=0; output_x<=0;
            sample_x<=0; trailing<=0;
        end else begin
            pixel_valid <= 0;
            frame_commit <= 0;
            if (source_commit) commit_seen <= 1;
            case (state)
                HEADER: if (header_accepted) begin
                    width_limited <= (source_width * OUTPUT_HEIGHT >= source_height * OUTPUT_WIDTH);
                    if (source_width * OUTPUT_HEIGHT >= source_height * OUTPUT_WIDTH) begin
                        fit_width <= OUTPUT_WIDTH;
                        numerator <= source_height * OUTPUT_WIDTH;
                        divisor <= source_width;
                    end else begin
                        fit_height <= OUTPUT_HEIGHT;
                        numerator <= source_width * OUTPUT_HEIGHT;
                        divisor <= source_height;
                    end
                    quotient <= 0;
                    state <= GEOMETRY;
                end
                GEOMETRY: if (numerator >= divisor) begin
                    numerator <= numerator - divisor;
                    quotient <= quotient + 1'b1;
                end else begin
                    if (width_limited) fit_height <= quotient == 0 ? 16'd1 : quotient;
                    else fit_width <= quotient == 0 ? 16'd1 : quotient;
                    state <= PREPARE;
                end
                PREPARE: begin
                    pad_x <= (OUTPUT_WIDTH-fit_width)/2;
                    // For bottom-up files, emit the display's bottom border first.
                    lead_rows <= top_down ? (OUTPUT_HEIGHT-fit_height)/2 :
                                           OUTPUT_HEIGHT-fit_height-(OUTPUT_HEIGHT-fit_height)/2;
                    sample_y <= top_down ? 32'd0 : {16'd0,source_height}-1'b1;
                    threshold_y <= fit_height;
                    sample_x <= 0; threshold_x <= 0; target_x <= 0;
                    area_mode <= BOX_FILTER &&
                                 (source_width > fit_width || source_height > fit_height);
                    h_phase<=0; h_count<=0; v_count<=0;
                    h_red<=0; h_green<=0; h_blue<=0;
                    // Reverse the vertical bin partition for bottom-up BMPs,
                    // so both file orientations produce identical display data.
                    v_phase <= top_down ? 13'd0 : fit_height-1'b1;
                    row_black <= 1;
                    state <= (top_down ? (OUTPUT_HEIGHT-fit_height)/2 :
                              OUTPUT_HEIGHT-fit_height-(OUTPUT_HEIGHT-fit_height)/2) == 0 ?
                             RECEIVE : OUT_READ;
                end
                RECEIVE: if (source_valid) begin
                    held_rgb <= source_rgb;
                    last_pixel <= source_x == source_width-1'b1;
                    if (area_mode) begin
                        h_red <= h_red + source_rgb[23:16];
                        h_green <= h_green + source_rgb[15:8];
                        h_blue <= h_blue + source_rgb[7:0];
                        h_count <= h_count + 1'b1;
                        if ({1'b0,h_phase}+fit_width >= source_width) begin
                            h_phase <= h_phase + fit_width - source_width;
                            state <= AREA_READ;
                        end else h_phase <= h_phase + fit_width;
                    end else begin
                        threshold_x <= threshold_x + fit_width;
                        state <= FILL;
                    end
                end
                AREA_READ: state <= AREA_WRITE;
                AREA_WRITE: begin
                    h_red<=0; h_green<=0; h_blue<=0; h_count<=0;
                    target_x <= target_x + 1'b1;
                    state <= RECEIVE;
                    if (last_pixel) begin
                        target_x <= 0;
                        if ({1'b0,v_phase}+fit_height >= source_height) begin
                            v_phase <= v_phase + fit_height - source_height;
                            group_rows <= v_count + 1'b1;
                            // Keep v_count until output completes: it controls
                            // the RAM add above on this last source row.
                            output_x <= 0; row_black <= 0; state <= OUT_READ;
                        end else begin
                            v_phase <= v_phase + fit_height;
                            v_count <= v_count + 1'b1;
                        end
                    end
                end
                FILL: if (line_write) begin
                    target_x <= target_x + 1'b1;
                    sample_x <= sample_x + source_width;
                end else if (last_pixel) begin
                    state <= ROW_DONE;
                end else state <= RECEIVE;
                ROW_DONE: if (sample_y < threshold_y && interior_rows < fit_height) begin
                    row_black <= 0; output_x <= 0; state <= OUT_READ;
                end else begin
                    sample_x <= 0; threshold_x <= 0; target_x <= 0;
                    threshold_y <= threshold_y + fit_height;
                    state <= RECEIVE;
                end
                OUT_READ: state <= area_mode && !row_black &&
                                   output_x >= pad_x && output_x < pad_x+fit_width ?
                                   AREA_DIV_SETUP : OUT_SEND;
                AREA_DIV_SETUP: begin
                    area_divisor <= area_q[108:96] * group_rows;
                    state <= AREA_DIV_ROUND;
                end
                AREA_DIV_ROUND: begin
                    div_red <= area_q[95:64] + (area_divisor >> 1);
                    div_green <= area_q[63:32] + (area_divisor >> 1);
                    div_blue <= area_q[31:0] + (area_divisor >> 1);
                    rem_red<=0; rem_green<=0; rem_blue<=0; div_step<=0;
                    state <= AREA_DIV;
                end
                AREA_DIV: begin
                    if (trial_red >= {1'b0,area_divisor}) begin
                        rem_red <= trial_red - area_divisor;
                        div_red <= {div_red[30:0],1'b1};
                    end else begin
                        rem_red <= trial_red[25:0]; div_red <= {div_red[30:0],1'b0};
                    end
                    if (trial_green >= {1'b0,area_divisor}) begin
                        rem_green <= trial_green - area_divisor;
                        div_green <= {div_green[30:0],1'b1};
                    end else begin
                        rem_green <= trial_green[25:0]; div_green <= {div_green[30:0],1'b0};
                    end
                    if (trial_blue >= {1'b0,area_divisor}) begin
                        rem_blue <= trial_blue - area_divisor;
                        div_blue <= {div_blue[30:0],1'b1};
                    end else begin
                        rem_blue <= trial_blue[25:0]; div_blue <= {div_blue[30:0],1'b0};
                    end
                    div_step <= div_step + 1'b1;
                    if (div_step == 31) state <= OUT_SEND;
                end
                OUT_SEND: if (pixel_ready) begin
                    pixel_valid <= 1;
                    pixel_rgb <= row_black || output_x < pad_x || output_x >= pad_x+fit_width ?
                                 24'd0 : area_mode ?
                                 {div_red[7:0],div_green[7:0],div_blue[7:0]} : line_q;
                    if (output_x == OUTPUT_WIDTH-1) begin
                        output_x <= 0;
                        output_rows <= output_rows + 1'b1;
                        if (row_black) begin
                            if (output_rows+1 >= OUTPUT_HEIGHT) state <= DRAIN;
                            else if (!trailing && output_rows+1 >= lead_rows) state <= RECEIVE;
                            else state <= OUT_READ;
                        end else begin
                            interior_rows <= interior_rows + 1'b1;
                            sample_y <= sample_y + source_height;
                            if (interior_rows+1 == fit_height) begin
                                if (output_rows+1 == OUTPUT_HEIGHT) state <= DRAIN;
                                else begin
                                    row_black <= 1; trailing <= 1; state <= OUT_READ;
                                end
                            end else if (area_mode) begin
                                v_count <= 0;
                                state <= RECEIVE;
                            end else if (sample_y + source_height < threshold_y) state <= OUT_READ;
                            else begin
                                sample_x <= 0; threshold_x <= 0; target_x <= 0;
                                threshold_y <= threshold_y + fit_height;
                                state <= RECEIVE;
                            end
                        end
                    end else begin
                        output_x <= output_x + 1'b1;
                        state <= OUT_READ;
                    end
                end
                DRAIN: if (commit_seen) begin
                    frame_commit <= 1;
                    state <= FINISHED;
                end
                default: ;
            endcase
        end
    end
endmodule

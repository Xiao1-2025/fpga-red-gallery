create_clock -name sys_clk -period 20.000 -waveform {0.000 10.000} [get_ports {sys_clk}]
create_generated_clock -name pixel_clk_5x -source [get_ports {sys_clk}] -master_clock sys_clk -multiply_by 2.5 [get_nets {pixel_clk_5x}]
create_generated_clock -name pixel_clk -source [get_ports {sys_clk}] -master_clock sys_clk -divide_by 2 [get_nets {pixel_clk}]
create_generated_clock -name mem_clk -source [get_ports {sys_clk}] -master_clock sys_clk -divide_by 1.25 -phase 0 [get_pins {u_mem_pll/pll_inst.clkc[1]}]
create_generated_clock -name mem_clk_shift -source [get_ports {sys_clk}] -master_clock sys_clk -divide_by 1.25 -phase 172.8 [get_pins {u_mem_pll/pll_inst.clkc[2]}]

set_false_path -from [get_ports {sys_rst_n}]
set_false_path -to [get_regs -hier {*/s1}]
set_false_path -to [get_regs -hier {*/request_sync1_mem}]
set_false_path -to [get_regs -hier {*/index_sync1_mem[*]}]
set_false_path -to [get_regs -hier {*/ack_sync1}]
set_false_path -to [get_regs -hier {*/req_sync1}]
set_false_path -to [get_regs -hier {*/index_sync1[*]}]
set_false_path -to [get_regs -hier {*busy_sync1}]
set_false_path -to [get_regs -hier {*commit_sync1}]
# Read-FIFO write-side reset synchroniser (inherited FIFO IP): both stages are
# set asynchronously by the pixel-domain reset and release through two flops in
# mem_clk. A release that lands next to a mem_clk edge can only leave a stage at
# or moving to its reset value (1), so recovery on these two flops is benign.
set_false_path -to [get_regs -hier {u_video/u_reader/u_read_fifo/asy_w_rst0}]
set_false_path -to [get_regs -hier {u_video/u_reader/u_read_fifo/asy_w_rst1}]
# Read side: same structure, and its reset request also contains mem_clk-domain
# terms (fifo_reset_count_mem), so it is a cross-domain release as well.
set_false_path -to [get_regs -hier {u_video/u_reader/u_read_fifo/asy_r_rst0}]
set_false_path -to [get_regs -hier {u_video/u_reader/u_read_fifo/asy_r_rst1}]

# Frame-reader reset-release synchronisers (local logic, see media_frame_reader):
# {x[0], 1'b1} shift registers set asynchronously by the combined reset request
# and released through two flops of their own clock. Same argument as above.
set_false_path -to [get_regs -hier {u_video/u_reader/fifo_release_mem[*]}]
set_false_path -to [get_regs -hier {u_video/u_reader/fifo_release_pix[*]}]

# Static error codes (reader and control faults) are sampled by two flops in the
# pixel domain. Only "non-zero" is used, so bit-to-bit skew is irrelevant.
set_false_path -to [get_regs -hier {*reader_error_pix1[*]}]
set_false_path -to [get_regs -hier {*control_error_pix1[*]}]
set_false_path -to [get_regs -hier {u_hdmi_audio_phy/symbols_sync1[*]}]
set_false_path -to [get_regs -hier {u_hdmi_audio_phy/toggle_sync1}]

# The inherited FIFO uses Gray pointers. Limit each crossing to one source
# clock period instead of declaring the complete pixel/memory domains false.
set_max_delay -from [get_regs -hier {u_video/u_reader/u_read_fifo/wr_to_rd_cross_inst/primary_addr_gray_reg[*]}] -to [get_regs -hier {u_video/u_reader/u_read_fifo/wr_to_rd_cross_inst/sync_r1[*]}] 25.000 -datapath_only
set_max_delay -from [get_regs -hier {u_video/u_reader/u_read_fifo/rd_to_wr_cross_inst/primary_addr_gray_reg[*]}] -to [get_regs -hier {u_video/u_reader/u_read_fifo/rd_to_wr_cross_inst/sync_r1[*]}] 40.000 -datapath_only

# Bound each implemented ODDR-to-pad path. This is a digital per-lane delay
# limit, not a claim about complete rise/fall pairwise skew or the analog eye.
set_max_delay -from [get_clocks {pixel_clk_5x}] \
    -to [get_ports {HDMI_CLK_P HDMI_D0_P HDMI_D1_P HDMI_D2_P}] \
    8.000 -datapath_only

# MUSIC.WAV FIFO: Gray-coded pointers cross between mem_clk (write) and the
# audio/pixel clock (read). Same budget style as the frame FIFO above: one
# source clock period per crossing, data path only.
set_max_delay -from [get_regs -hier {*u_wav_fifo/wr_gray_reg[*]}] -to [get_regs -hier {*u_wav_fifo/wr_gray_s1[*]}] 25.000 -datapath_only
set_max_delay -from [get_regs -hier {*u_wav_fifo/rd_gray_reg[*]}] -to [get_regs -hier {*u_wav_fifo/rd_gray_s1[*]}] 40.000 -datapath_only

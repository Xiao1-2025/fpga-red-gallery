`timescale 1ns/1ps

// Excellence top: everything in the final competition candidate plus the
// KEY4 parameter menu (short press = volume ladder, one-second hold =
// slideshow period ladder) and the UART status reporter (boot banner, per
// switch lines, parameter changes, error codes) on the board USB-UART.
module media_player_excellence_top (
    input  wire       sys_clk,
    input  wire       sys_rst_n,
    input  wire       key2_n,
    input  wire       key3_n,
    input  wire       key4_n,
    // SW4 toggle switch: audio play/pause. SW4_PLAY_LEVEL is the pin level
    // that means "play" (pin has a pull-up, so an open switch reads high).
    input  wire       sw4,
    output wire       uart_tx_o,
    output wire       sd_cs_n,
    output wire       sd_sclk,
    output wire       sd_mosi,
    input  wire       sd_miso,
    input  wire       flash_miso,
    output wire       flash_cs_n,
    output wire       flash_sclk,
    output wire       flash_mosi,
    output wire       flash_wp_n,
    output wire       flash_hold_n,
    output wire       HDMI_CLK_P,
    output wire       HDMI_D2_P,
    output wire       HDMI_D1_P,
    output wire       HDMI_D0_P,
    output wire [3:0] led
);
    wire mem_feedback_clk;
    wire mem_clk;
    wire mem_clk_shift;
    wire mem_locked;
    sys_pll u_mem_pll (
        .refclk(sys_clk), .reset(~sys_rst_n),
        .clk0_out(mem_feedback_clk), .clk1_out(mem_clk),
        .clk2_out(mem_clk_shift), .locked(mem_locked)
    );

    wire pixel_clk_5x;
    wire pixel_clk;
    wire video_locked;
    clk_wize u_video_pll (
        .refclk(sys_clk), .reset(~sys_rst_n),
        .clk0_out(pixel_clk_5x), .clk1_out(pixel_clk),
        .locked(video_locked)
    );

    wire mem_rst_n;
    wire pix_rst_n;
    wire pix_5x_rst_n;
    wire ctrl_rst_n;
    reset_sync u_mem_reset (
        .clk(mem_clk), .ext_rst_n(sys_rst_n & mem_locked),
        .rst_n_sync(mem_rst_n)
    );
    reset_sync u_pix_reset (
        .clk(pixel_clk), .ext_rst_n(sys_rst_n & video_locked),
        .rst_n_sync(pix_rst_n)
    );
    reset_sync u_pix_5x_reset (
        .clk(pixel_clk_5x), .ext_rst_n(sys_rst_n & video_locked),
        .rst_n_sync(pix_5x_rst_n)
    );
    reset_sync u_ctrl_reset (
        .clk(sys_clk), .ext_rst_n(sys_rst_n & video_locked),
        .rst_n_sync(ctrl_rst_n)
    );

    wire sdram_init_done;
    wire sdram_refresh_active;
    wire sdram_busy;
    wire ingest_app_wr_en;
    wire [20:0] ingest_app_wr_addr;
    wire [3:0] ingest_app_wr_mask;
    wire [31:0] ingest_app_wr_data;
    wire player_app_rd_en;
    wire [20:0] player_app_rd_addr;
    wire sdram_rd_valid;
    wire [31:0] sdram_rd_data;

    sdram u_sdram (
        .Clk(mem_clk), .Clk_sft(mem_clk_shift), .Rst(~mem_rst_n),
        .Sdr_init_done(sdram_init_done),
        .Sdr_init_ref_vld(sdram_refresh_active), .Sdr_busy(sdram_busy),
        .App_wr_en(ingest_app_wr_en), .App_wr_addr(ingest_app_wr_addr),
        .App_wr_dm(ingest_app_wr_mask), .App_wr_din(ingest_app_wr_data),
        .App_rd_en(player_app_rd_en), .App_rd_addr(player_app_rd_addr),
        .Sdr_rd_en(sdram_rd_valid), .Sdr_rd_dout(sdram_rd_data)
    );

    reg ingest_start;
    reg ingest_started;
    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            ingest_start <= 1'b0;
            ingest_started <= 1'b0;
        end else begin
            ingest_start <= 1'b0;
            if (sdram_init_done && !ingest_started) begin
                ingest_start <= 1'b1;
                ingest_started <= 1'b1;
            end
        end
    end

    wire ingest_busy;
    wire ingest_done;
    wire ingest_attempt;
    wire [2:0] ingest_error_stage;
    wire [7:0] ingest_error_code;
    wire [7:0] ingest_error_detail;
    wire card_ready;
    wire card_high_capacity;
    wire [3:0] resource_valid;
    wire [3:0] image_complete;
    wire title_complete;
    // MUSIC.WAV directory entry, and the ingest file streamer that the music
    // player borrows once the one-shot image ingest has finished.
    wire music_valid;
    wire [31:0] music_cluster;
    wire [31:0] music_size;
    wire music_file_sel;
    wire music_file_start;
    wire music_file_pause;
    wire music_file_valid;
    wire [7:0] music_file_byte;
    wire music_file_done;
    wire [7:0] music_file_error;
    // RETRY_CYCLES = 40e6 mem_clk cycles = 1 s: with no card, or a card that
    // fails to read, the whole sequence is tried again every second, so a TF
    // card inserted after power-up is picked up automatically.
    media_storage_ingest_top #(.LOAD_TITLE(1), .RETRY_CYCLES(40000000)) u_storage_ingest (
        .clk(mem_clk), .rst_n(mem_rst_n), .start(ingest_start),
        .busy(ingest_busy), .done(ingest_done), .attempt_start(ingest_attempt),
        .error_stage(ingest_error_stage), .error_code(ingest_error_code),
        .error_detail(ingest_error_detail), .card_ready(card_ready),
        .card_high_capacity(card_high_capacity),
        .resource_valid(resource_valid), .image_complete(image_complete),
        .title_complete(title_complete),
        .music_valid(music_valid), .music_cluster(music_cluster),
        .music_size(music_size),
        .audio_file_sel(music_file_sel), .audio_file_start(music_file_start),
        .audio_file_pause(music_file_pause), .audio_file_valid(music_file_valid),
        .audio_file_byte(music_file_byte), .audio_file_done(music_file_done),
        .audio_file_error(music_file_error),
        .controller_init_done(sdram_init_done),
        .controller_busy(sdram_busy), .refresh_active(sdram_refresh_active),
        .app_wr_en(ingest_app_wr_en), .app_wr_addr(ingest_app_wr_addr),
        .app_wr_mask(ingest_app_wr_mask), .app_wr_data(ingest_app_wr_data),
        .sd_cs_n(sd_cs_n), .sd_sclk(sd_sclk),
        .sd_mosi(sd_mosi), .sd_miso(sd_miso)
    );

    // Storage owns writes until all five frames commit. Playback then owns
    // only the read port; the two stages never issue commands concurrently.
    reg player_enable_mem;
    wire storage_error_mem;
    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            player_enable_mem <= 1'b0;
        end else if (ingest_done) begin
            if (ingest_error_stage == 0 && ingest_error_code == 0 &&
                image_complete == 4'hf && title_complete)
                player_enable_mem <= 1'b1;
        end
    end

    wire key2_press;
    wire key3_press;
    wire config_save_event;
    wire config_save_locked;
    wire config_ready;
    wire config_busy;
    wire config_load_done;
    wire config_save_done;
    wire config_apply_valid;
    wire config_rejected;
    wire config_fatal_error;
    wire [7:0] config_error_code;
    wire config_request_dropped;
    wire stored_config_valid;
    wire [31:0] stored_config_version;
    wire [31:0] config_period_ms;
    wire [31:0] config_period_cycles;
    wire [7:0] config_volume;
    wire [7:0] config_mode;
    wire [23:0] config_jedec_id;
    wire [7:0] config_status1, config_status2, config_status3;
    wire auto_enabled;

    // Human-operated chord contract: a single key acts on release; while the
    // first key remains held, the second key may join and start a 2 s save hold.
    wire key3_long_press;

    dual_key_chord_router #(
        .DEBOUNCE_CYCLES(1000000),
        .HOLD_CYCLES(100000000),
        .KEY3_LONG_CYCLES(50000000)
    ) u_key_router (
        .clk(sys_clk), .rst_n(ctrl_rst_n), .save_enabled(config_ready),
        .key2_n(key2_n), .key3_n(key3_n), .key2_event(key2_press),
        .key3_event(key3_press), .key3_long_event(key3_long_press),
        .save_event(config_save_event),
        .save_locked(config_save_locked), .key2_stable_n(),
        .key3_stable_n()
    );

    // Session-level brightness ladder: KEY3 held alone for one second and
    // released steps 100/75/50/25%% and back to 100%%. Not persisted, so the
    // Flash configuration record layout stays unchanged.
    reg [1:0] brightness_level;
    always @(posedge sys_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n)
            brightness_level <= 2'd0;
        else if (key3_long_press && config_ready)
            brightness_level <= brightness_level + 1'b1;
    end
    reg [7:0] brightness_sys;
    always @* begin
        case (brightness_level)
            2'd0: brightness_sys = 8'd255;
            2'd1: brightness_sys = 8'd192;
            2'd2: brightness_sys = 8'd128;
            default: brightness_sys = 8'd64;
        endcase
    end

    // KEY4 parameter menu: short press steps the volume ladder, a one
    // second hold steps the slideshow period ladder. The persistence service
    // samples the new value immediately; the dual-key chord still controls
    // the Flash write.
    wire menu_cfg_valid;
    wire [31:0] menu_cfg_period;
    wire [7:0] menu_cfg_volume;
    wire menu_evt;
    wire [1:0] menu_kind;

    param_menu_controller #(
        .CLKS_PER_MS(50000)
    ) u_param_menu (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .key4_n(key4_n), .service_ready(config_ready),
        .live_volume(config_volume), .live_period_ms(config_period_ms),
        .cfg_update_valid(menu_cfg_valid),
        .cfg_period_ms(menu_cfg_period), .cfg_volume(menu_cfg_volume),
        .menu_event(menu_evt), .menu_kind(menu_kind), .menu_level()
    );

    player_config_persistence u_player_config (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .cfg_update_valid((key3_press || menu_cfg_valid) && config_ready),
        .cfg_period_ms(menu_cfg_valid ? menu_cfg_period : config_period_ms),
        .cfg_volume(menu_cfg_valid ? menu_cfg_volume : config_volume),
        // KEY3 toggles the slideshow in the same cycle, so the persisted
        // mode must be the inverted current value; a KEY4 menu update leaves
        // the mode untouched and must record it as-is, otherwise every
        // volume/period change silently flips auto-slideshow - and writes
        // the flipped state back to flash across reboots.
        .cfg_mode(key3_press ? {7'd0, ~auto_enabled} :
                              {7'd0, auto_enabled}),
        .save_request(config_save_event), .service_ready(config_ready),
        .busy(config_busy), .load_done(config_load_done),
        .save_done(config_save_done), .apply_valid(config_apply_valid),
        .config_rejected(config_rejected),
        .fatal_error(config_fatal_error), .error_code(config_error_code),
        .request_dropped(config_request_dropped),
        .stored_config_valid(stored_config_valid),
        .active_version(stored_config_version),
        .live_period_ms(config_period_ms),
        .live_period_cycles(config_period_cycles),
        .live_volume(config_volume), .live_mode(config_mode),
        .jedec_id(config_jedec_id), .status1(config_status1),
        .status2(config_status2), .status3(config_status3),
        .flash_miso(flash_miso), .flash_cs_n(flash_cs_n),
        .flash_sclk(flash_sclk), .flash_mosi(flash_mosi),
        .flash_wp_n(flash_wp_n), .flash_hold_n(flash_hold_n)
    );

    reg config_save_ok_latched;
    always @(posedge sys_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n)
            config_save_ok_latched <= 1'b0;
        else if (config_save_done && !config_fatal_error)
            config_save_ok_latched <= 1'b1;
    end

    wire [3:0] image_complete_sys;
    genvar bit_index;
    generate
        for (bit_index = 0; bit_index < 4; bit_index = bit_index + 1) begin : g_image_sync
            sync_2ff u_sync (
                .clk(sys_clk), .rst_n(ctrl_rst_n),
                .async_in(image_complete[bit_index]),
                .sync_out(image_complete_sys[bit_index])
            );
        end
    endgenerate

    wire video_clk;
    wire video_hs;
    wire video_vs;
    wire video_de;
    wire [23:0] video_rgb;
    wire [9:0] video_x;
    wire [1:0] active_index;
    wire [1:0] pending_index;
    wire frame_start;
    wire reader_busy;
    wire reader_underflow;
    wire [7:0] video_error;
    wire boot_active;

    // FADE_FRAMES=16 gives roughly a 0.27 s ramp at 640x480@60 on both the
    // fade-out and fade-in halves of a manual switch.
    wire [7:0] brightness_pix;
    genvar bright_bit;
    generate
        for (bright_bit = 0; bright_bit < 8; bright_bit = bright_bit + 1) begin : g_bright_sync
            sync_2ff u_sync (
                .clk(pixel_clk), .rst_n(pix_rst_n),
                .async_in(brightness_sys[bright_bit]),
                .sync_out(brightness_pix[bright_bit])
            );
        end
    endgenerate

    media_video_pipeline #(
        .FADE_FRAMES(16), .BOOT_TITLE_FRAMES(300)
    ) u_video (
        .brightness(brightness_pix),
        .ctrl_clk(sys_clk), .ctrl_rst_n(ctrl_rst_n),
        .next_event(key2_press), .toggle_auto_event(key3_press),
        .period_cfg_valid(config_apply_valid),
        .period_cfg_cycles(config_period_cycles),
        .auto_cfg_valid(config_apply_valid),
        .auto_cfg_enabled(config_mode[0]),
        .image_complete(image_complete_sys),
        .player_enable(player_enable_mem), .mem_clk(mem_clk),
        .mem_rst_n(mem_rst_n), .controller_init_done(sdram_init_done),
        .controller_busy(sdram_busy), .refresh_active(sdram_refresh_active),
        .app_rd_en(player_app_rd_en), .app_rd_addr(player_app_rd_addr),
        .sdram_rd_valid(sdram_rd_valid), .sdram_rd_data(sdram_rd_data),
        .pix_clk(pixel_clk), .pix_rst_n(pix_rst_n),
        .video_clk(video_clk), .video_hs(video_hs),
        .video_vs(video_vs),
        .video_de(video_de), .video_rgb(video_rgb), .video_x(video_x),
        .boot_active(boot_active),
        .active_index(active_index),
        .pending_index(pending_index), .auto_enabled(auto_enabled),
        .frame_start(frame_start), .reader_busy(reader_busy),
        .reader_underflow(reader_underflow), .video_error(video_error)
    );

    // Background music: MUSIC.WAV streams from the TF card only after the
    // boot title has retired, so the title stays silent and the song starts
    // together with the gallery. The streamer loops the file by itself.
    wire boot_active_mem;
    sync_2ff #(.RESET_VAL(1'b1)) u_boot_active_mem (
        .clk(mem_clk), .rst_n(mem_rst_n),
        .async_in(boot_active), .sync_out(boot_active_mem)
    );
    // The streamer stays selected for the music for good once the gallery
    // runs (parked by file_pause if the file is unusable), so it is never
    // handed back mid-file.
    assign music_file_sel = player_enable_mem && music_valid && !boot_active_mem;
    wire wav_fifo_wr_en;
    wire [31:0] wav_fifo_wr_data;
    wire wav_fifo_has_room;
    wire wav_format_bad;
    wav_stream_ingest u_wav_ingest (
        .clk(mem_clk), .rst_n(mem_rst_n), .run(music_file_sel),
        .music_valid(music_valid),
        .fifo_has_room(wav_fifo_has_room),
        .fifo_wr_en(wav_fifo_wr_en), .fifo_wr_data(wav_fifo_wr_data),
        .file_start(music_file_start), .file_pause(music_file_pause),
        .file_valid(music_file_valid), .file_byte(music_file_byte),
        .file_done(music_file_done), .file_error(music_file_error),
        .format_bad(wav_format_bad), .loop_pulse()
    );
    // Both flags are static once set; a missing or unsupported file falls
    // back to the per-image tones.
    wire music_valid_video;
    wire wav_bad_video;
    sync_2ff u_music_valid_video (
        .clk(video_clk), .rst_n(pix_rst_n),
        .async_in(music_valid), .sync_out(music_valid_video)
    );
    sync_2ff u_wav_bad_video (
        .clk(video_clk), .rst_n(pix_rst_n),
        .async_in(wav_format_bad), .sync_out(wav_bad_video)
    );

    // Audio-video linkage: the displayed image picks the sustained note and
    // the persisted volume scales it. Both are slow, frame-granular signals
    // crossing into the registered video clock domain.
    wire [1:0] active_index_video;
    wire [7:0] volume_video;
    genvar media_bit;
    generate
        for (media_bit = 0; media_bit < 2; media_bit = media_bit + 1) begin : g_media_sync
            sync_2ff u_sync (
                .clk(video_clk), .rst_n(pix_rst_n),
                .async_in(active_index[media_bit]),
                .sync_out(active_index_video[media_bit])
            );
        end
    endgenerate
    generate
        for (media_bit = 0; media_bit < 8; media_bit = media_bit + 1) begin : g_volume_sync
            sync_2ff u_sync (
                .clk(video_clk), .rst_n(pix_rst_n),
                .async_in(config_volume[media_bit]),
                .sync_out(volume_video[media_bit])
            );
        end
    endgenerate

    wire [9:0] audio_symbol0;
    wire [9:0] audio_symbol1;
    wire [9:0] audio_symbol2;
    wire audio_sequence_error;
    wire audio_tone_overflow;
    wire audio_pcm_contract_error;
    wire audio_phy_phase_error;
    wire audio_blip_active;

    // Audio faults surface as 8'h71 (distinct from the 0x6x reader family
    // and 0x5x control family) so the UART log and the status OSD report the
    // same failure the 4'hd LED shows.
    // Cross-domain status wires (declared before first use to keep
    // synthesis logs free of HDL-5373 used-before-declaration noise).
    wire player_enable_sys;
    wire storage_error_sys;
    wire video_fault_sys;
    wire audio_fault_sys;
    wire [3:0] video_error_sys;

    // Storage failures surface the real ingest error code (SD init
    // 0x01-0x0c, filesystem 0x10-0x22, decoder 0x31-0x38, loader 0x41-0x46)
    // so the OSD and UART distinguish "no card" (CMD0 timeout) from
    // "no FAT/no BMP"; the blanket 0xFE remains for code-less failures.
    wire [7:0] storage_reported_error;
    // Publish an immutable code and its valid flag together in sys_clk.
    // The previous direct ingest_error_code -> UART path crossed mem_clk
    // without a coherent snapshot and failed final setup timing.
    // HOLD_CYCLES = 250 ms of sys_clk: the retry loop clears the latch as every
    // attempt begins, so the reported error is held across that short gap and
    // LED/UART show one steady error while the player keeps retrying.
    sticky_error_cdc #(.HOLD_CYCLES(12500000)) u_storage_error_snapshot (
        .src_clk(mem_clk), .src_rst_n(mem_rst_n),
        .src_error(ingest_done &&
                   (ingest_error_stage != 0 || ingest_error_code != 0 ||
                    image_complete != 4'hf || !title_complete)),
        .src_clear(ingest_attempt),
        .src_code(ingest_error_code), .src_latched(storage_error_mem),
        .dst_clk(sys_clk), .dst_rst_n(ctrl_rst_n),
        .dst_valid(storage_error_sys), .dst_code(storage_reported_error)
    );
    wire [7:0] reported_error = storage_error_sys ? storage_reported_error :
                                 config_fatal_error ? config_error_code :
                                 video_fault_sys ? {4'b0, video_error_sys} :
                                 audio_fault_sys ? 8'h71 :
                                 8'd0;

    // Status OSD: bank number, auto mode and fault code rendered in the
    // top-left corner. Purely combinational, so the video_x/video_de
    // alignment feeding the HDMI Data Island scheduler is preserved.
    wire auto_enabled_video;
    wire [7:0] reported_error_video;
    genvar osd_bit;
    sync_2ff u_auto_osd_sync (
        .clk(video_clk), .rst_n(pix_rst_n),
        .async_in(auto_enabled), .sync_out(auto_enabled_video)
    );
    generate
        for (osd_bit = 0; osd_bit < 8; osd_bit = osd_bit + 1) begin : g_osd_err
            sync_2ff u_sync (
                .clk(video_clk), .rst_n(pix_rst_n),
                .async_in(reported_error[osd_bit]),
                .sync_out(reported_error_video[osd_bit])
            );
        end
    endgenerate

    wire [23:0] video_rgb_osd;
    wire video_hs_osd;
    wire video_vs_osd;
    wire video_de_osd;
    wire [9:0] video_x_osd;
    osd_overlay_24 #(.OSD_X(8), .OSD_Y(8)) u_osd (
        .clk(video_clk), .rst_n(pix_rst_n),
        .hsync(video_hs), .vsync(video_vs), .de(video_de),
        .rgb_in(video_rgb), .pixel_x(video_x),
        .active_index(active_index_video), .auto_enabled(auto_enabled_video),
        .error_code(reported_error_video),
        .rgb_out(video_rgb_osd),
        .hsync_out(video_hs_osd), .vsync_out(video_vs_osd),
        .de_out(video_de_osd), .pixel_x_out(video_x_osd),
        .osd_active()
    );

    // E5 extension: audio waveform overlay, tapped from the samples the
    // bridge is actually transmitting. Combinational overlay - the timing
    // bundle stays aligned.
    wire [23:0] video_rgb_wave;
    wire audio_pcm_tap_valid;
    wire signed [15:0] audio_pcm_tap_left;
    promax_audio_waveform #(
        .WAVE_X(64), .WAVE_Y(336), .WAVE_WIDTH(512), .WAVE_HEIGHT(64)
    ) u_audio_waveform (
        .clk(video_clk), .rst_n(pix_rst_n),
        .vsync(video_vs_osd), .de(video_de_osd),
        .rgb_in(video_rgb_osd), .pixel_x(video_x_osd),
        .enable(1'b1),
        .pcm_tap_valid(audio_pcm_tap_valid), .pcm_tap_left(audio_pcm_tap_left),
        .rgb_out(video_rgb_wave), .waveform_active()
    );

    // E1 extension: scrolling subtitle banner, one caption per picture. Registered
    // stage - rgb and the whole timing bundle shift by the same clock.
    wire [23:0] video_rgb_sub;
    wire video_hs_sub;
    wire video_vs_sub;
    wire video_de_sub;
    wire [9:0] video_x_sub;
    // Subtitle adds one clock. Delay the clean title and selection equally so
    // bypassing every overlay keeps RGB aligned with its HDMI timing bundle.
    reg [23:0] title_rgb_delayed;
    reg clean_title_delayed;
    always @(posedge video_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            title_rgb_delayed <= 24'd0;
            clean_title_delayed <= 1'b1;
        end else begin
            title_rgb_delayed <= video_rgb;
            clean_title_delayed <= boot_active;
        end
    end
    subtitle_scroll_24 #(
        .SUB_Y(438), .SCROLL_STEP(3), .H_ACT(640)
    ) u_subtitle (
        .clk(video_clk), .rst_n(pix_rst_n),
        .hsync(video_hs_osd), .vsync(video_vs_osd), .de(video_de_osd),
        .pixel_x(video_x_osd), .rgb_in(video_rgb_wave),
        .caption_sel(active_index_video),
        .hsync_out(video_hs_sub), .vsync_out(video_vs_sub),
        .de_out(video_de_sub), .pixel_x_out(video_x_sub),
        .rgb_out(video_rgb_sub), .subtitle_active()
    );

    // Settings panel: appears for ~3.5 s after the volume, brightness,
    // auto-play or slideshow period changes. It is a combinational mux behind
    // registered pixels, so it adds no clock of delay to the video bundle.
    wire [1:0] period_code_sys = (config_period_ms < 32'd3500)  ? 2'd0 :
                                 (config_period_ms < 32'd7500)  ? 2'd1 :
                                 (config_period_ms < 32'd20000) ? 2'd2 : 2'd3;
    wire [1:0] period_code_video;
    genvar period_bit;
    generate
        for (period_bit = 0; period_bit < 2; period_bit = period_bit + 1) begin : g_period_sync
            sync_2ff u_sync (
                .clk(video_clk), .rst_n(pix_rst_n),
                .async_in(period_code_sys[period_bit]),
                .sync_out(period_code_video[period_bit])
            );
        end
    endgenerate
    wire sw4_video;
    sync_2ff u_sw4_sync (
        .clk(video_clk), .rst_n(pix_rst_n),
        .async_in(sw4), .sync_out(sw4_video)
    );
    localparam SW4_PLAY_LEVEL = 1'b1;
    wire audio_paused_video = (sw4_video != SW4_PLAY_LEVEL);
    wire [23:0] video_rgb_panel;
    settings_panel_overlay u_settings_panel (
        .clk(video_clk), .rst_n(pix_rst_n),
        .vsync(video_vs_sub), .de(video_de_sub), .pixel_x(video_x_sub),
        .rgb_in(video_rgb_sub), .suppress(boot_active),
        .active_index(active_index_video), .volume(volume_video),
        .brightness(brightness_pix), .auto_enabled(auto_enabled_video),
        .period_code(period_code_video),
        .music_on(music_valid_video && !wav_bad_video),
        .music_paused(audio_paused_video),
        .rgb_out(video_rgb_panel), .panel_visible()
    );

    media_hdmi_audio_bridge u_hdmi_audio_bridge (
        .pixel_clk(video_clk), .pixel_rst_n(pix_rst_n),
        .video_hsync(video_hs_sub), .video_vsync(video_vs_sub),
        .video_de(video_de_sub), .video_x(video_x_sub),
        .video_rgb(clean_title_delayed ? title_rgb_delayed : video_rgb_panel),
        .media_id(active_index_video),
        .volume(clean_title_delayed ? 8'd0 : volume_video),
        .audio_pause(audio_paused_video),
        .wav_select(music_valid_video && !wav_bad_video),
        .wav_wr_clk(mem_clk), .wav_wr_rst_n(mem_rst_n),
        .wav_wr_en(wav_fifo_wr_en), .wav_wr_data(wav_fifo_wr_data),
        .wav_wr_has_room(wav_fifo_has_room),
        .pcm_tap_valid(audio_pcm_tap_valid), .pcm_tap_left(audio_pcm_tap_left),
        .channel0_symbol(audio_symbol0),
        .channel1_symbol(audio_symbol1),
        .channel2_symbol(audio_symbol2),
        .sequence_error(audio_sequence_error),
        .tone_overflow(audio_tone_overflow),
        .pcm_contract_error(audio_pcm_contract_error),
        .blip_active(audio_blip_active)
    );

    hdmi_tmds_eg4_phy u_hdmi_audio_phy (
        .pixel_clk(video_clk), .pixel_rst_n(pix_rst_n),
        .clk_5x(pixel_clk_5x), .clk_5x_rst_n(pix_5x_rst_n),
        .channel0_symbol(audio_symbol0),
        .channel1_symbol(audio_symbol1),
        .channel2_symbol(audio_symbol2),
        .tmds_clock_p(HDMI_CLK_P), .tmds_data0_p(HDMI_D0_P),
        .tmds_data1_p(HDMI_D1_P), .tmds_data2_p(HDMI_D2_P),
        .phase_error(audio_phy_phase_error)
    );

    sync_2ff u_player_enable_sys (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .async_in(player_enable_mem), .sync_out(player_enable_sys)
    );
    sync_2ff u_video_fault_sys (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .async_in(video_error != 0), .sync_out(video_fault_sys)
    );
    sync_2ff u_audio_fault_sys (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .async_in(audio_sequence_error || audio_tone_overflow ||
                  audio_pcm_contract_error ||
                  audio_phy_phase_error),
        .sync_out(audio_fault_sys)
    );

    genvar error_bit_index;
    generate
        for (error_bit_index = 0; error_bit_index < 4;
             error_bit_index = error_bit_index + 1) begin : g_video_error_sync
            sync_2ff u_sync (
                .clk(sys_clk), .rst_n(ctrl_rst_n),
                .async_in(video_error[error_bit_index]),
                .sync_out(video_error_sys[error_bit_index])
            );
        end
    endgenerate

    // UART status reporter: boot banner, image switch lines, parameter
    // menu changes and fault codes on the board USB-UART at 115200 8N1.
    wire [1:0] active_index_sys;
    genvar uart_bit;
    generate
        for (uart_bit = 0; uart_bit < 2; uart_bit = uart_bit + 1) begin : g_media_sys
            sync_2ff u_sync (
                .clk(sys_clk), .rst_n(ctrl_rst_n),
                .async_in(active_index[uart_bit]),
                .sync_out(active_index_sys[uart_bit])
            );
        end
    endgenerate

    reg [1:0] active_index_sys_q;
    always @(posedge sys_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n)
            active_index_sys_q <= 2'd0;
        else
            active_index_sys_q <= active_index_sys;
    end
    wire switch_evt = (active_index_sys != active_index_sys_q);


    uart_status_reporter #(.CLKS_PER_BIT(434)) u_uart_report (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .enable(player_enable_sys), .media_id(active_index_sys),
        .volume(config_volume), .period_ms(config_period_ms),
        .auto_enabled(auto_enabled),
        .switch_event(switch_evt), .menu_event(menu_evt),
        .menu_kind(menu_kind), .error_code(reported_error),
        .bright_event(key3_long_press && config_ready),
        .bright_value(brightness_sys),
        .uart_tx(uart_tx_o)
    );

    // Competition-facing playback indicators with fault-code priority:
    // storage all-on, config code, audio 4'hD, video code, save-ok 4'b0101,
    // then the running bank/auto/auto state.
    assign led = storage_error_sys ? 4'hf :
                 config_fatal_error ? {1'b1,config_error_code[2:0]} :
                 audio_fault_sys ? 4'hd :
                 video_fault_sys ? video_error_sys :
                 config_save_ok_latched ? 4'b0101 :
                 player_enable_sys ? {1'b0, auto_enabled, active_index} :
                 {1'b0, 1'b0, &image_complete_sys,
                  mem_locked & video_locked};

endmodule

`timescale 1ns/1ps
// HDMI audio bridge with the real packet chain: switching between the tone
// and the WAV source at arbitrary moments must never trip the PCM contract
// check, the packet sequence check or the overflow flags, and the WAV frames
// must come out in order, scaled by the player volume.
module tb_audio_bridge_wav;
    reg mem_clk = 0, pix_clk = 0;
    always #12.5 mem_clk = ~mem_clk;
    always #20 pix_clk = ~pix_clk;
    reg rst_n = 0;

    wire hs, vs, de;
    wire [11:0] vx, vy;
    video_timing_ctrl vtc (.pclk(pix_clk), .rst_n(rst_n), .hsync(hs), .vsync(vs),
                           .de(de), .x(vx), .y(vy));

    // WAV frame writer: ramp, L = n+1, R = -(n+1); fills while there is room.
    reg wav_wr_en = 0;
    reg [31:0] wav_wr_data = 0;
    integer wr_n = 0;
    wire has_room;
    always @(posedge mem_clk) begin
        wav_wr_en <= 0;
        if (rst_n && has_room && !wav_wr_en) begin
            wav_wr_en <= 1;
            wav_wr_data <= {16'(-(wr_n + 1)), 16'(wr_n + 1)};
            wr_n <= wr_n + 1;
        end
    end

    reg wav_select = 0;
    reg pause = 0;
    reg [7:0] volume = 8'd255;
    wire [9:0] ch0, ch1, ch2;
    wire seq_err, tone_ovf, contract_err, blip;
    media_hdmi_audio_bridge dut (
        .pixel_clk(pix_clk), .pixel_rst_n(rst_n),
        .video_hsync(hs), .video_vsync(vs), .video_de(de), .video_x(vx[9:0]),
        .video_rgb(24'h203040), .media_id(2'd1), .volume(volume),
        .audio_pause(pause), .wav_select(wav_select), .wav_wr_clk(mem_clk), .wav_wr_rst_n(rst_n),
        .wav_wr_en(wav_wr_en), .wav_wr_data(wav_wr_data),
        .wav_wr_has_room(has_room),
        .channel0_symbol(ch0), .channel1_symbol(ch1), .channel2_symbol(ch2),
        .sequence_error(seq_err), .tone_overflow(tone_ovf),
        .pcm_contract_error(contract_err), .blip_active(blip),
        .pcm_tap_valid(), .pcm_tap_left()
    );

    // Observe samples that actually cross into the packet chain.
    integer expect_n = 0, wav_samples = 0, tone_samples = 0, silent_after = 0, wrong = 0;
    reg started = 0;
    integer exp_l, exp_r;
    integer grace = 0;     // silent frames already queued when the pause began / ends
    integer paused_wav = 0, paused_checks = 0;
    always @(posedge pix_clk) begin
        if (rst_n && dut.sample_valid && dut.sample_ready) begin
            if (pause) grace = 16;
            else if (grace > 0) grace = grace - 1;
            if (dut.use_wav) begin
                if (dut.sample_left == 0 && dut.sample_right == 0) begin
                    if (started && grace == 0) silent_after = silent_after + 1;
                end else begin
                    started = 1;
                    exp_l = ((expect_n + 1) * volume) >>> 8;
                    exp_r = (-(expect_n + 1) * volume) >>> 8;
                    if (dut.sample_left !== exp_l[15:0] || dut.sample_right !== exp_r[15:0]) begin
                        if (wrong < 5)
                            $display("MISMATCH n=%0d got %0d/%0d exp %0d/%0d",
                                     expect_n, dut.sample_left, dut.sample_right, exp_l, exp_r);
                        wrong = wrong + 1;
                    end
                    expect_n = expect_n + 1;
                    wav_samples = wav_samples + 1;
                end
            end else
                tone_samples = tone_samples + 1;
        end
    end

    integer round, wait_clks;
    initial begin
        repeat (10) @(negedge mem_clk);
        rst_n = 1;
        repeat (60000) @(posedge pix_clk);          // tone only, ~2.4 ms
        for (round = 0; round < 12; round = round + 1) begin
            wav_select = 1;
            wait_clks = 4000 + ($random & 16'h7fff);   // random switch phase
            repeat (wait_clks) @(posedge pix_clk);
            if (round % 4 == 2) begin
                // SW4 pause in the middle of the song: no WAV frame may be
                // consumed while paused, and the song resumes at the same spot.
                pause = 1;
                repeat (3000) @(posedge pix_clk);
                paused_wav = wav_samples;
                repeat (15000) @(posedge pix_clk);
                if (wav_samples != paused_wav) $fatal(1, "WAV advanced while paused (%0d -> %0d)", paused_wav, wav_samples);
                paused_checks = paused_checks + 1;
                pause = 0;
            end
            // The player volume changes live; the new value must apply cleanly.
            volume = (round % 3 == 0) ? 8'd255 : (round % 3 == 1) ? 8'd192 : 8'd64;
            repeat (20000) @(posedge pix_clk);
            wav_select = 0;
            wait_clks = 3000 + ($random & 16'h3fff);
            repeat (wait_clks) @(posedge pix_clk);
        end
        if (contract_err) $fatal(1, "PCM contract violated during source switching");
        if (seq_err) $fatal(1, "HDMI audio sequence error");
        if (tone_ovf) $fatal(1, "audio overflow flag raised");
        if (wrong != 0) $fatal(1, "%0d wrong WAV frames", wrong);
        if (silent_after != 0) $fatal(1, "%0d silent frames inside WAV playback", silent_after);
        if (paused_checks < 2) $fatal(1, "pause not exercised");
        if (wav_samples < 500 || tone_samples < 200)
            $fatal(1, "sources not both exercised: wav=%0d tone=%0d", wav_samples, tone_samples);
        $display("PASS audio bridge: %0d WAV and %0d tone samples, 24 clean source switches, volume steps applied, %0d pause/resume cycles hold position",

                 wav_samples, tone_samples, paused_checks);
        $finish;
    end
endmodule

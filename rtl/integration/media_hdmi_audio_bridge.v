`timescale 1ns/1ps

// Player-owned boundary between the registered video bundle and the verified
// Route B HDMI packet/symbol chain. The EG4 DDR PHY remains in the board Top so
// this bridge can be exercised in ordinary RTL simulation without vendor pads.
// media_id drives the per-image tone selection and volume scales the output,
// turning the tone source into the audio half of the AV-linked feature.
module media_hdmi_audio_bridge (
    input  wire        pixel_clk,
    input  wire        pixel_rst_n,
    input  wire        video_hsync,
    input  wire        video_vsync,
    input  wire        video_de,
    input  wire [9:0]  video_x,
    input  wire [23:0] video_rgb,
    input  wire [1:0]  media_id,
    input  wire [7:0]  volume,
    // Audio play/pause switch (quasi-static level in this clock domain). While
    // paused the song holds its position and the tone source is muted.
    input  wire        audio_pause,
    // MUSIC.WAV source: wav_select is a quasi-static level in this clock
    // domain; the frame write port belongs to the storage (mem_clk) domain.
    input  wire        wav_select,
    input  wire        wav_wr_clk,
    input  wire        wav_wr_rst_n,
    input  wire        wav_wr_en,
    input  wire [31:0] wav_wr_data,
    output wire        wav_wr_has_room,
    output wire [9:0]  channel0_symbol,
    output wire [9:0]  channel1_symbol,
    output wire [9:0]  channel2_symbol,
    output wire        sequence_error,
    output wire        tone_overflow,
    output wire        pcm_contract_error,
    output wire        blip_active,
    // PCM tap of the samples actually handed to the packet chain; used by the
    // waveform overlay so the display shows the audio being transmitted.
    output wire        pcm_tap_valid,
    output wire signed [15:0] pcm_tap_left
);
    wire source_valid;
    wire source_ready;
    wire signed [15:0] source_left;
    wire signed [15:0] source_right;
    wire tone_valid;
    wire tone_ready;
    wire signed [15:0] tone_left;
    wire signed [15:0] tone_right;
    wire tone_overflow_raw;
    wire wav_valid;
    wire wav_ready;
    wire signed [15:0] wav_left;
    wire signed [15:0] wav_right;
    wire wav_overflow;
    wire wav_underflow;

    // The active source only changes while no sample is waiting for ready, so
    // the PCM contract (data stable while valid && !ready) is never broken.
    reg use_wav;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n)
            use_wav <= 1'b0;
        else if (!(source_valid && !source_ready))
            use_wav <= wav_select;
    end
    assign source_valid = use_wav ? wav_valid : tone_valid;
    assign source_left = use_wav ? wav_left : tone_left;
    assign source_right = use_wav ? wav_right : tone_right;
    assign tone_ready = use_wav ? 1'b0 : source_ready;
    assign wav_ready = use_wav ? source_ready : 1'b0;
    assign tone_overflow = tone_overflow_raw | wav_overflow;
    wire sample_valid;
    wire sample_ready;
    wire signed [15:0] sample_left;
    wire signed [15:0] sample_right;
    // One clock per sample actually handed to the packet chain (valid && ready),
    // so the waveform overlay counts samples, not clocks.
    assign pcm_tap_valid = sample_valid && sample_ready;
    assign pcm_tap_left = sample_left;

    pcm_media_tone u_tone (
        .clk(pixel_clk), .rst_n(pixel_rst_n),
        .media_id(media_id), .volume(audio_pause ? 8'd0 : volume), .standby(use_wav),
        .sample_valid(tone_valid), .sample_ready(tone_ready),
        .sample_left(tone_left), .sample_right(tone_right),
        .overflow(tone_overflow_raw), .blip_active(blip_active)
    );

    wav_pcm_source u_wav_source (
        .wr_clk(wav_wr_clk), .wr_rst_n(wav_wr_rst_n),
        .wr_en(wav_wr_en), .wr_data(wav_wr_data),
        .wr_has_room(wav_wr_has_room),
        .clk(pixel_clk), .rst_n(pixel_rst_n), .enable(use_wav),
        .pause(audio_pause), .volume(volume),
        .sample_valid(wav_valid), .sample_ready(wav_ready),
        .sample_left(wav_left), .sample_right(wav_right),
        .overflow(wav_overflow), .underflow(wav_underflow)
    );

    m06_pcm_contract_adapter u_m06_pcm_contract (
        .clk(pixel_clk), .rst_n(pixel_rst_n),
        .source_valid(source_valid), .source_ready(source_ready),
        .source_left(source_left), .source_right(source_right),
        .pcm_valid(sample_valid), .pcm_ready(sample_ready),
        .pcm_left(sample_left), .pcm_right(sample_right),
        .contract_error(pcm_contract_error)
    );

    hdmi_audio_symbol_core u_symbol_core (
        .pixel_clk(pixel_clk), .rst_n(pixel_rst_n),
        .video_hsync(video_hsync), .video_vsync(video_vsync),
        .video_de(video_de), .video_x(video_x), .video_rgb(video_rgb),
        .sample_valid(sample_valid), .sample_ready(sample_ready),
        .sample_left(sample_left), .sample_right(sample_right),
        .channel0_symbol(channel0_symbol),
        .channel1_symbol(channel1_symbol),
        .channel2_symbol(channel2_symbol),
        .sequence_error(sequence_error)
    );
endmodule

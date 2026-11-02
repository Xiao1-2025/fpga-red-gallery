param([string]$IcarusBin = 'D:\FPGA\iverilog\bin')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $PSScriptRoot 'boot_title_build'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$sources = @(Get-ChildItem (Join-Path $root 'rtl') -Recurse -Filter '*.v' | ForEach-Object FullName)
$sources += @('al_ip/afifo_32_16_256.v','src/sync_2ff.v','src/fifo_prefetch_2.v','src/video_timing_ctrl.v','src/rgb_video_adapter.v') | ForEach-Object { Join-Path $root "dependencies/lesson36_build/$_" }
foreach ($test in @('tb_boot_title_ingest','tb_boot_title_video','tb_bmp_fit','tb_bmp_fit_errors','tb_file_pause')) {
    $exe = Join-Path $out "$test.vvp"
    & (Join-Path $IcarusBin 'iverilog.exe') -g2012 -s $test -o $exe (Join-Path $PSScriptRoot "$test.sv") @sources
    if ($LASTEXITCODE -ne 0) { throw "Compile failed: $test" }
    & (Join-Path $IcarusBin 'vvp.exe') $exe
    if ($LASTEXITCODE -ne 0) { throw "Test failed: $test" }
}
$fadeExe = Join-Path $out 'tb_boot_title_video_fade.vvp'
& (Join-Path $IcarusBin 'iverilog.exe') -g2012 -DTEST_FADE_FRAMES=16 -s tb_boot_title_video -o $fadeExe (Join-Path $PSScriptRoot 'tb_boot_title_video.sv') @sources
if ($LASTEXITCODE -ne 0) { throw 'Compile failed: boot title with fade' }
& (Join-Path $IcarusBin 'vvp.exe') $fadeExe
if ($LASTEXITCODE -ne 0) { throw 'Test failed: boot title with fade' }

# MUSIC.WAV streaming: stereo, mono, reduced volume and a rejected sample rate.
$wavVariants = @(
    @{ Name = 'tb_wav_stream_stereo'; Defines = @() },
    @{ Name = 'tb_wav_stream_mono';   Defines = @('-DTEST_MONO') },
    @{ Name = 'tb_wav_stream_vol100'; Defines = @('-DTEST_VOLUME=100') },
    @{ Name = 'tb_wav_stream_bad44k'; Defines = @('-DTEST_RATE=44100') }
)
foreach ($variant in $wavVariants) {
    $exe = Join-Path $out "$($variant.Name).vvp"
    & (Join-Path $IcarusBin 'iverilog.exe') -g2012 @($variant.Defines) -s tb_wav_stream -o $exe (Join-Path $PSScriptRoot 'tb_wav_stream.sv') @sources
    if ($LASTEXITCODE -ne 0) { throw "Compile failed: $($variant.Name)" }
    & (Join-Path $IcarusBin 'vvp.exe') $exe
    if ($LASTEXITCODE -ne 0) { throw "Test failed: $($variant.Name)" }
}

# HDMI audio bridge with the real packet chain (PHY primitives excluded).
$hdmiSources = @(Get-ChildItem (Join-Path $root 'risk_prototypes/hdmi_audio_route_b/rtl') -Filter '*.v' |
    Where-Object { $_.Name -notmatch 'eg4' } | ForEach-Object FullName)
$bridgeExe = Join-Path $out 'tb_audio_bridge_wav.vvp'
& (Join-Path $IcarusBin 'iverilog.exe') -g2012 -s tb_audio_bridge_wav -o $bridgeExe (Join-Path $PSScriptRoot 'tb_audio_bridge_wav.sv') @sources @hdmiSources
if ($LASTEXITCODE -ne 0) { throw 'Compile failed: audio bridge' }
& (Join-Path $IcarusBin 'vvp.exe') $bridgeExe
if ($LASTEXITCODE -ne 0) { throw 'Test failed: audio bridge' }

# Settings panel: trigger rules, timer and highlight (pass +dump=<prefix> to vvp for PPM frames).
$panelExe = Join-Path $out 'tb_settings_panel.vvp'
& (Join-Path $IcarusBin 'iverilog.exe') -g2012 -s tb_settings_panel -o $panelExe (Join-Path $PSScriptRoot 'tb_settings_panel.sv') @sources
if ($LASTEXITCODE -ne 0) { throw 'Compile failed: settings panel' }
& (Join-Path $IcarusBin 'vvp.exe') $panelExe
if ($LASTEXITCODE -ne 0) { throw 'Test failed: settings panel' }

# Per-picture scrolling subtitle, checked against tests/subtitle_expected.mem (run from the project root).
$subExe = Join-Path $out 'tb_subtitle.vvp'
& (Join-Path $IcarusBin 'iverilog.exe') -g2012 -s tb_subtitle -o $subExe (Join-Path $PSScriptRoot 'tb_subtitle.sv') (Join-Path $root 'rtl/display/subtitle_scroll_24.v') (Join-Path $root 'dependencies/lesson36_build/src/video_timing_ctrl.v')
if ($LASTEXITCODE -ne 0) { throw 'Compile failed: subtitle' }
Push-Location $root
try { & (Join-Path $IcarusBin 'vvp.exe') $subExe } finally { Pop-Location }
if ($LASTEXITCODE -ne 0) { throw 'Test failed: subtitle' }

# Audio waveform overlay (sample strobe, trace shape, auto scale).
$waveExe = Join-Path $out 'tb_waveform.vvp'
& (Join-Path $IcarusBin 'iverilog.exe') -g2012 -s tb_waveform -o $waveExe (Join-Path $PSScriptRoot 'tb_waveform.sv') (Join-Path $root 'rtl/display/promax_audio_waveform.v') (Join-Path $root 'dependencies/lesson36_build/src/video_timing_ctrl.v')
if ($LASTEXITCODE -ne 0) { throw 'Compile failed: waveform' }
& (Join-Path $IcarusBin 'vvp.exe') $waveExe
if ($LASTEXITCODE -ne 0) { throw 'Test failed: waveform' }

# TF card inserted after power-up: SPI-level card model, absent -> inserted -> pulled mid-load -> re-inserted.
$hpExe = Join-Path $out 'tb_sd_hotplug.vvp'
& (Join-Path $IcarusBin 'iverilog.exe') -g2012 -s tb_sd_hotplug -o $hpExe (Join-Path $PSScriptRoot 'tb_sd_hotplug.sv') (Join-Path $PSScriptRoot 'sd_card_spi_model.sv') @sources
if ($LASTEXITCODE -ne 0) { throw 'Compile failed: sd hotplug' }
& (Join-Path $IcarusBin 'vvp.exe') $hpExe
if ($LASTEXITCODE -ne 0) { throw 'Test failed: sd hotplug' }

# Config journal: slot selection and the saved record (the CRC is built over two clocks).
$cjExe = Join-Path $out 'tb_config_journal.vvp'
& (Join-Path $IcarusBin 'iverilog.exe') -g2012 -s tb_config_journal -o $cjExe (Join-Path $PSScriptRoot 'tb_config_journal.sv') (Join-Path $root 'rtl/config/config_journal.v')
if ($LASTEXITCODE -ne 0) { throw 'Compile failed: config journal' }
& (Join-Path $IcarusBin 'vvp.exe') $cjExe
if ($LASTEXITCODE -ne 0) { throw 'Test failed: config journal' }

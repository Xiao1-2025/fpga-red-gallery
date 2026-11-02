# 背景音乐：TF 卡 MUSIC.WAV

## 行为

- 启动页期间静音，不访问 `MUSIC.WAV`。启动页结束、进入画廊后开始读卡并播放。
- 播放到文件末尾后自动从头开始，循环播放；回绕时 FIFO 里还有缓存，不产生静音间隙。
- 音量沿用原有 KEY4 音量档（含 Flash 保存），对音乐和原琶音提示音同样生效。
- 拨动开关 SW4（引脚 C5）可暂停/继续音乐：暂停时音乐停在当前位置，继续后从该位置接着播；提示音同样静音。
  引脚上拉，默认高电平为“播放”；若实板拨动方向相反，把顶层 `SW4_PLAY_LEVEL` 改为 0。
- 没有 `MUSIC.WAV`，或文件格式不受支持时，自动回到原来的“每张图一段琶音”提示音，不报错。

## TF 卡文件

TF 卡根目录（FAT32）放入 `TITLE.BMP`、`PIC1.BMP`~`PIC4.BMP` 和 `MUSIC.WAV`。
`MUSIC.WAV` 可在 `assets/red_memory_audio/` 找到，约 29 MB（约 2 分 32 秒）。

支持格式：PCM（格式码 1）、48 kHz、16 位，单声道或立体声（单声道复制到左右声道）。
文件头里 `LIST` 等额外数据块会被跳过；`data` 块长度为 0 或 0xFFFFFFFF 时按读到文件末尾处理。
其他采样率、位深或压缩格式会被拒绝，退回提示音。

## 实现

| 模块 | 作用 |
| --- | --- |
| `rtl/audio/wav_stream_ingest.v` | 解析 RIFF/fmt/data，按帧写入 FIFO，文件读完后重新开始 |
| `rtl/audio/pcm_async_fifo.v` | mem_clk 到音频时钟的格雷码双时钟 FIFO（2048 帧，块 RAM） |
| `rtl/audio/wav_pcm_source.v` | 按 48 kHz 取帧、乘音量、缺数据时输出静音帧，并给 HDMI 音频链 valid/ready |
| `rtl/integration/media_hdmi_audio_bridge.v` | 在琶音提示音与 WAV 之间选择，只在没有待送样本时切换 |
| `rtl/filesystem/fat32_volume_scanner.v` | 识别根目录中的 `MUSIC.WAV`（可选） |
| `rtl/filesystem/fat32_file_streamer.v` | 新增 `loop_check_en`；音乐关闭簇链环路检测，不受 2048 簇上限限制 |
| `rtl/integration/media_ingest_pipeline.v` | 图片加载完成后，把同一个文件流模块借给音乐播放 |

SD 读取按扇区暂停，FIFO 有空位才继续读，所以读卡速度只跟随播放速度。
音乐沿用图片加载用的同一个文件流模块和 SD 读扇区通道，图片全部写入 SDRAM 后才开始，两者不会同时使用。

## 验证

`tests/run_boot_title.ps1` 包含：

- `tb_wav_stream`：合成 FAT32 卡，簇链故意打乱，文件头带 `LIST` 和奇数长度数据块；检查采样顺序、循环 3 遍无缝、音量缩放；
  另有单声道、音量 100、44.1 kHz 被拒绝（并停止读卡）三个变体。
- `tb_audio_bridge_wav`：接真实 HDMI 音频打包链，随机时刻在提示音和 WAV 之间切换 24 次，音量中途变化；
  PCM 合同、包序列、溢出标志均无报错，WAV 帧顺序正确。
- `tb_boot_title_ingest`：`MUSIC.WAV` 在目录最后、缺失两种情况；借用文件流读出的字节与文件内容一致，且不触发图片解码。

TD 6.2.1 全流程：Setup WNS +0.200 ns，Hold WNS +0.024 ns，TNS 均为 0；LUT 15678/19600，BRAM 37/64，DSP 25/29。
尚未实板下载验证，也未用示波器或耳机确认声音。

# 启动页实现与验证

顶层 `media_player_excellence_top` 启用 `LOAD_TITLE=1`、`BOOT_TITLE_FRAMES=300`(25 MHz 像素时钟、约 59.5 Hz,约 5 秒)。通用加载模块默认 `LOAD_TITLE=0`、视频模块默认 `BOOT_TITLE_FRAMES=0`，便于继续使用不带启动页的调用方式。

SDRAM 的正常四帧基地址为 0、307200、614400、921600；启动页使用独立的第五帧，基地址 1228800，最后一个字地址为 1535999。正常图片编号仍为两位，启动页只在读帧选择器中使用编号 4，不影响按键、自动循环及配置格式。

沿用先写后读的访问结构：TITLE、PIC1、PIC2、PIC3、PIC4 全部加载成功后才使能读取。在首个场同步边沿启动显示，保持启动页 300 个完整画面，再在消隐区切入 PIC1。计时不会保存到 Flash，每次复位重新开始。启动页 RGB 绕过效果层，顶层通过与字幕相同的一拍延迟绕过所有叠加层；音频音量置零。

运行 `powershell -ExecutionPolicy Bypass -File project_code/tests/run_boot_title.ps1`。脚本默认使用 `D:\FPGA\iverilog\bin`，其他路径可通过 `-IcarusBin` 指定。输出位于 `tests/boot_title_build/`。

本次检查：

- `tb_boot_title_ingest`：真实扫描器、文件流、BMP 解码器和写帧模块；测试 TITLE 位于第二个目录扇区最后一项、缺失 TITLE、TITLE 位于首项，逐像素校验五帧的地址及颜色，包括 BMP 自下而上的行翻转。
- `tb_boot_title_video`：真实读帧 FIFO 和异步时钟；缩小分辨率和启动帧数，检查恰好三个完整启动画面、首次正常画面为 PIC1、启动前已启用自动模式及按下下一张仍不会跳图、循环超过一轮后不返回启动页。分别运行 FADE_FRAMES=0 和顶层使用的 16。
- 现有 `tb_bmp_fit`、`tb_bmp_fit_errors`、`tb_file_pause` 回归。
- 修正原扫描器最后目录项刚被接受时立即检查旧完成标志的问题；BMP 解码器将 `line_read_x` 声明移到使用之前，以兼容 Icarus，逻辑不变。

TD 6.2.1 使用现有 `build_scaling_quality.tcl` 完成全工程综合、布局布线及 bit 生成，输出 `project/quality_build/media_player_excellence_quality.bit`。本次报告：Setup WNS 0.157 ns，Hold WNS 0.037 ns，Setup/Hold TNS 均为 0；LUT 14345/19600、BRAM 29/64、DSP 23/29。报告文件为同目录的 `quality_pr.timing` 和 `quality_phy.area`。

构建仍有原约束中 `busy_sync1`、`commit_sync1` 通配符未匹配的警告；上述时序结果以当前 SDC 的实际覆盖为准（报告 STA coverage 99.98%），不代表已完成所有 CDC 或板级时序验证。本次没有修改原 SDC。尚未进行实板下载和显示验证，也未实现 WAV 播放。

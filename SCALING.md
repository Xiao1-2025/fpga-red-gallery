# 拓展三：图片缩放适配

图片读取时自动等比例缩放至 640×480 显示区，居中放置，剩余区域补黑。
大图缩小默认采用整数区域平均（box averaging），小图放大保留最近邻采样；
无按键操作，也不需要在电脑上预先改成 640×480。
缩放结果写入原有 SDRAM 图片区，后续播放仍使用固定尺寸帧，兼容已有淡入淡出和滑动转场。

| 输入尺寸 | 显示图像尺寸 | 黑边 |
| --- | --- | --- |
| 640×480 | 640×480 | 无 |
| 320×240 | 640×480 | 无 |
| 1920×1080 | 640×360 | 上下各 60 像素 |
| 480×800 | 288×480 | 左右各 176 像素 |
| 1125×2436 | 221×480 | 左 209、右 210 像素 |

## 使用

1. 在 TD 中重新打开 `project/media_player_excellence.al`，确保源文件列表包含 `bmp24_fit_decoder.v`，再执行完整编译。
2. 下载本次生成的 `.bit`。`reference_build` 内的历史文件不包含缩放功能。
3. TF 卡继续使用 FAT32，根目录文件名仍为 `PIC1.BMP` 到 `PIC4.BMP`。
4. 换入不同宽高比的图片，重新加载资源，观察图片完整显示及黑边；再检查手动和自动转场。

支持 24 位、未压缩（BI_RGB）的 BMP，宽、高绝对值各为 1～4096。
兼容正高度（自底向上）和负高度（自顶向下）、四字节行补齐和扩展像素偏移。
不支持 JPEG、PNG、调色板 BMP、32 位 BMP 或压缩 BMP。
最近邻放大有像素感；缩放尺寸取整数，极端宽高比的窄边至少保留 1 像素。
区域平均主要减少缩小时的锯齿、细线断裂和纹理混叠，边缘可能更柔和，无法保留超过显示分辨率的细节。
大图片读取耗时会增加。原有 FAT 链遍历最多 2048 个簇，单文件还受
`2048 × 每簇字节数` 限制；测试 1080p BMP 建议每簇至少 4 KiB。

## 实现

- `bmp24_decoder.v`：新增可变尺寸模式；默认参数仍保留固定尺寸检查。
- `bmp24_fit_decoder.v`：解析尺寸、计算显示区域、缩小时区域平均、放大时最近邻采样、补黑和完整帧提交。
- `fat32_file_streamer.v`：只在扇区边界暂停新数据请求，避免截断正在传输的扇区。
- `media_frame_loader.v`：输出 FIFO 容量反馈，缩放器据此暂停像素发送；
  写入 FIFO 使用同步块 RAM，保留连续突发写入时序，为新增滤波逻辑释放 LUT 和布线空间。
- 缩放器字节队列、最近邻行缓存和区域累加行缓存均使用块 RAM，不缓存整幅原图。

### 缩小质量优化

`bmp24_fit_decoder` 的 `BOX_FILTER` 默认值为 `1`，工程现有实例自动启用。
设为 `0` 并重新编译可恢复上一版最近邻算法，便于比较。

将原图宽、高记为 `sw/sh`，适配后的宽、高记为 `fw/fh`。
输出像素 `(x,y)` 对应以下原图矩形（右、下边界不包含）：

```text
x0 = ceil(x * sw / fw)       x1 = ceil((x+1) * sw / fw)
y0 = ceil(y * sh / fh)       y1 = ceil((y+1) * sh / fh)
RGB = round(sum(source[y0:y1, x0:x1]) / ((x1-x0)*(y1-y0)))
```

每个原图像素参与一次累加。三个颜色通道分别保留 32 位累加值，最后统一除以采样数，
四舍五入，避免先横向再纵向取整的精度损失。底向上 BMP 反转纵向分组顺序，
保证文件存储方向不同不会改变显示结果。
这是整数矩形分组平均，不是按边界覆盖比例加权的面积重采样，也不是双线性插值。
两倍缩小的黑白棋盘格得到灰色 `128`，避免最近邻只采到同一种颜色。

区域行缓存为 `1024×109` 位（640 宽输出），保存各列 RGB 累加值和水平采样数。
采用三个并行的 32 周期串行除法器；加载期间通过现有扇区暂停机制控制输入。
图片加载会增加计算时间，加载完成后的播放及转场仍读取固定尺寸 SDRAM 帧。

## 仿真

在工程根目录，使用 Icarus Verilog 运行：

```powershell
iverilog -g2012 -s tb_bmp_fit -o fit.vvp tests/tb_bmp_fit.sv rtl/image/bmp24_decoder.v rtl/image/bmp24_fit_decoder.v rtl/memory/media_frame_loader.v
vvp fit.vvp
iverilog -g2012 -DTEST_BOX_FILTER=0 -s tb_bmp_fit -o nearest.vvp tests/tb_bmp_fit.sv rtl/image/bmp24_decoder.v rtl/image/bmp24_fit_decoder.v rtl/memory/media_frame_loader.v
vvp nearest.vvp
iverilog -g2012 -DTEST_WIDTH=640 -DTEST_HEIGHT=480 -s tb_bmp_fit -o full.vvp tests/tb_bmp_fit.sv rtl/image/bmp24_decoder.v rtl/image/bmp24_fit_decoder.v rtl/memory/media_frame_loader.v
vvp full.vvp
iverilog -g2012 -s tb_bmp_fit_errors -o errors.vvp tests/tb_bmp_fit_errors.sv rtl/image/bmp24_decoder.v rtl/image/bmp24_fit_decoder.v
vvp errors.vvp
iverilog -g2012 -s tb_file_pause -o pause.vvp tests/tb_file_pause.sv rtl/filesystem/fat32_file_streamer.v
vvp pause.vvp
```

主测试逐像素比较缩放输出及 SDRAM 写入地址/数据，模拟 512 字节扇区传输、写入繁忙和刷新暂停。
覆盖放大、缩小、横竖图、奇数尺寸、上下方向和非零行补齐，另有黑白棋盘格、红蓝条纹、全白图检查。
错误测试覆盖签名、尺寸、planes、位深、压缩、偏移和截断文件；错误图片不得提交。
小尺寸测试也检查连续文件切换（不复位）和 4096×1、1×4096 极端尺寸。
文件流测试使用真实 FAT32 streamer，检查扇区内暂停仍收完当前扇区、暂停期间停止新数据扇区、
跨簇读取 FAT 和恢复后字节顺序。
仿真和布局布线不能替代开发板及实际 TF 卡验收。

### 真实图片与独立参考对比

安装 Pillow、NumPy 后，在工程根目录执行（不会修改原图）：

```powershell
python tests/compare_scaling.py 'C:/path/PIC1.BMP' 'C:/path/scaling_comparison'
iverilog -g2012 -s tb_bmp_fit_file -o actual.vvp tests/tb_bmp_fit_file.sv rtl/image/bmp24_decoder.v rtl/image/bmp24_fit_decoder.v rtl/memory/media_frame_loader.v
vvp actual.vvp '+BMP=C:/path/PIC1.BMP' '+GOLDEN=C:/path/scaling_comparison/area.hex'
```

脚本生成最近邻 `nearest.png`、区域平均 `area.png`、左右对比 `comparison.png` 和显示顺序参考帧 `area.hex`。
参考使用 NumPy 独立求和，不调用 RTL 中的相位累加实现。
真实文件测试逐一检查 307200 个输出像素及 SDRAM 写入值，并模拟扇区传输、写忙和刷新暂停。
生成的用户图片及参考帧只保存在指定输出目录，不加入代码仓库。

### 命令行构建

也可在工程 `project` 目录运行 TD 的 `td_commands_prompt.exe ../tests/build_scaling_quality.tcl`。
输出在 `project/quality_build/`，包含 `.bit`、资源报告和最终时序报告；
脚本在布线后显式执行 `fix_hold`，最终仍需检查 `quality_pr.timing` 的建立和保持裕量。
该目录已加入 Git 忽略规则。

## 最近邻基线构建记录（2026-10-19，提交 defa687）

14 组小尺寸/边界尺寸测试、16 组实际 640×480 输出测试、9 组错误输入测试及文件流暂停测试全部通过。

TD 6.2.168116、EG4S20BG256 完成综合、布局布线和 bitgen。
LUT 15236/19600，寄存器 8593/19600，BRAM9K 14/64，DSP 22/29。
现有 SDC 下报告建立裕量 0.104 ns、保持裕量 0.014 ns，无已约束路径时序违例，
STA 覆盖率 99.98%。裕量较小，后续修改需重新检查时序。
原工程 SDC 中 `busy_sync1`、`commit_sync1` 两条例外仍报对象未匹配警告，
本次未调整其跨时钟约束，不能将上述报告视为完整的 CDC/板级时序验收。

下载用文件另存于桌面 `media_player_excellence_scaling.bit`，SHA-256：
`2E3FC2E9C4AB51DAE322AA2E390752C4B8CBB67700E6B852F8D05AF1D711D6BE`。

## 区域平均质量优化构建记录（2026-10-19）

最终 RTL（含块 RAM 输出 FIFO）通过 18 组区域平均边界测试、18 组最近邻回归。
1125×2436 的真实 24 位 BMP 适配为 221×480，307200 个输出像素及 SDRAM 写入
均与独立 NumPy 参考一致，包含黑边及底向上地址映射，并模拟扇区暂停、写忙和刷新。
9 组错误输入及 FAT32 文件流暂停测试也通过。
另有 20 组 640×480 输出算法测试全部通过，含 1920×1080、480×800、棋盘格和奇数尺寸。
这轮完整算法测试使用 FIFO 改造前的版本；最终 FIFO 版本由上述 18+18 组回归及真实图片测试覆盖。

TD 6.2.168116、EG4S20BG256 完成综合、布局布线、保持时间修复和 bitgen。
最终布局布线资源：LUT 14170/19600（72.30%），寄存器 8762/19600，
BRAM9K 29/64，DSP 23/29。
现有 SDC 下建立裕量 0.275 ns、保持裕量 0.030 ns，建立及保持总负裕量均为 0，
STA 覆盖率 99.98%。原有两条例外未匹配警告仍存在；尚未进行开发板实测。

下载文件另存于桌面 `media_player_excellence_quality.bit`（629648 字节），SHA-256：
`6D14B62AC16C3EFCE95D439902CEB962BB158B44D0DCD083407FE91A1C27A4E8`。
桌面 `scaling_quality_comparison.png` 是同一张输入图的独立参考效果图，左为最近邻、右为区域平均，
不是开发板屏幕截图。原有 `media_player_excellence_scaling.bit` 保留用于对比。

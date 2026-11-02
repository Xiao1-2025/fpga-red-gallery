"""Exact integer-bin reference and local comparison images; no source edits.

Usage: python tests/compare_scaling.py input.bmp output_directory
The .hex frame can also verify the RTL with tb_bmp_fit_file.sv.
"""
import argparse
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont


def resize_reference(rgb, output_width=640, output_height=480):
    sh, sw, _ = rgb.shape
    if sw * output_height >= sh * output_width:
        fw, fh = output_width, max(1, sh * output_width // sw)
    else:
        fw, fh = max(1, sw * output_height // sh), output_height
    xs = np.arange(fw, dtype=np.int64) * sw // fw
    ys = np.arange(fh, dtype=np.int64) * sh // fh
    nearest = rgb[ys[:, None], xs[None, :]]
    filtered = nearest
    if sw > fw or sh > fh:
        # Ceil boundaries match the hardware's integer bins. Every source
        # pixel contributes exactly once, and normalization rounds only once.
        xe = (np.arange(fw + 1, dtype=np.int64) * sw + fw - 1) // fw
        ye = (np.arange(fh + 1, dtype=np.int64) * sh + fh - 1) // fh
        sums = np.add.reduceat(rgb.astype(np.uint64), ye[:-1], axis=0)
        sums = np.add.reduceat(sums, xe[:-1], axis=1)
        counts = np.diff(ye)[:, None] * np.diff(xe)[None, :]
        counts = counts[:, :, None].astype(np.uint64)
        filtered = ((sums + counts // 2) // counts).astype(np.uint8)
    px, py = (output_width - fw) // 2, (output_height - fh) // 2
    frames = []
    for content in (nearest, filtered):
        frame = np.zeros((output_height, output_width, 3), dtype=np.uint8)
        frame[py:py + fh, px:px + fw] = content
        frames.append(frame)
    return frames, (fw, fh)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    with Image.open(args.input) as source:
        if source.format != "BMP":
            raise ValueError("Expected an actual BMP file, not a renamed JPEG")
        rgb = np.asarray(source.convert("RGB"))
    args.output.mkdir(parents=True, exist_ok=True)
    (nearest, filtered), fit = resize_reference(rgb)
    Image.fromarray(nearest).save(args.output / "nearest.png")
    Image.fromarray(filtered).save(args.output / "area.png")
    # Golden frame in display order, independent of BMP storage orientation.
    with (args.output / "area.hex").open("w", encoding="ascii") as output:
        for r, g, b in filtered.reshape(-1, 3):
            output.write(f"{r:02x}{g:02x}{b:02x}\n")
    comparison = Image.new("RGB", (1280, 530), "#eeeeee")
    comparison.paste(Image.fromarray(nearest), (0, 50))
    comparison.paste(Image.fromarray(filtered), (640, 50))
    draw = ImageDraw.Draw(comparison)
    try:
        font = ImageFont.truetype("arial.ttf", 19)
    except OSError:
        font = ImageFont.load_default()
    draw.text((20, 15), "Nearest neighbour (baseline)", fill="black", font=font)
    draw.text((660, 15), "Area average (FPGA reference)", fill="black", font=font)
    comparison.save(args.output / "comparison.png")
    print(f"Input {rgb.shape[1]}x{rgb.shape[0]}, fit {fit[0]}x{fit[1]}")
    print(f"Reference and comparison: {args.output.resolve()}")


if __name__ == "__main__":
    main()

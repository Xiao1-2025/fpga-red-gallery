from pathlib import Path

from PIL import Image, ImageDraw, ImageEnhance, ImageFont, ImageOps


ROOT = Path(__file__).resolve().parent
SOURCE_DIR = ROOT / "red_memory_sources"
OUTPUT_DIR = ROOT / "red_memory_tf"
CANVAS = (640, 480)

EXHIBITS = [
    ("01_red_boat.jpg", "PIC1.BMP", "星火初燃", "1921  嘉兴南湖"),
    ("02_jinggangshan.jpg", "PIC2.BMP", "井冈会师", "1928  井冈山龙江书院"),
    ("03_luding_bridge.jpg", "PIC3.BMP", "飞夺泸定桥", "1935  四川泸定"),
    ("04_founding.jpg", "PIC4.BMP", "山河新生", "1949  北平和平解放"),
]


def load_font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    windows_fonts = Path("C:/Windows/Fonts")
    names = ["msyhbd.ttc", "simhei.ttf"] if bold else ["msyh.ttc", "simsun.ttc"]
    for name in names:
        path = windows_fonts / name
        if path.exists():
            return ImageFont.truetype(str(path), size=size)
    return ImageFont.load_default()


def make_exhibit(source: Path, title: str, caption: str) -> Image.Image:
    with Image.open(source) as image:
        image = ImageOps.exif_transpose(image).convert("RGB")
        image = ImageEnhance.Contrast(image).enhance(1.05)
        image = ImageEnhance.Color(image).enhance(0.92)
        frame = ImageOps.fit(image, CANVAS, method=Image.Resampling.LANCZOS, centering=(0.5, 0.5))

    overlay = Image.new("RGBA", CANVAS, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    draw.rectangle((0, 0, 640, 88), fill=(30, 18, 16, 185))
    draw.rectangle((0, 0, 10, 88), fill=(178, 25, 28, 255))
    draw.rectangle((28, 78, 612, 80), fill=(211, 168, 76, 220))

    title_font = load_font(31, bold=True)
    caption_font = load_font(17)
    draw.text((30, 12), title, font=title_font, fill=(250, 244, 226, 255))
    draw.text((32, 55), caption, font=caption_font, fill=(229, 207, 151, 255))

    return Image.alpha_composite(frame.convert("RGBA"), overlay).convert("RGB")


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    previews = []
    for source_name, output_name, title, caption in EXHIBITS:
        result = make_exhibit(SOURCE_DIR / source_name, title, caption)
        result.save(OUTPUT_DIR / output_name, format="BMP", bits=24)
        previews.append(result.resize((320, 240), Image.Resampling.LANCZOS))

    sheet = Image.new("RGB", (640, 480), "black")
    for index, preview in enumerate(previews):
        sheet.paste(preview, ((index % 2) * 320, (index // 2) * 240))
    sheet.save(OUTPUT_DIR / "preview.png")


if __name__ == "__main__":
    main()

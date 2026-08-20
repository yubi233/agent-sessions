#!/usr/bin/env python3
"""Render a redacted real-agent transcript into a portrait MP4 source sequence."""
from pathlib import Path
import re
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
REPORT_ROOT = ROOT / "e2e-verify" / "reports"
SCREENCAST_ROOT = ROOT / "e2e-verify" / "screencasts"
FPS = 5
FRAME_COUNT = 100
WIDTH, HEIGHT = 1080, 1920
FONT_PATH = "/System/Library/Fonts/STHeiti Medium.ttc"


def font(size: int):
    return ImageFont.truetype(FONT_PATH, size=size)


def clean(value: str) -> str:
    value = re.sub(r"(bearer\s+)[^\s\"']+", r"\1[REDACTED]", value, flags=re.I)
    value = re.sub(r"((?:api[_-]?key|token|password|secret)\s*[:=]\s*)[^\s,}\"']+", r"\1[REDACTED]", value, flags=re.I)
    value = re.sub(r"/(?:Users|private|var|tmp)/[^\s\"']+", "[PATH REDACTED]", value)
    return re.sub(r"\s+", " ", value).strip()[:520]


def wrap(draw, text, typeface, max_width):
    lines, current = [], ""
    for char in text:
        candidate = current + char
        if current and draw.textbbox((0, 0), candidate, font=typeface)[2] > max_width:
            lines.append(current)
            current = char
        else:
            current = candidate
    if current:
        lines.append(current)
    return lines


def card(draw, box, label, body, accent):
    x1, y1, x2, y2 = box
    draw.rounded_rectangle(box, radius=28, fill="#172554", outline=accent, width=3)
    draw.text((x1 + 34, y1 + 28), label, font=font(30), fill=accent)
    body_font = font(38)
    y = y1 + 92
    for line in wrap(draw, body, body_font, x2 - x1 - 68):
        draw.text((x1 + 34, y), line, font=body_font, fill="#F8FAFC")
        y += 58


def main():
    input_path = Path(sys.argv[1]) if len(sys.argv) > 1 else REPORT_ROOT / "REAL" / "real-agent-dialog.txt"
    output_dir = Path(sys.argv[2]) if len(sys.argv) > 2 else SCREENCAST_ROOT / "REAL" / "real-agent-dialog"
    input_path = input_path.resolve()
    output_dir = output_dir.resolve()
    if REPORT_ROOT not in input_path.parents or SCREENCAST_ROOT not in output_dir.parents:
        raise SystemExit("真实对话事件流必须在 e2e-verify/reports，视频必须在 e2e-verify/screencasts。")
    output_dir.mkdir(parents=True, exist_ok=True)
    assistant = clean(input_path.read_text(encoding="utf-8"))
    if not assistant:
        raise SystemExit("真实 Agent 输出为空。")
    frames = output_dir / "frames"
    frames.mkdir(exist_ok=True)
    title_font = font(58)
    subtitle_font = font(30)
    for index in range(1, FRAME_COUNT + 1):
        seconds = (index - 1) / FPS
        image = Image.new("RGB", (WIDTH, HEIGHT), "#0F172A")
        draw = ImageDraw.Draw(image)
        draw.text((70, 150), "真实 Agent 对话演示", font=title_font, fill="#F8FAFC")
        draw.text((70, 245), "OpenCode Go / deepseek-v4-flash", font=subtitle_font, fill="#94A3B8")
        if seconds >= 4:
            card(draw, (60, 510, 1020, 830), "用户", "请说明移动端如何创建会话、发送任务、处理权限请求并结束会话。", "#CBD5E1")
        if seconds >= 8:
            card(draw, (60, 930, 1020, 1470), "真实 Agent", assistant, "#93C5FD")
        draw.text((70, 1770), "真实 Provider 输出；未混入 Flutter fixture", font=subtitle_font, fill="#94A3B8")
        image.save(frames / f"frame-{index:04d}.png")
    output = output_dir / "real-agent-dialog.mp4"
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-framerate", str(FPS), "-i", str(frames / "frame-%04d.png"),
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
        "-y", str(output),
    ], check=True)
    print(f"{{\"output\": \"{output}\", \"fps\": {FPS}, \"frames\": {FRAME_COUNT}, \"source\": \"real_model\"}}")


if __name__ == "__main__":
    main()

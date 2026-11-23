"""Render demo-video.mp4 from REAL captured terminal output
(demo/demo_output.txt + forge test output). No fake footage: every frame
is the actual text of runs executed in this repo."""
import subprocess
import textwrap
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
FRAMES = ROOT / "demo" / "frames"
FRAMES.mkdir(exist_ok=True)
W, H = 1280, 720
BG = (13, 17, 23)
FG = (201, 209, 217)
ACCENT = (88, 166, 255)
GREEN = (63, 185, 80)
FONT = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 17)
FONT_BIG = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 44)
FONT_MED = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 24)

frame_no = 0


def save(img: Image.Image, seconds: float) -> None:
    global frame_no
    # duplicate frame to reach duration at 2 fps
    for _ in range(max(1, round(seconds * 2))):
        img.save(FRAMES / f"f{frame_no:05d}.png")
        frame_no += 1


def card(title: str, lines: list[str], seconds: float) -> None:
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    d.text((80, 200), title, font=FONT_BIG, fill=ACCENT)
    y = 290
    for line in lines:
        d.text((80, y), line, font=FONT_MED, fill=FG)
        y += 40
    save(img, seconds)


def terminal(lines: list[str], header: str, per_line: float) -> None:
    shown: list[str] = []
    for line in lines:
        for wrapped in textwrap.wrap(line, 108) or [""]:
            shown.append(wrapped)
        img = Image.new("RGB", (W, H), BG)
        d = ImageDraw.Draw(img)
        d.rectangle([0, 0, W, 46], fill=(22, 27, 34))
        d.text((20, 12), header, font=FONT, fill=ACCENT)
        y = 60
        for l in shown[-30:]:
            color = GREEN if ("✓" in l or "PASS" in l) else FG
            d.text((20, y), l, font=FONT, fill=color)
            y += 21
        save(img, per_line)


def main() -> None:
    card("Agent-to-Agent Settlement on HSK Chain",
         ["HSK Chain Horizon Hackathon · Seoul — Track 2:",
          "Agent Payments & A2A Settlement (HSP)",
          "",
          "Buyer AI agent hires a worker AI agent under an HSP-style",
          "payment mandate, escrowed on-chain, paid on verifiable delivery.",
          "",
          "Emilio Tecnologías — demo rendered from real terminal output"],
         6)

    tests = subprocess.run(
        ["bash", "-c", 'export PATH="$HOME/.foundry/bin:$PATH"; forge test 2>&1 | grep -E "PASS|FAIL|Suite|Ran"'],
        cwd=ROOT, capture_output=True, text=True).stdout.strip().splitlines()
    terminal(["$ forge test"] + tests, "AgentEscrow.sol — Foundry test suite", 0.55)
    save(Image.new("RGB", (W, H), BG), 0.5)

    demo_lines = (ROOT / "demo" / "demo_output.txt").read_text().strip().splitlines()
    # keep the human-readable part; shorten the raw JSONL tail
    cut = next(i for i, l in enumerate(demo_lines) if l.startswith('{"ts"'))
    demo_lines = demo_lines[:cut] + ["(audit log entries written to demo/settlement_log.jsonl)"]
    terminal(["$ bash demo/run_demo.sh"] + demo_lines,
             "Local anvil end-to-end: deploy → mandate → delivery → verify → pay", 1.15)

    card("Settlement complete ✓",
         ["Mandate created → worker delivered → hash verified → 0.05 HSK paid",
          "Over-cap mandate (5 HSK) rejected by contract spend caps ✓",
          "",
          "github.com/emiliotecnologias/hsk-horizon-agent-settlement",
          "Deploy scripts ready for HSK testnet (133) / mainnet (177)"],
         6)

    out = ROOT / "demo-video.mp4"
    subprocess.run(
        ["ffmpeg", "-y", "-framerate", "2", "-i", str(FRAMES / "f%05d.png"),
         "-c:v", "libx264", "-pix_fmt", "yuv420p", "-r", "30", str(out)],
        check=True, capture_output=True)
    dur = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "csv=p=0", str(out)], capture_output=True, text=True).stdout.strip()
    print(f"video: {out} duration={float(dur):.1f}s frames={frame_no}")


if __name__ == "__main__":
    main()

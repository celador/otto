# /// script
# dependencies = ["pillow"]
# ///
"""Captioned 6.9" App Store screenshots (1320x2868) from raw simulator captures.

uv run scripts/store_shots.py   -> ~/.hermes/cache/scratch/final-*.png + final-sheet.png
"""
import pathlib

from PIL import Image, ImageDraw, ImageFont

S = pathlib.Path.home() / ".hermes/cache/scratch"
W, H = 1320, 2868
BG = (0, 0, 0)
FG = (245, 245, 245)
MUTED = (142, 142, 147)
FONT = "/System/Library/Fonts/SFNS.ttf"


def font(size, weight=700):
    f = ImageFont.truetype(FONT, size)
    # axes: Width, Optical Size, GRAD, Weight
    f.set_variation_by_axes([100, 96 if size > 90 else 28, 400, weight])
    return f


def rounded(im, r):
    m = Image.new("L", im.size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, im.width - 1, im.height - 1], r, fill=255)
    out = Image.new("RGBA", im.size)
    out.paste(im, (0, 0), m)
    return out


def headline(d, line1, line2, y=170):
    f = font(118)
    for text, color in ((line1, FG), (line2, MUTED)):
        if not text:
            continue
        w = d.textlength(text, font=f)
        d.text(((W - w) / 2, y), text, font=f, fill=color)
        y += 140
    return y


def phone_shot(raw, line1, line2, out):
    c = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(c)
    y = headline(d, line1, line2) + 70
    shot = Image.open(S / raw).convert("RGB")
    sw = int(W * 0.84)
    sh = int(shot.height * sw / shot.width)
    shot = rounded(shot.resize((sw, sh), Image.Resampling.LANCZOS), 90)
    # thin bezel
    bez = Image.new("RGBA", (sw + 16, sh + 16), (0, 0, 0, 0))
    ImageDraw.Draw(bez).rounded_rectangle([0, 0, sw + 15, sh + 15], 98, fill=(58, 58, 60))
    bx = (W - bez.width) // 2
    c.paste(bez, (bx, y), bez)
    c.paste(shot, (bx + 8, y + 8), shot)
    c.save(S / out)


def watch_shot(raw, line1, line2, out):
    c = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(c)
    y = headline(d, line1, line2, y=260) + 330
    shot = Image.open(S / raw).convert("RGB")
    sw = 760
    sh = int(shot.height * sw / shot.width)
    shot = rounded(shot.resize((sw, sh), Image.Resampling.LANCZOS), 150)
    case = Image.new("RGBA", (sw + 120, sh + 120), (0, 0, 0, 0))
    cd = ImageDraw.Draw(case)
    cd.rounded_rectangle([0, 0, sw + 119, sh + 119], 210, fill=(44, 44, 46))
    cd.rounded_rectangle([20, 20, sw + 99, sh + 99], 190, fill=(10, 10, 10))
    x = (W - case.width) // 2
    # band
    d.rounded_rectangle([x + 130, y - 170, x + case.width - 130, y + case.height + 170], 60, fill=(28, 28, 30))
    c.paste(case, (x, y), case)
    c.paste(shot, (x + 60, y + 60), shot)
    # crown
    d.rounded_rectangle([x + case.width - 6, y + 230, x + case.width + 34, y + 400], 18, fill=(70, 70, 72))
    sub = font(54, 500)
    t = "Tap once. Speak. Hear the answer."
    d.text(((W - d.textlength(t, font=sub)) / 2, H - 330), t, font=sub, fill=MUTED)
    c.save(S / out)


def privacy_shot(out):
    c = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(c)
    headline(d, "Private", "by design.", y=330)
    big, small = font(300), font(64, 500)
    rows = [("0", "accounts"), ("0", "trackers"), ("0", "bytes collected")]
    y = 900
    for n, label in rows:
        w = d.textlength(n, font=big)
        d.text(((W - w) / 2, y), n, font=big, fill=FG)
        lw = d.textlength(label, font=small)
        d.text(((W - lw) / 2, y + 330), label, font=small, fill=MUTED)
        y += 520
    note = font(52, 500)
    for i, t in enumerate(["Talks only to the agent server", "you run. Nothing in between."]):
        d.text(((W - d.textlength(t, font=note)) / 2, H - 360 + i * 70), t, font=note, fill=MUTED)
    c.save(S / out)


PLAN = [
    ("phone", "store-chat.png", "Your agent.", "In your pocket.", "final-1.png"),
    ("watch", "h-watch.png", "Talk to it.", "From your wrist.", "final-2.png"),
    ("phone", "store-voice.png", "Just say it.", "Hear it back.", "final-3.png"),
    ("phone", "store-board.png", "Your board,", "anywhere.", "final-4.png"),
    ("phone", "raw-agents.png", "Every agent,", "one tap away.", "final-5.png"),
    ("phone", "store-connect.png", "Connect", "in seconds.", "final-6.png"),
    ("privacy", None, None, None, "final-7.png"),
]

IPAD_W, IPAD_H = 2064, 2752
IPAD_PLAN = [
    ("ipadraw-chat.png", "Your agent.", "On the big screen.", "ipad-final-1.png"),
    ("ipadraw-voice.png", "Just say it.", "Hear it back.", "ipad-final-2.png"),
    ("ipadraw-board.png", "Your board,", "anywhere.", "ipad-final-3.png"),
    ("ipadraw-agents.png", "Every agent,", "one tap away.", "ipad-final-4.png"),
]


def ipad_shot(raw, line1, line2, out):
    c = Image.new("RGB", (IPAD_W, IPAD_H), BG)
    d = ImageDraw.Draw(c)
    f = font(130)
    y = 150
    for text, color in ((line1, FG), (line2, MUTED)):
        d.text(((IPAD_W - d.textlength(text, font=f)) / 2, y), text, font=f, fill=color)
        y += 155
    y += 70
    shot = Image.open(S / raw).convert("RGB")
    sh = IPAD_H - y - 40
    sw = int(shot.width * sh / shot.height)
    shot = rounded(shot.resize((sw, sh), Image.Resampling.LANCZOS), 60)
    bez = Image.new("RGBA", (sw + 20, sh + 20), (0, 0, 0, 0))
    ImageDraw.Draw(bez).rounded_rectangle([0, 0, sw + 19, sh + 19], 70, fill=(58, 58, 60))
    bx = (IPAD_W - bez.width) // 2
    c.paste(bez, (bx, y), bez)
    c.paste(shot, (bx + 10, y + 10), shot)
    c.save(S / out)


def ipad_privacy(out):
    c = Image.new("RGB", (IPAD_W, IPAD_H), BG)
    d = ImageDraw.Draw(c)
    f = font(150)
    for i, (t, col) in enumerate((("Private", FG), ("by design.", MUTED))):
        d.text(((IPAD_W - d.textlength(t, font=f)) / 2, 380 + i * 180), t, font=f, fill=col)
    big, small = font(320), font(70, 500)
    for i, label in enumerate(["accounts", "trackers", "bytes collected"]):
        cx = IPAD_W * (i + 1) / 4
        d.text((cx - d.textlength("0", font=big) / 2, 1150), "0", font=big, fill=FG)
        d.text((cx - d.textlength(label, font=small) / 2, 1520), label, font=small, fill=MUTED)
    note = font(60, 500)
    t = "Talks only to the agent server you run. Nothing in between."
    d.text(((IPAD_W - d.textlength(t, font=note)) / 2, 2200), t, font=note, fill=MUTED)
    c.save(S / out)


if __name__ == "__main__":
    for raw, l1, l2, out in IPAD_PLAN:
        ipad_shot(raw, l1, l2, out)
    ipad_privacy("ipad-final-5.png")
    ims = [Image.open(S / f"ipad-final-{i}.png").resize((516, 688)) for i in range(1, 6)]
    sheet = Image.new("RGB", (526 * 5, 688), (255, 255, 255))
    for i, im in enumerate(ims):
        sheet.paste(im, (i * 526, 0))
    sheet.save(S / "ipad-final-sheet.png")

    for kind, raw, l1, l2, out in PLAN:
        {"phone": lambda: phone_shot(raw, l1, l2, out), "watch": lambda: watch_shot(raw, l1, l2, out),
         "privacy": lambda: privacy_shot(out)}[kind]()
    ims = [Image.open(S / p[-1]).resize((330, 717)) for p in PLAN]
    sheet = Image.new("RGB", (340 * len(ims), 717), (255, 255, 255))
    for i, im in enumerate(ims):
        sheet.paste(im, (i * 340, 0))
    sheet.save(S / "final-sheet.png")
    print("ok", len(ims))

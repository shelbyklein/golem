#!/usr/bin/env python3
"""Turns Golem's transparent animations into the avatar Chatterbox plays.

Each source (a transparent WebM, or a folder of PNG frames) becomes
<state>.mov in the avatar folder: HEVC with alpha, which macOS and iOS play
natively, on a shared 512x512 stage. Golem's base stone (his head) lands at the
same size and spot in every one, measured from the resting first frame, so
switching from idle to thinking doesn't make him jump. The head image for the
sidebar is copied as head.png.

  scripts/make-golem-avatar.py                      # the usual sources
  scripts/make-golem-avatar.py thinking=path.webm   # one state from a file

Needs ffmpeg (Homebrew). The avatar folder is ~/Chatterbox/Dot/Avatar, where
Chatterbox looks; any <state>.mov dropped there is picked up.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HOME = os.path.expanduser("~")
SOURCE = os.path.join(HOME, "Vibes/sandbox/output/golem")
AVATAR = os.path.join(HOME, "Chatterbox/Dot/Avatar")
DEFAULTS = {
    "idle": os.path.join(SOURCE, "idle/golem_idle_alpha.webm"),
    "thinking": os.path.join(SOURCE, "idle/golem_thinking_alpha.webm"),
}
HEAD = os.path.join(SOURCE, "parts/head.png")

STAGE = 512
# On the stage, in head widths: the stage is 2.7 heads wide, and the head's
# bottom sits 85% of the way down (room above for stacked or floating stones).
STAGE_IN_HEADS = 2.7
HEAD_BOTTOM = 0.85


def run(args, **kw):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kw)


def decoder(path):
    # libvpx keeps a VP9 WebM's alpha; ffmpeg's own decoder drops it.
    return ["-c:v", "libvpx-vp9"] if path.endswith(".webm") else []


def source_input(path):
    """ffmpeg input arguments for a WebM, a video, or a folder of PNG frames."""
    if os.path.isdir(path):
        frames = sorted(f for f in os.listdir(path) if f.endswith(".png"))
        if not frames:
            sys.exit(f"No PNG frames in {path}")
        pattern = re.sub(r"\d+(?=\.png$)", lambda m: f"%0{len(m.group())}d", frames[0])
        return ["-framerate", "24", "-i", os.path.join(path, pattern)]
    return decoder(path) + ["-i", path]


def first_frame_box(path):
    """The opaque part of the first frame (the shadow is too faint to count):
    at rest, that's the cairn, as wide as its widest stone, the head."""
    out = subprocess.run(["ffmpeg", "-hide_banner", *source_input(path), "-frames:v", "1",
                          "-vf", "alphaextract,bbox=min_val=128", "-f", "null", "-"],
                         capture_output=True, text=True).stderr
    m = re.search(r"x1:(\d+) x2:(\d+) y1:(\d+) y2:(\d+)", out)
    if not m:
        sys.exit(f"Couldn't find Golem in the first frame of {path} (is it transparent?)")
    return tuple(int(v) for v in m.groups())


def convert(state, path, out_dir):
    x1, x2, y1, y2 = first_frame_box(path)
    head = x2 - x1
    side = round(head * STAGE_IN_HEADS)
    left = round((x1 + x2) / 2 - side / 2)
    top = round(y2 - side * HEAD_BOTTOM)
    # Pad generously first so the stage can reach past the source's edges.
    margin = side
    crop = f"pad=iw+{2 * margin}:ih+{2 * margin}:{margin}:{margin}:color=black@0," \
           f"crop={side}:{side}:{left + margin}:{top + margin},scale={STAGE}:{STAGE}:flags=lanczos,format=bgra"
    target = os.path.join(out_dir, f"{state}.mov")
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *source_input(path), "-vf", crop,
         "-c:v", "hevc_videotoolbox", "-alpha_quality", "0.9", "-q:v", "70", "-tag:v", "hvc1",
         "-an", target])
    return {"state": state, "source": path, "head_px": head, "file": os.path.basename(target)}


def main():
    sources = dict(DEFAULTS)
    for arg in sys.argv[1:]:
        state, _, path = arg.partition("=")
        if not path:
            sys.exit(f"Use state=path, not {arg!r}")
        sources[state] = os.path.expanduser(path)
    os.makedirs(AVATAR, exist_ok=True)
    made = []
    # Write into a scratch folder and move into place, so Chatterbox never plays a half-written file.
    with tempfile.TemporaryDirectory() as scratch:
        for state, path in sources.items():
            if not os.path.exists(path):
                print(f"skip {state}: {path} not found")
                continue
            info = convert(state, path, scratch)
            shutil.move(os.path.join(scratch, info["file"]), os.path.join(AVATAR, info["file"]))
            made.append(info)
            print(f"{state}: {info['file']} (head {info['head_px']}px in the source)")
    if os.path.exists(HEAD):
        shutil.copyfile(HEAD, os.path.join(AVATAR, "head.png"))
        print("head.png")
    with open(os.path.join(AVATAR, "made.json"), "w") as f:
        json.dump(made, f, indent=2)


if __name__ == "__main__":
    main()

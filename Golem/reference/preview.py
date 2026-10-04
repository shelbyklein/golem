"""Render golem.json through the reference Player: a mood script → GIF/MP4 + contact sheet.
  python preview.py                      # the showreel
  python preview.py idle:0 waiting:2     # custom mood script (mood:start_seconds), ends 4 s after the last"""
import math, os, subprocess, sys, shutil
from PIL import Image
import numpy as np
from golem_rig import Rig, Player

HERE = os.path.dirname(os.path.abspath(__file__))
RIG_DIR = os.path.join(HERE, '..', 'rig')
rig = Rig(os.path.join(RIG_DIR, 'golem.json'))
SIDE = 520                      # output px
FPS = 24
BG = (247, 244, 238)
stage = rig.spec['stage']
UNIT = SIDE / stage['size']     # output px per rig px
GROUND = SIDE * stage['groundFromTop']
PS = rig.spec['pixelScale']
IMG = {n: Image.open(os.path.join(RIG_DIR, s['image'])).convert('RGBA') for n, s in rig.stones.items()}
EYES = [(Image.open(os.path.join(RIG_DIR, e['image'])).convert('RGBA'), e) for e in rig.spec['eyes']['sprites']]


def head_image(frame):
    head = IMG['head'].copy()
    for img, e in EYES:
        sy = max(.08, 1 - frame.blink * .95)
        eye = img.resize((img.width, max(1, round(img.height * sy))), Image.LANCZOS)
        head.alpha_composite(eye, (round((e['x'] + frame.eye_x) * PS - eye.width / 2),
                                   round((e['y'] + frame.eye_y + frame.blink * 4) * PS - eye.height / 2)))
    return head


def draw(frame):
    canvas = Image.new('RGBA', (SIDE, SIDE), (0, 0, 0, 0))
    for name, s in sorted(frame.stones.items(), key=lambda kv: -kv[1].depth):
        img = head_image(frame) if name == 'head' else IMG[name]
        k = UNIT / PS * s.scale
        w = max(1, round(img.width * k * (1 + s.squash * .6))); h = max(1, round(img.height * k * (1 - s.squash)))
        img = img.resize((w, h), Image.LANCZOS)
        if s.shade > 0:
            a = np.asarray(img).astype(np.float32); a[..., :3] *= (1 - s.shade); img = Image.fromarray(a.astype(np.uint8))
        cy = s.y - rig.h(name) * s.scale * s.squash / 2          # squash keeps the bottom put
        if s.rot: img = img.rotate(s.rot, Image.BICUBIC, expand=True)
        canvas.alpha_composite(img, (round(SIDE / 2 + s.x * UNIT - img.width / 2), round(GROUND - cy * UNIT - img.height / 2)))
    return canvas


def run(script, name):
    end = script[-1][1] + 4.0
    player = Player(rig, script[0][0]); events = list(script[1:])
    out = os.path.join(HERE, 'preview', name); shutil.rmtree(out, ignore_errors=True); os.makedirs(out)
    frames = []
    for i in range(int(end * FPS)):
        t = i / FPS
        while events and events[0][1] <= t:
            player.set_mood(events.pop(0)[0], t)
        f = draw(player.frame(t))
        f.save(f'{out}/f_{i:04d}.png'); frames.append(f)
    flat = os.path.join(HERE, 'preview', f'{name}.mp4')
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-framerate', str(FPS), '-i', f'{out}/f_%04d.png', '-vf',
                    f'color=c=0x{BG[0]:02x}{BG[1]:02x}{BG[2]:02x}:s={SIDE}x{SIDE}[bg];[bg][0]overlay=shortest=1',
                    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '18', flat], check=True)
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', flat, '-vf',
                    'fps=20,scale=360:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=180[p];[b][p]paletteuse=dither=bayer:bayer_scale=4',
                    os.path.join(HERE, 'preview', f'{name}.gif')], check=True)
    return frames


def sheet(frames, times, path, cols=6):
    cells = [frames[min(len(frames) - 1, int(t * FPS))] for t in times]
    rows = math.ceil(len(cells) / cols); s = SIDE // 2
    img = Image.new('RGB', (cols * s, rows * s), BG)
    for i, c in enumerate(cells):
        img.paste(Image.alpha_composite(Image.new('RGBA', c.size, BG + (255,)), c).convert('RGB').resize((s, s)), ((i % cols) * s, (i // cols) * s))
    img.save(path)


if __name__ == '__main__':
    if len(sys.argv) > 1:
        script = [(a.split(':')[0], float(a.split(':')[1])) for a in sys.argv[1:]]; name = 'custom'
    else:
        script = [('idle', 0), ('waiting', 3), ('idle', 8), ('thinking', 11), ('idle', 17), ('news', 20), ('idle', 25)]
        name = 'showreel'
    fr = run(script, name)
    times = [x / 2 for x in range(0, int(len(fr) / FPS * 2))]
    sheet(fr, times, os.path.join(HERE, 'preview', f'{name}-sheet.png'), cols=8)
    print('PREVIEW', name, len(fr), 'frames')

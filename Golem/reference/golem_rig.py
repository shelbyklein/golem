"""Golem rig — reference evaluator for golem.json (Swift's GolemRig mirrors this line for line).

Rig px: y up from the ground, x from the centre line; angles CCW-positive degrees; seconds.
A Frame is {stone: StoneState} plus eye offsets and blink, ready to draw back-to-front by depth."""
import json, math
from dataclasses import dataclass, replace

TAU = math.pi * 2


# ------------------------------------------------------------------ helpers
def clamp01(u): return min(1.0, max(0.0, u))
def smooth(u): u = clamp01(u); return u * u * (3 - 2 * u)
def smoother(u): u = clamp01(u); return u * u * u * (u * (6 * u - 15) + 10)
def out_back(u, k=1.9):
    u = clamp01(u) - 1
    return 1 + u * u * ((k + 1) * u + k)
def lerp(a, b, m): return a + (b - a) * m
def pulse(t, at, dur):
    u = (t - at) / dur
    return math.sin(math.pi * u) ** 2 if 0 <= u <= 1 else 0.0
def window(t, a, b, ramp): return smooth((t - a) / ramp) * (1 - smooth((t - (b - ramp)) / ramp))
def hash01(n, salt):
    """deterministic 0..1 noise per integer n, identical in Swift"""
    v = math.sin(n * 12.9898 + salt * 78.233) * 43758.5453
    return v - math.floor(v)


@dataclass
class StoneState:
    x: float
    y: float
    rot: float = 0.0          # degrees, CCW positive
    scale: float = 1.0
    squash: float = 0.0       # + flatter (bottom stays put), - stretched
    depth: float = 0.0        # + farther away (drawn first)
    shade: float = 0.0        # 0..1 darkening


@dataclass
class Frame:
    stones: dict
    eye_x: float = 0.0
    eye_y: float = 0.0
    blink: float = 0.0


class Rig:
    def __init__(self, path):
        self.spec = json.load(open(path))
        self.stones = self.spec['stones']
        self.poses = self.spec['poses']
        self.nest_k = self.spec['nest']['k']; self.nest_c = self.spec['nest']['c']

    def h(self, s): return self.stones[s]['h']
    def nest(self, lower, upper): return self.nest_k * min(self.h(lower), self.h(upper)) + self.nest_c

    # -------------------------------------------------------------- poses
    def stack_lean(self, sw, f, t):
        ph = TAU * t / sw['period']
        return (sw['tip'] * math.sin(ph + sw.get('tipPhase', 0))
                + sw['bend'] * f ** sw['bendExp'] * math.sin(ph - sw['lag'] * f)
                + sw.get('catch', 0) * f * f * math.sin(2 * ph - sw.get('catchLag', 0) * f + sw.get('catchPhase', 0)))

    def eval_stack(self, st, t, out):
        sw = st['sway']; order = st['order']
        total = sum(self.h(n) for n, _ in order)
        base_ang = self.stack_lean(sw, 0, t)
        top_x = math.radians(base_ang) * self.h(order[0][0]) / 2 if sw.get('roll') else 0.0
        top_y = st.get('lift', 0.0)
        acc, prev = 0.0, None
        for i, (name, dx) in enumerate(order):
            hh = self.h(name)
            ang = self.stack_lean(sw, (acc + hh / 2) / total, t)
            a = math.radians(ang)
            n = self.nest(prev, name) if prev else 0.0
            cx = top_x + math.sin(a) * (hh / 2 - n) + dx * math.cos(a)
            cy = top_y + math.cos(a) * (hh / 2 - n)
            top_x, top_y = cx + math.sin(a) * hh / 2, cy + math.cos(a) * hh / 2
            out[name] = StoneState(cx, cy, -ang, depth=-0.01 * i)
            prev = name; acc += hh
        hs = st.get('headSwing')
        if hs and 'head' in out:
            out['head'].rot -= hs['amp'] * math.sin(TAU * t / sw['period'] - hs['phase'])
        br = st.get('breath')
        if br:
            for name, _ in order:
                s = out[name]; f = s.y / top_y
                s.y += br['amp'] * f * (0.5 - 0.5 * math.cos(TAU * t / br['period'] - br['lag'] * f))

    def eval_float(self, fl, t, out):
        for name, p in fl.items():
            s = StoneState(p['x'], p['y'], p.get('rot', 0.0), depth=-0.05)
            bob = p.get('bob')
            if bob:
                ph = bob.get('phase', 0.0)
                s.y += bob.get('y', 0) * math.sin(TAU * t / bob['period'] + ph)
                s.rot += bob.get('rot', 0) * math.sin(TAU * t / bob.get('rotPeriod', bob['period']) + ph)
            pu = p.get('pulse')
            if pu:
                v = max(0.0, math.sin(TAU * t / pu['period'] + pu.get('phase', 0.0)))
                s.scale = 1 + pu['scale'] * v * v
            out[name] = s

    def eval_ring(self, rg, t, out):
        c = out[rg['around']]
        n = len(rg['slots'])
        for i, name in enumerate(rg['slots']):
            a = i * TAU / n + TAU * t / rg['period']
            d = math.sin(a)
            out[name] = StoneState(c.x + rg['rx'] * math.cos(a), c.y + rg['cy'] + rg['ry'] * d,
                                   rg.get('rock', 0) * math.sin(a + 0.5), scale=1 - rg['depthScale'] * d,
                                   depth=d, shade=rg.get('shade', 0) * max(0.0, d))

    def pose_eyes(self, pose, t, stones):
        e = pose.get('eyes', {}); gx = gy = 0.0
        if 'look' in e: gx += e['look'][0]; gy += e['look'][1]
        if 'followRing' in e and 'ring' in pose:
            rg = pose['ring']; c = stones[rg['around']]
            front = min(rg['slots'], key=lambda s: stones[s].depth)
            gx += e['followRing'] * max(-1.0, min(1.0, (stones[front].x - c.x) / rg['rx']))
        if 'swayFollow' in e and 'stack' in pose:
            sf = e['swayFollow']; v = math.sin(TAU * t / pose['stack']['sway']['period'] - sf['lag'])
            gx += sf['x'] * v; gy += sf['y'] * abs(v)
        if e.get('glances'):
            g = self.spec['eyes']['glance']; n0 = math.floor(t / g['interval'])
            for n in (n0 - 1, n0):
                tg = n * g['interval'] + hash01(n, 3) * g['jitter']
                w = window(t, tg, tg + g['hold'], g['ramp'])
                side = -1 if hash01(n, 4) < 0.5 else 1
                gx += side * g['x'] * w; gy += g['y'] * w
        return gx, gy

    def blink(self, t):
        b = self.spec['eyes']['blink']; n0 = math.floor(t / b['interval']); v = 0.0
        for n in (n0 - 1, n0):
            tb = n * b['interval'] + hash01(n, 1) * b['jitter']
            v = max(v, pulse(t, tb, b['duration']))
            if hash01(n, 2) < b['doubleChance']:
                v = max(v, pulse(t, tb + b['doubleGap'], b['duration']))
        return v

    def eval_pose(self, name, t):
        pose = self.poses[name]; out = {}
        if 'stack' in pose: self.eval_stack(pose['stack'], t, out)
        if 'float' in pose: self.eval_float(pose['float'], t, out)
        if 'ring' in pose: self.eval_ring(pose['ring'], t, out)
        gx, gy = self.pose_eyes(pose, t, out)
        return Frame(out, gx, gy, self.blink(t))

    def transition_spec(self, a, b):
        d = dict(self.spec['transitions']['default'])
        d.update(self.spec['transitions'].get(f'{a}>{b}', {}))
        return d


class Transition:
    """Any pose (or a frozen snapshot) → any pose, driven by a transition spec."""

    def __init__(self, rig, a, b, t0, spec, snapshot=None):
        self.rig, self.a, self.b, self.t0, self.spec = rig, a, b, t0, spec
        self.snapshot = snapshot            # Frame, when interrupting mid-move
        A = self.from_frame(t0); B = rig.eval_pose(b, t0)
        names = list(B.stones)
        self.depart_rank = {s: i for i, s in enumerate(sorted(names, key=lambda s: -A.stones[s].y))}
        self.arrive_rank = {s: i for i, s in enumerate(sorted(names, key=lambda s: B.stones[s].y))}
        self.a_rank = {s: i for i, s in enumerate(sorted(names, key=lambda s: A.stones[s].y))}
        self.base = min(names, key=lambda s: A.stones[s].y - rig.h(s) / 2)
        self.dist = {s: math.hypot(B.stones[s].x - A.stones[s].x, B.stones[s].y - A.stones[s].y) for s in names}
        self.side = {}
        for s in names:
            dx = B.stones[s].x - A.stones[s].x
            alternate = 1 if self.depart_rank[s] % 2 else -1
            self.side[s] = alternate if spec.get('sides') == 'alternate' or abs(dx) <= 40 else (1 if dx > 0 else -1)
        sp = spec; self.sched = {}
        for s in names:
            lead = sp.get('lead')
            if lead and lead['stone'] == s:
                self.sched[s] = (lead['start'], lead['duration'], lead['ease'])
            elif sp['mode'] == 'launch':
                self.sched[s] = (sp['antic'] + sp['hold'] + self.arrive_rank[s] * sp['arriveGap'], sp['fallIn'], 'smoother')
            else:
                dep = sp['antic'] + self.depart_rank[s] * sp['departGap']
                end = sp['antic'] + sp['arriveStart'] + self.arrive_rank[s] * sp['arriveGap'] + sp['fly']
                self.sched[s] = (dep, max(0.45, end - dep), 'smoother')
        self.duration = max(st + du for st, du, _ in self.sched.values()) + sp['land']['duration']
        self.stack_above = []
        if not snapshot and 'stack' in rig.poses[a]:
            self.stack_above = [n for n, _ in rig.poses[a]['stack']['order']][1:]

    def from_frame(self, t):
        return self.snapshot if self.snapshot else self.rig.eval_pose(self.a, t)

    def squash_at(self, tau):
        sp = self.spec
        if sp['antic'] <= 0: return 0.0
        return sp['squash'] * smooth(tau / sp['antic']) * (1 - smooth((tau - sp['antic']) / 0.06))

    def done(self, t): return t - self.t0 >= self.duration

    def frame(self, t):
        rig, sp = self.rig, self.spec
        tau = t - self.t0
        A = self.from_frame(t); B = rig.eval_pose(self.b, t)
        out = {}
        for s, b in B.stones.items():
            a = replace(A.stones[s])
            # anticipation: the base squashes; the stack above sinks with it, each a beat later
            if sp['antic'] > 0 and not self.snapshot:
                if s == self.base:
                    a.squash += self.squash_at(tau)
                elif s in self.stack_above:
                    i = self.stack_above.index(s); lag = 0.045 * (i + 1)
                    drop = rig.h(self.base) * max(0.0, self.squash_at(tau - lag)) if tau < sp['antic'] + 0.1 else 0.0
                    a.y -= drop * (1 + 0.22 * i)
                    u = (tau - sp['antic'] + 0.12 - lag) / 0.2
                    if 0 <= u <= 1 and tau < sp['antic']:
                        a.y += 6 * (i + 1) * math.sin(math.pi * u)
            # launch: thrown off the jumping base, higher stones with more momentum
            if sp['mode'] == 'launch' and not (sp.get('lead') and sp['lead']['stone'] == s):
                tl = tau - sp['antic']
                if tl > 0:
                    L = sp['launch']; r = max(0, self.a_rank[s] - 1)
                    ta = L['tApex'] + L['tApexPerRank'] * r; ap = L['apex'] + L['apexPerRank'] * r
                    g = 2 * ap / (ta * ta)
                    a.y += g * ta * tl - 0.5 * g * tl * tl
                    a.x += self.side[s] * L['spread'] * smoother(tl / (ta + 0.3))
                    a.rot += self.side[s] * -40 * smoother(tl / (ta + 0.4))
            start, dur, ease = self.sched[s]
            u = (tau - start) / dur
            m = out_back(u) if ease == 'outBack' else smoother(u)
            if tau < start: m = 0.0
            k = min(1.0, self.dist[s] / sp.get('arcDistance', 400))
            bump = math.sin(math.pi * clamp01(u)) if 0 < u < 1 else 0.0
            st = StoneState(lerp(a.x, b.x, m) + self.side[s] * sp.get('fling', 0) * k * bump,
                            lerp(a.y, b.y, m) + sp.get('arc', 0) * k * bump,
                            lerp(a.rot, b.rot, m), lerp(a.scale, b.scale, m),
                            a.squash * (1 - clamp01(m)), lerp(a.depth, b.depth, clamp01(m)), lerp(a.shade, b.shade, clamp01(m)))
            # the jumper stretches as it springs
            if ease == 'outBack' and sp['mode'] == 'launch':
                v = (tau - start) / 0.32
                if 0 <= v <= 1: st.squash -= 0.08 * math.sin(math.pi * v) * (1 - 0.4 * v)
            # settle as it lands
            since = tau - (start + dur)
            if 'stack' in rig.poses[self.b] and 0 <= since <= sp['land']['duration'] and \
                    s in [n for n, _ in rig.poses[self.b]['stack']['order']]:
                st.squash += sp['land']['squash'] * math.sin(math.pi * since / sp['land']['duration'])
            st.y = max(st.y, rig.h(s) * st.scale / 2)        # nothing ever sinks below the ground
            out[s] = st
        p = smoother(tau / self.duration)
        squint = 0.55 * smooth(tau / sp['antic']) * (1 - smooth((tau - sp['antic']) / 0.1)) if sp['antic'] > 0 else 0.0
        return Frame(out, lerp(A.eye_x, B.eye_x, p), lerp(A.eye_y, B.eye_y, p), max(rig.blink(t), squint))


class Player:
    """The runtime state machine: set a mood any time; it plays the right transition (or re-routes mid-move)."""

    def __init__(self, rig, mood='idle', t=0.0):
        self.rig = rig; self.pose = rig.spec['moods'][mood]; self.trans = None

    def set_mood(self, mood, t):
        target = self.rig.spec['moods'].get(mood, self.rig.spec['moods']['idle'])
        if self.trans:
            if target == self.trans.b: return
            snap = self.trans.frame(t)
            self.trans = Transition(self.rig, self.trans.b, target, t, self.rig.transition_spec('*', '*'), snapshot=snap)
        else:
            if target == self.pose: return
            self.trans = Transition(self.rig, self.pose, target, t, self.rig.transition_spec(self.pose, target))
        self.pose = target

    def frame(self, t):
        if self.trans and self.trans.done(t): self.trans = None
        return self.trans.frame(t) if self.trans else self.rig.eval_pose(self.pose, t)

# Golem's rig

Golem is drawn live from data: `rig/golem.json` describes his stones, poses, transitions and
which pose each mood plays; `Shared/GolemRig.swift` evaluates it and `Shared/GolemRigView.swift`
draws it on macOS and iOS.

- **Stones**: five sprites (head, belly, chest, foot, pebble) plus two eyes, so he can blink and
  look around. Units are rig px: y up from the ground, x from the centre line; images are drawn
  at `pixelScale` image px per rig px.
- **Poses** combine a `stack` (an ordered pile that sways; the cairn, balancing and news poses),
  `float` (stones placed freely with a bob or pulse; the news "!", the thinking head) and a
  `ring` (the 2.5D orbit: far stones shrink, darken and pass behind).
- **Moods** map Chatterbox's states to poses: idle → cairn, waiting → balance, thinking →
  thinking, news → news.
- **Transitions** move any pose to any other. `default` sends stones off top-first and lands them
  bottom-first on arcs; pair entries (`"cairn>balance"`) override only what differs: an
  anticipation squash, a momentum `launch`, a `lead` stone that moves first, `sides` to fling
  stones both ways. A mood change mid-move re-routes from wherever the stones are.

## Changing him

Edit `rig/golem.json`, preview, then install:

    python3 Golem/reference/preview.py                 # showreel → Golem/reference/preview/
    python3 Golem/reference/preview.py idle:0 news:2   # any mood script (mood:seconds)
    scripts/install-golem-rig.sh                       # into ~/Chatterbox/Dot/Avatar

The preview needs Pillow and NumPy (`uv run --with pillow --with numpy python …`).
`reference/golem_rig.py` is the reference evaluator; the Swift one mirrors it line for line, so
a change to how poses or transitions are computed goes in both.

"""Rasterise assets/prospero-win-logo.svg (128x128 viewBox) to a 512x512 icon0.png.

  python3 -I scripts/render-logo-icon.py assets/prospero-win-logo.svg assets/icon0.png
"""

import re, sys
from PIL import Image, ImageDraw

SRC, OUT = sys.argv[1], sys.argv[2]
SS = 8                      # supersample factor
SIZE = 512
K = SIZE * SS / 128.0       # viewBox units -> supersampled pixels

def tokens(d):
    return re.findall(r'[MmLlHhVvCcSsZz]|-?\d*\.?\d+', d)

def cubic(p0, p1, p2, p3, n=24):
    pts = []
    for i in range(1, n + 1):
        t = i / n; u = 1 - t
        pts.append((u**3*p0[0] + 3*u*u*t*p1[0] + 3*u*t*t*p2[0] + t**3*p3[0],
                    u**3*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t**3*p3[1]))
    return pts

def subpaths(d):
    t = tokens(d); i = 0; cmd = None
    x = y = sx = sy = 0.0; last_c2 = None; cur = []; out = []
    def num():
        nonlocal i
        v = float(t[i]); i += 1; return v
    while i < len(t):
        if re.match(r'[A-Za-z]', t[i]):
            cmd = t[i]; i += 1
            if cmd in 'Zz':
                if cur: out.append(cur)
                cur = []; x, y = sx, sy; last_c2 = None
                continue
        rel = cmd.islower(); c = cmd.upper()
        if c == 'M':
            nx, ny = num(), num()
            if rel: nx += x; ny += y
            if cur: out.append(cur)
            x, y = sx, sy = nx, ny; cur = [(x, y)]; last_c2 = None
            cmd = 'l' if rel else 'L'
        elif c == 'L':
            nx, ny = num(), num()
            if rel: nx += x; ny += y
            x, y = nx, ny; cur.append((x, y)); last_c2 = None
        elif c == 'H':
            nx = num(); x = nx + x if rel else nx; cur.append((x, y)); last_c2 = None
        elif c == 'V':
            ny = num(); y = ny + y if rel else ny; cur.append((x, y)); last_c2 = None
        elif c == 'C':
            a = [num() for _ in range(6)]
            if rel: a = [a[0]+x, a[1]+y, a[2]+x, a[3]+y, a[4]+x, a[5]+y]
            cur += cubic((x, y), (a[0], a[1]), (a[2], a[3]), (a[4], a[5]))
            last_c2 = (a[2], a[3]); x, y = a[4], a[5]
        elif c == 'S':
            a = [num() for _ in range(4)]
            if rel: a = [a[0]+x, a[1]+y, a[2]+x, a[3]+y]
            c1 = (2*x - last_c2[0], 2*y - last_c2[1]) if last_c2 else (x, y)
            cur += cubic((x, y), c1, (a[0], a[1]), (a[2], a[3]))
            last_c2 = (a[0], a[1]); x, y = a[2], a[3]
    if cur: out.append(cur)
    return out

svg = open(SRC).read()
rect = re.search(r'<rect[^>]*/>', svg).group(0)
paths = re.findall(r'<path d="([^"]+)"([^>]*)/>', svg)
attr = lambda s, k: re.search(k + r'="([^"]+)"', s).group(1)

bg = attr(rect, 'fill'); edge = attr(rect, 'stroke')
img = Image.new('RGB', (SIZE * SS,) * 2, bg)
dr = ImageDraw.Draw(img)
rx, ry, rw, rh = (float(attr(rect, k)) for k in ('x', 'y', 'width', 'height'))
dr.rounded_rectangle([rx*K, ry*K, (rx+rw)*K, (ry+rh)*K], radius=float(attr(rect, 'rx'))*K,
                     fill=bg, outline=edge, width=int(float(attr(rect, 'stroke-width'))*K))
for d, rest in paths:
    scaled = [[(px*K, py*K) for px, py in sp] for sp in subpaths(d)]
    if 'fill="' in rest:
        # first subpath is the shape, later ones are counters (holes) painted with the background
        dr.polygon(scaled[0], fill=attr(rest, 'fill'))
        for hole in scaled[1:]:
            dr.polygon(hole, fill=bg)
    else:
        w = float(attr(rest, 'stroke-width')) * K
        (x0, y0), (x1, y1) = scaled[0][0], scaled[0][-1]
        dr.line([(x0, y0), (x1, y1)], fill=attr(rest, 'stroke'), width=int(w))
        for cx, cy in ((x0, y0), (x1, y1)):   # round caps
            dr.ellipse([cx - w/2, cy - w/2, cx + w/2, cy + w/2], fill=attr(rest, 'stroke'))
img.resize((SIZE, SIZE), Image.LANCZOS).save(OUT, optimize=True)
print('wrote', OUT)

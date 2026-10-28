#!/usr/bin/env python3
"""Bake a stage's vertex light: the sun (soft shadows), the sky, the project's placed lights, glowing materials and
light bounces (radiosity), ray traced with Embree (pip package embreex). Replaces the LP1 lightmap bake that
lp2stage.py samples into the vertex colour, when the project's stage.light.source is "bake".

  lp2bake.py PROJECT_DIR             bake the editor's preview (.preview/geo.bin + bake.bin; the unsplit LP1 one kept
                                     in geo_base.bin / .json)
  lp2bake.py PROJECT_DIR --restore   the preview back to the LP1 bake

lp2mapc.py bakes the built stage (after the editor's geometry edits) the same way; lp2preview.py re-bakes a rebuilt
preview. Settings, project stage.light (defaults in DEFAULTS): source "lp1" / "bake"; live: sun, sky (strengths),
sky_tint, lights, glow, exposure (EV), min_light (the darkest linear light allowed, softly); baked: bounce (strength),
bounces, samples (sky rays per vertex), emissive {colour map name: [r, g, b]} (glowing materials).
The bake keeps each light source apart (COMPONENTS, bounces included: light adds up), so the live settings and the
sun / sky / ground colours apply afterwards without a re-bake (combine(); the editor's shader, from .preview/bake.bin).
Geometry, light placement, sun direction, bounces and samples need a re-bake.

Light model (the editor's baked.gdshader; assumed to be the game's): the vertex colour c is light in gamma space,
pixel = colour map x (2c)^2.2, so linear light L = (2c)^2.2 and c = L^(1/2.2) / 2 (L 1.0 = byte 128). Sun, sky and
ground colours come from the project's environment (as the Lighting window shows them). Bounced light takes each
material's average colour-map colour. Stage units are cm; the preview's are m.
"""
import argparse, json, os, shutil, sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

DEFAULTS = dict(source="lp1", sun=0.4, sky=1.0, sky_tint=[1.0, 1.0, 1.0], lights=1.0, glow=1.0, exposure=0.0,
                min_light=0.01, bounce=1.0, bounces=2, samples=64, detail=0, emissive={})
LIVE = ("sun", "sky", "sky_tint", "lights", "glow", "exposure", "min_light")   # applied to the stored components
STOCK_SUN, STOCK_SKY, STOCK_GROUND = [2.43] * 3, [0.152] * 3, [0.106] * 3
CALIBRATION = 0.48    # linear light per unit of irradiance (fitted: Battlegrounds' default bake's median = LP1's)
EPS = 2.0             # ray start off the surface, cm
FAR = 200000.0        # cm from the map's centre: beyond it (LP1's sky dome, ~3-7 km out) nothing blocks light or is baked
SUN_SAMPLES = 8
SUN_SPREAD = 0.01     # soft shadow: rays within this many radians of the sun direction
SPREAD = 0.6          # rays start up to this far from a vertex towards the middle of a triangle around it
CHUNK = 1 << 20
COMPONENTS = ("sun", "sky", "ground", "lights", "glow")
# detail (settings "detail": up to that many % more vertices): bake, split the triangles whose corners' light differs
# most (shadow edges, doorways, wall feet), bake again; DETAIL_PASSES times, quick bakes, then the full one
DETAIL_PASSES = 3
DETAIL_SAMPLES = 16
DETAIL_CONTRAST = 0.4    # split when the brightest corner is over e^0.4 (1.5x) the darkest
DETAIL_MIN_EDGE = 30.0   # cm: edges shorter than this aren't split   # 3 floats each per vertex, white sun / sky / ground


def settings(p):
    s = dict(DEFAULTS)
    s.update((p.get("stage") or {}).get("light") or {})
    return s


def progress(f, text):
    print(f"@progress {f:.3f} {text}", flush=True)


def srgb_lin(c):
    c = np.asarray(c, np.float64)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def albedo_png(path):
    """a colour map's average colour (linear), from a preview PNG"""
    from PIL import Image
    try:
        im = Image.open(path).convert("RGB")
    except OSError:
        return None
    im.thumbnail((64, 64))
    return srgb_lin(np.asarray(im, np.float64) / 255.0).reshape(-1, 3).mean(0)


def _frame(n):
    """tangent, bitangent for unit normals (n, 3)"""
    a = np.where(np.abs(n[:, :1]) < 0.9, [[1.0, 0, 0]], [[0, 1.0, 0]])
    t = np.cross(n, a)
    t /= np.linalg.norm(t, axis=1, keepdims=True)
    return t, np.cross(n, t)


def _col(c, fallback):
    return np.asarray(c if c is not None else fallback, np.float64)


def bake(P, N, T, vmat, albedo, emission, env, lights, s, log=print):
    """-> light components per vertex (n, 15): COMPONENTS x rgb, before the live settings (combine());
    NaN for the far geometry (it keeps its old colour). The sun, sky and ground are white here (their colours
    are live), the placed lights and glow carry their own colours. Bounces are in every component.
    P (n, 3) cm, N (n, 3) unit normals, T (k, 3) triangles, vmat (n,) material per vertex, albedo / emission
    (materials, 3) linear, env the project's environment, lights its placed lights, s settings()."""
    from embreex import rtcore_scene as rtcs
    from embreex.mesh_construction import TriangleMesh
    P, N = P.astype(np.float32), N.astype(np.float32).copy()
    bad = ~np.isfinite(N).all(1) | (np.linalg.norm(N, axis=1) < 0.5)
    N[bad] = (0, 1, 0)
    far = np.linalg.norm(P - np.median(P, 0), axis=1) > FAR
    T = T[~far[T].any(1)]
    scene = rtcs.EmbreeScene()
    TriangleMesh(scene, P[T])
    tri_n = np.cross(P[T[:, 1]] - P[T[:, 0]], P[T[:, 2]] - P[T[:, 0]])
    front = np.sign(np.einsum("ij,ij->i", tri_n, N[T].sum(1)))   # which side of each triangle its vertices face
    tri_n *= front[:, None]
    n = len(P)
    rng = np.random.default_rng(1)
    # each ray starts somewhere on the surface around its vertex (towards the centre of one of its triangles), so a
    # vertex's light is its neighbourhood's, like a lightmap texel; from the corner itself, floors at the foot of a
    # wall all fell into the wall's shadow
    order = np.argsort(T.ravel(), kind="stable")
    vt = order // 3                                           # triangles by vertex
    first = np.searchsorted(T.ravel()[order], np.arange(n))
    count = np.bincount(T.ravel(), minlength=n)
    centre = P[T].mean(1)

    def origins(idx):
        c = count[idx]
        pick = vt[np.minimum(first[idx] + (rng.random(len(idx)) * c).astype(np.int64), len(vt) - 1)]
        f = np.where(c > 0, rng.random(len(idx)) * SPREAD, 0.0)[:, None]
        return (P[idx] + (centre[pick] - P[idx]) * f + N[idx] * EPS).astype(np.float32)

    def trace(o, d, dist=None):
        """-> 1 blocked, 0 clear, -1 the ray started behind a surface (inside a wall: the sample doesn't count)"""
        out = np.zeros(len(o), np.int8)
        for i in range(0, len(o), CHUNK):
            dd = None if dist is None else dist[i:i + CHUNK].astype(np.float32)
            h = scene.run(o[i:i + CHUNK], d[i:i + CHUNK].astype(np.float32), dists=dd, output=1)
            pid = h["primID"]
            back = (pid >= 0) & (np.einsum("ij,ij->i", tri_n[np.maximum(pid, 0)], d[i:i + CHUNK]) > 0)
            out[i:i + CHUNK] = np.where(back, -1, pid >= 0)
        return out

    C = np.zeros((n, 15))
    # direct: the sun (white, unit strength)
    progress(0.03, "sun")
    sd = np.asarray(env.get("sun") or [0.472, 0.848, 0.241], np.float64)
    sd /= np.linalg.norm(sd)
    cos = N @ sd
    lit = np.nonzero(cos > 0)[0]
    clear, valid = np.zeros(len(lit)), np.zeros(len(lit))
    t, b = _frame(sd[None])
    for _ in range(SUN_SAMPLES):
        r = np.sqrt(rng.random(len(lit))) * SUN_SPREAD
        a = rng.random(len(lit)) * 2 * np.pi
        d = sd + t * (r * np.cos(a))[:, None] + b * (r * np.sin(a))[:, None]
        d /= np.linalg.norm(d, axis=1, keepdims=True)
        h = trace(origins(lit), d)
        clear += h == 0
        valid += h >= 0
    C[lit, 0:3] = (cos[lit] * clear / np.maximum(valid, 1))[:, None]

    # direct: placed lights (point / spot: full to start, linear fade to end, cm; spots: cone + soft edge)
    for k, L in enumerate(lights or []):
        progress(0.08, f"light {k + 1}")
        lp = np.asarray(L["pos"], np.float64)
        v = lp - P
        dist = np.linalg.norm(v, axis=1)
        end, start = float(L.get("end", 1000.0)), float(L.get("start", 0.0))
        f = np.clip((end - dist) / max(end - start, 1.0), 0, 1)
        d = v / np.maximum(dist, 1e-6)[:, None]
        f *= np.clip(np.einsum("ij,ij->i", N, d), 0, None)
        if L.get("type") == "spot" and L.get("dir"):
            half = np.radians(float(L.get("cone", 60.0)) / 2)
            soft = np.radians(float(L.get("spread", 10.0)))
            c = -d @ np.asarray(L["dir"], np.float64)
            f *= np.clip((c - np.cos(half + soft)) / max(np.cos(half) - np.cos(half + soft), 1e-4), 0, 1)
        on = np.nonzero(f > 0)[0]
        if len(on):
            o = origins(on)
            v2 = lp - o
            d2 = np.linalg.norm(v2, axis=1)
            f[on[trace(o, v2 / np.maximum(d2, 1e-6)[:, None], d2 - EPS) == 1]] = 0
        C[:, 9:12] += np.outer(f, _col(L.get("colour"), [1, 1, 1]) * float(L.get("brightness", 2.0)))

    # sky rays (cosine weighted, fixed per vertex): what each sees, reused by every bounce
    K = int(s["samples"])
    tv, bv = _frame(N.astype(np.float64))
    hit_p = np.full((n, K), -1, np.int32)
    hit_uv = np.zeros((n, K, 2), np.float16)
    valid = np.zeros(n)
    for k in range(K):
        progress(0.1 + 0.6 * k / K, f"sky rays {k + 1}/{K}")
        u1 = (k + rng.random(n)) / K   # stratified on the elevation
        a = rng.random(n) * 2 * np.pi
        r = np.sqrt(u1)
        d = tv * (r * np.cos(a))[:, None] + bv * (r * np.sin(a))[:, None] + N * np.sqrt(1 - u1)[:, None]
        O = origins(np.arange(n))
        for i in range(0, n, CHUNK):
            h = scene.run(O[i:i + CHUNK], d[i:i + CHUNK].astype(np.float32), output=1)
            pid = h["primID"]
            back = (pid >= 0) & (np.einsum("ij,ij->i", tri_n[np.maximum(pid, 0)], d[i:i + CHUNK]) > 0)
            pid = np.where(back, -2, pid)   # started behind a surface: the sample doesn't count
            hit_p[i:i + CHUNK, k] = pid
            hit_uv[i:i + CHUNK, k, 0], hit_uv[i:i + CHUNK, k, 1] = h["u"], h["v"]
            valid[i:i + CHUNK] += pid != -2
            miss = pid == -1
            up = d[i:i + CHUNK, 1] >= 0
            C[i:i + CHUNK, 3:6] += (miss & up)[:, None] * np.pi
            C[i:i + CHUNK, 6:9] += (miss & ~up)[:, None] * np.pi
    w_v = 1.0 / np.maximum(valid, 1)
    C[:, 3:9] *= w_v[:, None]

    # bounces: each sky ray that hit a surface gathers that point's outgoing light (albedo x light + glow).
    # Light adds up, so each component bounces on its own; the gather is a fixed sparse sum (owner <- 3 vertices).
    progress(0.72, "bounces")
    hp = hit_p.ravel()
    hit = hp >= 0
    tri = T[hp[hit]].astype(np.int32)
    w = hit_uv.reshape(-1, 2)[hit].astype(np.float32)
    bw = np.stack([1 - w[:, 0] - w[:, 1], w[:, 0], w[:, 1]], 1)
    owner = np.repeat(np.arange(n), K)[hit]
    del hit_p, hit_uv, hp, w
    wk = w_v[owner]

    def gather(x):
        """x (n,) outgoing light -> what each vertex's sky rays gather"""
        return np.bincount(owner, (bw * x[tri]).sum(1) * wk, n)

    alb = albedo[vmat] * s["bounce"]
    D = C.copy()
    D[:, 12:15] = 0
    glow = emission[vmat] * np.pi
    for ci in range(15):
        ch = ci % 3
        if ci >= 12:   # glow: what the glowing surfaces light around them, then bounced
            D[:, ci] = gather(glow[:, ch])
        if not D[:, ci].any():
            continue
        E = D[:, ci].copy()
        for it in range(int(s["bounces"])):
            E = D[:, ci] + gather(alb[:, ch] * E)
        C[:, ci] = E
        progress(0.72 + 0.23 * (ci + 1) / 15, f"bounces {COMPONENTS[ci // 3]}")
    C[:, 12:15] += glow   # glowing surfaces show their glow

    # seams: vertices at one spot facing the same way (split by material / atom) share their light
    key = np.concatenate([np.round(P / 0.5).astype(np.int64), np.round(N * 4).astype(np.int64)], 1)
    _, inv, cnt = np.unique(key, axis=0, return_inverse=True, return_counts=True)
    inv = inv.ravel()
    for ci in range(15):
        C[:, ci] = np.bincount(inv, C[:, ci], len(cnt))[inv] / cnt[inv]
    C[far] = np.nan
    progress(0.97, "done")
    return C.astype(np.float32)


def combine(C, env, s):
    """components -> linear light with the live settings (the editor's baked.gdshader does the same)"""
    sun = _col(env.get("sun_colour"), STOCK_SUN) * float(s["sun"])
    tint = np.asarray(s.get("sky_tint") or [1, 1, 1], np.float64) * float(s["sky"])
    L = (C[:, 0:3] * sun + C[:, 3:6] * _col(env.get("sky_colour"), STOCK_SKY) * tint
         + C[:, 6:9] * _col(env.get("ground_colour"), STOCK_GROUND) * tint
         + C[:, 9:12] * float(s["lights"]) + C[:, 12:15] * float(s["glow"]))
    L = L * CALIBRATION * 2.0 ** float(s["exposure"])
    m = float(s["min_light"])   # the floor: a soft max, so the darkest spots lift without going flat
    return np.sqrt(L * L + m * m)


def subdivide(attrs, T, score, budget, unit=("N",)):
    """split up to budget edges: each scoring triangle's longest edge, best first, and with it every triangle that
    shares that edge (no cracks inside a mesh). attrs: name -> per-vertex array (new vertices: the edge's midpoint,
    the unit ones renormalised; integer arrays copy the first end). -> attrs, T, added vertex count"""
    P = attrs["P"]
    n = len(P)
    e = np.stack([T[:, [0, 1]], T[:, [1, 2]], T[:, [2, 0]]], 1)               # (k, 3, 2)
    ln = np.linalg.norm(P[e[..., 0]] - P[e[..., 1]], axis=2)                  # (k, 3)
    longest = ln.argmax(1)
    pick = np.nonzero(np.isfinite(score) & (score > 0) & (ln.max(1) > DETAIL_MIN_EDGE))[0]
    pick = pick[np.argsort(-(score[pick] * ln.max(1)[pick]), kind="stable")]
    le = np.sort(e[pick, longest[pick]], 1)
    key = le[:, 0] * n + le[:, 1]
    _, first = np.unique(key, return_index=True)
    key = key[np.sort(first)][:budget]                                         # best first, each edge once
    if not len(key):
        return attrs, T, 0
    mid = {int(k): n + i for i, k in enumerate(key)}
    a, b = key // n, key % n
    new = {}
    for name, v in attrs.items():
        if np.issubdtype(v.dtype, np.integer):
            m = v[a]
        else:
            m = (v[a].astype(np.float64) + v[b]) / 2
            if name in unit:
                m /= np.maximum(np.linalg.norm(m, axis=1, keepdims=True), 1e-9)
        new[name] = np.concatenate([v, m.astype(v.dtype)])
    ek = np.sort(e, 2)
    ek = ek[..., 0] * n + ek[..., 1]                                           # (k, 3) edge keys
    marked = np.isin(ek, key)
    out = [T[~marked.any(1)]]
    for t, mk, kk in zip(T[marked.any(1)], marked[marked.any(1)], ek[marked.any(1)]):
        m = [mid.get(int(x)) if f else None for x, f in zip(kk, mk)]
        c = int(mk.sum())
        r = int(np.argmax(mk)) if c == 1 else (int(np.argmin(mk)) + 1) % 3 if c == 2 else 0
        A, B, C = t[r], t[(r + 1) % 3], t[(r + 2) % 3]
        m0, m1, m2 = m[r], m[(r + 1) % 3], m[(r + 2) % 3]
        if c == 1:      # A-B split
            out.append([[A, m0, C], [m0, B, C]])
        elif c == 2:    # A-B and B-C split
            out.append([[m0, B, m1], [A, m0, m1], [A, m1, C]])
        else:
            out.append([[A, m0, m2], [m0, B, m1], [m2, m1, C], [m0, m1, m2]])
    return new, np.concatenate([np.asarray(x, T.dtype).reshape(-1, 3) for x in out]), len(key)


def bake_detailed(attrs, T, albedo, emission, env, lights, s, log=print):
    """bake() with the detail passes: -> attrs, T (split), components. attrs needs P (cm), N, vmat, group (the
    vertex's block / mesh: kept together by the caller); anything else is carried along"""
    budget = int(len(attrs["P"]) * float(s.get("detail") or 0) / 100)
    for it in range(DETAIL_PASSES if budget > 0 else 0):
        quick = dict(s, samples=min(DETAIL_SAMPLES, int(s["samples"])), bounces=min(1, int(s["bounces"])))
        comp = bake(attrs["P"], attrs["N"], T, attrs["vmat"], albedo, emission, env, lights, quick, log)
        lum = combine(comp, env, s).mean(1)
        lg = np.log(lum + 0.01)
        score = lg[T].max(1) - lg[T].min(1) - DETAIL_CONTRAST
        attrs, T, added = subdivide(attrs, T, score, budget)
        budget -= added
        log(f"detail pass {it + 1}: +{added} vertices")
        if not added or budget <= 0:
            break
    comp = bake(attrs["P"], attrs["N"], T, attrs["vmat"], albedo, emission, env, lights, s, log)
    return attrs, T, comp


def regroup(attrs, T):
    """vertices sorted by group (stable): -> attrs, T, and per group (first vertex, count)"""
    order = np.argsort(attrs["group"], kind="stable")
    inv = np.empty_like(order)
    inv[order] = np.arange(len(order))
    attrs = {k: v[order] for k, v in attrs.items()}
    return attrs, inv[T], order


def to_colour(L):
    """linear light -> vertex colour 0..1 (c = L^(1/2.2) / 2)"""
    return np.clip(np.power(np.maximum(L, 0), 1 / 2.2) / 2, 0, 1)


def emission_table(names, s):
    em = np.zeros((len(names), 3))
    for i, nm in enumerate(names):
        c = (s.get("emissive") or {}).get(nm or "")
        if c:
            em[i] = c[:3]
    return em


# ---------------------------------------------------------------- the editor's preview

def preview_arrays(prev, name="geo"):
    g = json.load(open(os.path.join(prev, name + ".json")))
    b = open(os.path.join(prev, name + ".bin"), "rb").read()
    arr = lambda k, w, t="<f4": np.frombuffer(b, t, g["arrays"][k][1] // 4, g["arrays"][k][0]).reshape(-1, w)
    P, N, C = arr("pos", 3) * 100.0, arr("nrm", 3), arr("col", 4)
    idx = arr("idx", 3, "<i4").astype(np.int64)
    vmat = np.zeros(len(P), np.int64)
    for atom, mat, v0, vn, i0, ic in g["blocks"]:
        idx[i0 // 3:(i0 + ic) // 3] += v0
        vmat[v0:v0 + vn] = mat
    return g, P, N, C, idx, vmat


def bake_preview(folder, log=print):
    """bake into PROJECT/.preview: bake.bin (the components, see write_custom) and geo.bin / geo.json (split by the
    detail passes; col combined with the current settings, for everything that reads the plain colour). The unsplit
    preview (with the LP1 bake) stays in geo_base.bin / .json: every bake starts from it, restore_preview puts it back"""
    import lp2project
    p = lp2project.load(folder)
    s = settings(p)
    env = p.get("environment") or {}
    prev = os.path.join(folder, ".preview")
    old = os.path.join(prev, "col_lp1.bin")   # an earlier bake's keep of the LP1 colours: back into geo.bin first
    if os.path.exists(old) and not os.path.exists(os.path.join(prev, "geo_base.bin")):
        o, nb = json.load(open(os.path.join(prev, "geo.json")))["arrays"]["col"]
        with open(os.path.join(prev, "geo.bin"), "r+b") as f:
            f.seek(o)
            f.write(open(old, "rb").read()[:nb])
    if os.path.exists(old):
        os.remove(old)
    for ext in ("bin", "json"):
        if not os.path.exists(os.path.join(prev, "geo_base." + ext)):
            shutil.copyfile(os.path.join(prev, "geo." + ext), os.path.join(prev, "geo_base." + ext))
    g, P, N, C, T, vmat = preview_arrays(prev, "geo_base")
    raw = open(os.path.join(prev, "geo_base.bin"), "rb").read()
    U = np.frombuffer(raw, "<f4", g["arrays"]["uv"][1] // 4, g["arrays"]["uv"][0]).reshape(-1, 2)
    group = np.zeros(len(P), np.int64)
    for k, (atom, mat, v0, vn, i0, ic) in enumerate(g["blocks"]):
        group[v0:v0 + vn] = k
    mats = g["materials"]
    albedo = np.stack([a if a is not None else np.full(3, 0.5) for a in
                       (albedo_png(os.path.join(prev, m["tex"])) if m.get("tex") else None for m in mats)]).astype(np.float64)
    attrs = dict(P=P.astype(np.float64), N=N.astype(np.float64), U=U, C=C, vmat=vmat, group=group)
    attrs, T, comp = bake_detailed(attrs, T, albedo, emission_table([m.get("name") for m in mats], s),
                                   env, p.get("lights") or [], s, log)
    order = np.argsort(attrs["group"], kind="stable")   # back into blocks
    attrs, T, comp = {k: v[order] for k, v in attrs.items()}, np.argsort(order)[T], comp[order]
    T = T[np.argsort(attrs["group"][T[:, 0]], kind="stable")]
    write_custom(os.path.join(prev, "bake.bin"), comp)
    L = combine(comp, env, s)
    col = np.array(attrs["C"], np.float32)
    ok = np.isfinite(L).all(1)
    col[ok, :3] = to_colour(L[ok])
    nb = len(g["blocks"])
    v0 = np.searchsorted(attrs["group"], np.arange(nb))
    vn = np.bincount(attrs["group"], minlength=nb)
    tg = attrs["group"][T[:, 0]]
    t0 = np.searchsorted(tg, np.arange(nb))
    tc = np.bincount(tg, minlength=nb)
    local = T - v0[tg][:, None]
    cur = json.load(open(os.path.join(prev, "geo.json")))   # keep what other tools added to it
    arrays, bin_ = {}, bytearray()
    for name, arr in (("pos", attrs["P"] / 100.0), ("nrm", attrs["N"]), ("uv", attrs["U"]), ("col", col), ("idx", local.ravel())):
        data = np.asarray(arr).astype("<i4" if name == "idx" else "<f4").tobytes()
        arrays[name] = [len(bin_), len(data)]
        bin_ += data
    cur["arrays"] = arrays
    cur["blocks"] = [[blk[0], blk[1], int(v0[k]), int(vn[k]), int(t0[k]) * 3, int(tc[k]) * 3] for k, blk in enumerate(g["blocks"])]
    cur.setdefault("stats", {}).update(vertices=int(len(attrs["P"])), triangles=int(len(T)))
    open(os.path.join(prev, "geo.bin"), "wb").write(bin_)
    json.dump(cur, open(os.path.join(prev, "geo.json"), "w"), separators=(",", ":"))
    ref = np.power(np.clip(C[:, :3] * 2, 0, None), 2.2)
    log(f"bake: median light {np.nanmedian(L):.3f} (LP1 bake {np.median(ref):.3f}); "
        f"{len(attrs['P'])} vertices ({len(attrs['P']) - len(P):+d} for detail)")


def write_custom(path, comp):
    """the components as the editor's 4 vertex channels (CUSTOM0-3, RGBA f32, one block each, geo.bin's order):
    sun rgb + 1 (0: not baked, keep the plain colour), sky rgb + glow r, ground rgb + glow g, lights rgb + glow b"""
    ok = np.isfinite(comp).all(1).astype(np.float32)
    c = np.nan_to_num(comp).astype(np.float32)
    blocks = [np.c_[c[:, 0:3], ok], np.c_[c[:, 3:6], c[:, 12]], np.c_[c[:, 6:9], c[:, 13]], np.c_[c[:, 9:12], c[:, 14]]]
    open(path, "wb").write(b"".join(b.astype("<f4").tobytes() for b in blocks))


def read_custom(path):
    """write_custom's file -> components (n, 15), NaN where not baked"""
    b = np.fromfile(path, "<f4").reshape(4, -1, 4)
    comp = np.concatenate([b[0, :, :3], b[1, :, :3], b[2, :, :3], b[3, :, :3], b[1:, :, 3].T], 1)
    comp[b[0, :, 3] < 0.5] = np.nan
    return comp


def restore_preview(folder, log=print):
    prev = os.path.join(folder, ".preview")
    if os.path.exists(os.path.join(prev, "bake.bin")):
        os.remove(os.path.join(prev, "bake.bin"))
    if os.path.exists(os.path.join(prev, "geo_base.bin")):
        cur = json.load(open(os.path.join(prev, "geo.json")))
        base = json.load(open(os.path.join(prev, "geo_base.json")))
        cur.update(arrays=base["arrays"], blocks=base["blocks"])
        cur.setdefault("stats", {}).update(vertices=base["stats"]["vertices"], triangles=base["stats"]["triangles"])
        shutil.copyfile(os.path.join(prev, "geo_base.bin"), os.path.join(prev, "geo.bin"))
        json.dump(cur, open(os.path.join(prev, "geo.json"), "w"), separators=(",", ":"))
        for ext in ("bin", "json"):
            os.remove(os.path.join(prev, "geo_base." + ext))
        log("preview back to the LP1 bake")


# ---------------------------------------------------------------- the built stage (lp2mapc.py)

def bake_stage(model, folder, p, log=print):
    """re-light (and with detail, split) a written stage rModel in place"""
    import lp2pieces, lp2stage
    S = lp2pieces.read_stage(model)
    s = settings(p)
    env = p.get("environment") or {}
    V = np.concatenate([m["v"] for m in S["meshes"]])
    Ts, base = [], 0
    for m in S["meshes"]:
        Ts.append(m["tris"] + base)
        base += len(m["v"])
    unpack = lambda o: (V[:, o:o + 3].astype(np.float64) - 127.0) / 127.0
    attrs = dict(P=V[:, :12].copy().view("<f4").reshape(-1, 3).astype(np.float64), N=unpack(12), TG=unpack(16),
                 U=V[:, 20:24].copy().view("<f2").reshape(-1, 2).astype(np.float64), C=V[:, 24:28].astype(np.float64),
                 W=V[:, [15, 19]].astype(np.int64),
                 vmat=np.concatenate([np.full(len(m["v"]), m["mat"]) for m in S["meshes"]]),
                 group=np.concatenate([np.full(len(m["v"]), k) for k, m in enumerate(S["meshes"])]))
    attrs["N"] /= np.maximum(np.linalg.norm(attrs["N"], axis=1, keepdims=True), 1e-6)
    names = []
    for raw in S["materials"]:
        slot = int.from_bytes(raw[12:16], "little")
        names.append(S["textures"][slot - 1].split("\\")[-1] if 0 < slot <= len(S["textures"]) else None)
    tex = os.path.join(folder, ".preview", "tex")
    albedo = np.stack([a if a is not None else np.full(3, 0.5) for a in
                       (albedo_png(os.path.join(tex, nm + ".png")) if nm else None for nm in names)]).astype(np.float64)
    n0 = len(V)
    attrs, T, comp = bake_detailed(attrs, np.concatenate(Ts), albedo, emission_table(names, s), env,
                                   p.get("lights") or [], s, log)
    L = combine(comp, env, s)
    ok = np.isfinite(L).all(1)
    c = np.clip(np.round(attrs["C"]), 0, 255).astype(np.uint8)
    c[ok, :3] = np.round(to_colour(L[ok]) * 255).astype(np.uint8)
    pack = lambda x: np.clip(np.round(x * 127.0 + 127.0), 0, 255).astype(np.uint8)
    rows = np.zeros((len(c), 28), np.uint8)
    rows[:, :12] = attrs["P"].astype("<f4").view(np.uint8).reshape(-1, 12)
    rows[:, 12:15], rows[:, 15] = pack(attrs["N"]), attrs["W"][:, 0]
    rows[:, 16:19], rows[:, 19] = pack(attrs["TG"]), attrs["W"][:, 1]
    rows[:, 20:24] = attrs["U"].astype("<f2").view(np.uint8).reshape(-1, 4)
    rows[:, 24:28] = c
    tg = attrs["group"][T[:, 0]]
    meshes = []
    for k, m in enumerate(S["meshes"]):
        vi = np.nonzero(attrs["group"] == k)[0]
        remap = np.full(len(rows), -1, np.int64)
        remap[vi] = np.arange(len(vi))
        meshes.append(dict(mat=m["mat"], verts=rows[vi], tris=remap[T[tg == k]]))
    lp2stage.write_stage(model, S["textures"], S["materials"], meshes)
    log(f"  baked light: {len(rows)} vertices ({len(rows) - n0:+d} for detail)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("project")
    ap.add_argument("--restore", action="store_true")
    a = ap.parse_args()
    (restore_preview if a.restore else bake_preview)(a.project)


if __name__ == "__main__":
    main()

"""Signed-distance modelling helpers and a surface-nets mesher (numpy).

Distances are negative inside. Shapes take grid coordinate arrays X, Y, Z.
"""
import numpy as np

def length(*c):
    return np.sqrt(sum(x * x for x in c))

def ellipsoid(X, Y, Z, c, r):
    px, py, pz = (X - c[0]) / r[0], (Y - c[1]) / r[1], (Z - c[2]) / r[2]
    k0 = length(px, py, pz)
    k1 = length(px / r[0], py / r[1], pz / r[2])
    return k0 * (k0 - 1.0) / np.maximum(k1, 1e-9)

def sphere(X, Y, Z, c, r):
    return length(X - c[0], Y - c[1], Z - c[2]) - r

def capsule(X, Y, Z, a, b, ra, rb=None):
    rb = ra if rb is None else rb
    pax, pay, paz = X - a[0], Y - a[1], Z - a[2]
    bx, by, bz = b[0] - a[0], b[1] - a[1], b[2] - a[2]
    h = np.clip((pax * bx + pay * by + paz * bz) / (bx * bx + by * by + bz * bz), 0, 1)
    return length(pax - bx * h, pay - by * h, paz - bz * h) - (ra + (rb - ra) * h)

def torus(X, Y, Z, c, R, r, sx=1.0, sy=1.0):
    qx = length((X - c[0]) / sx, (Y - c[1]) / sy) - R
    return length(qx, Z - c[2]) - r

def cylinder(X, Y, Z, c, r, h):
    d0 = length(X - c[0], Y - c[1]) - r
    d1 = np.abs(Z - c[2]) - h
    return np.minimum(np.maximum(d0, d1), 0) + length(np.maximum(d0, 0), np.maximum(d1, 0))

def smin(a, b, k):
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0, 1)
    return b + (a - b) * h - k * h * (1 - h)

def smax(a, b, k):
    return -smin(-a, -b, k)

def ssub(a, b, k):
    """a minus b, blended."""
    return smax(a, -b, k)

def grid(lo, hi, step):
    xs = [np.arange(lo[i], hi[i] + step, step, dtype=np.float32) for i in range(3)]
    X, Y, Z = np.meshgrid(*xs, indexing="ij")
    return X, Y, Z, np.array(lo, np.float32)

def surface_nets(f, origin, step):
    """Quads on the zero level set of f (negative inside), one vertex per crossed cell."""
    nx, ny, nz = f.shape
    def edges(axis):
        s0 = [slice(None)] * 3; s1 = [slice(None)] * 3
        s0[axis] = slice(0, -1); s1[axis] = slice(1, None)
        f0, f1 = f[tuple(s0)], f[tuple(s1)]
        cross = (f0 < 0) != (f1 < 0)
        t = np.where(cross, f0 / np.where(cross, f0 - f1, 1), 0).astype(np.float32)
        return cross, t
    S = np.zeros((nx - 1, ny - 1, nz - 1, 3), np.float32)
    C = np.zeros((nx - 1, ny - 1, nz - 1), np.float32)
    cx, tx = edges(0)
    for a in (0, 1):
        for b in (0, 1):
            m = cx[:, a:ny - 1 + a, b:nz - 1 + b]
            C += m; S[..., 0] += m * tx[:, a:ny - 1 + a, b:nz - 1 + b]; S[..., 1] += m * a; S[..., 2] += m * b
    cy, ty = edges(1)
    for a in (0, 1):
        for b in (0, 1):
            m = cy[a:nx - 1 + a, :, b:nz - 1 + b]
            C += m; S[..., 0] += m * a; S[..., 1] += m * ty[a:nx - 1 + a, :, b:nz - 1 + b]; S[..., 2] += m * b
    cz, tz = edges(2)
    for a in (0, 1):
        for b in (0, 1):
            m = cz[a:nx - 1 + a, b:ny - 1 + b, :]
            C += m; S[..., 0] += m * a; S[..., 1] += m * b; S[..., 2] += m * tz[a:nx - 1 + a, b:ny - 1 + b, :]
    active = C > 0
    idx = -np.ones(active.shape, np.int64)
    n = int(active.sum()); idx[active] = np.arange(n)
    ii, jj, kk = np.nonzero(active)
    verts = (np.stack([ii, jj, kk], 1).astype(np.float32) + S[active] / C[active][:, None]) * step + origin
    quads = []
    e = np.argwhere(cx[:, 1:ny - 1, 1:nz - 1]); i, j, k = e[:, 0], e[:, 1] + 1, e[:, 2] + 1
    q = np.stack([idx[i, j - 1, k - 1], idx[i, j, k - 1], idx[i, j, k], idx[i, j - 1, k]], 1)
    q[f[i, j, k] >= 0] = q[f[i, j, k] >= 0][:, ::-1]; quads.append(q)
    e = np.argwhere(cy[1:nx - 1, :, 1:nz - 1]); i, j, k = e[:, 0] + 1, e[:, 1], e[:, 2] + 1
    q = np.stack([idx[i - 1, j, k - 1], idx[i - 1, j, k], idx[i, j, k], idx[i, j, k - 1]], 1)
    q[f[i, j, k] >= 0] = q[f[i, j, k] >= 0][:, ::-1]; quads.append(q)
    e = np.argwhere(cz[1:nx - 1, 1:ny - 1, :]); i, j, k = e[:, 0] + 1, e[:, 1] + 1, e[:, 2]
    q = np.stack([idx[i - 1, j - 1, k], idx[i, j - 1, k], idx[i, j, k], idx[i - 1, j, k]], 1)
    q[f[i, j, k] >= 0] = q[f[i, j, k] >= 0][:, ::-1]; quads.append(q)
    return verts, np.concatenate(quads)

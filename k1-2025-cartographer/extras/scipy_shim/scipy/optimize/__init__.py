# scipy.optimize shim — numpy-only curve_fit. See scipy/__init__.py for why.
#
# Strategy: detect whether f is linear in its parameters by probing it with
# basis vectors. If linear (every cartographer use is), solve the bounded
# linear least-squares problem EXACTLY via numpy, honouring simple box bounds
# with a tiny active-set loop. Otherwise run a projected Levenberg-Marquardt
# with numeric jacobians. Python 3.8 / numpy 1.16 compatible.

import inspect

import numpy as np


def _param_count(f, p0):
    if p0 is not None:
        return len(p0)
    return len(inspect.signature(f).parameters) - 1


def _as_bounds(bounds, n):
    lo, hi = bounds
    lo = np.full(n, lo, dtype=float) if np.isscalar(lo) else np.asarray(lo, dtype=float)
    hi = np.full(n, hi, dtype=float) if np.isscalar(hi) else np.asarray(hi, dtype=float)
    return lo, hi


def _probe_linear(f, x, n):
    """If f(x, p) == A @ p + c for all p, return (A, c); else None."""
    c = np.asarray(f(x, *np.zeros(n)), dtype=float)
    cols = []
    for i in range(n):
        e = np.zeros(n)
        e[i] = 1.0
        cols.append(np.asarray(f(x, *e), dtype=float) - c)
    A = np.column_stack(cols)
    # verify superposition with an arbitrary parameter vector
    p_test = np.linspace(0.5, 1.5, n)
    lhs = np.asarray(f(x, *p_test), dtype=float)
    rhs = A.dot(p_test) + c
    scale = max(1.0, float(np.max(np.abs(lhs))))
    if np.max(np.abs(lhs - rhs)) > 1e-9 * scale:
        return None
    return A, c


def _bounded_linear_lstsq(A, y, lo, hi):
    """Exact solve of min ||A p - y|| with box bounds, tiny active-set loop."""
    n = A.shape[1]
    fixed = {}  # index -> bound value
    for _ in range(n + 1):
        free = [i for i in range(n) if i not in fixed]
        if not free:
            break
        y_eff = y.astype(float).copy()
        for i, v in fixed.items():
            y_eff -= A[:, i] * v
        sol, _, _, _ = np.linalg.lstsq(A[:, free], y_eff, rcond=None)
        p = np.empty(n)
        for i, v in fixed.items():
            p[i] = v
        for k, i in enumerate(free):
            p[i] = sol[k]
        # find worst bound violation among free params
        worst, worst_i, worst_v = 0.0, None, 0.0
        for i in free:
            if p[i] < lo[i] and lo[i] - p[i] > worst:
                worst, worst_i, worst_v = lo[i] - p[i], i, lo[i]
            if p[i] > hi[i] and p[i] - hi[i] > worst:
                worst, worst_i, worst_v = p[i] - hi[i], i, hi[i]
        if worst_i is None:
            return p
        fixed[worst_i] = worst_v
    return np.clip(p, lo, hi)


def _lm_fit(f, x, y, p, lo, hi, maxfev, ftol, xtol):
    """Projected Levenberg-Marquardt with numeric jacobian (fallback path)."""
    n = p.size

    def resid(q):
        return np.asarray(f(x, *q), dtype=float) - y

    r = resid(p)
    cost = float(r.dot(r))
    lam = 1e-3
    evals = 1 + n
    while evals < maxfev:
        J = np.empty((y.size, n))
        for j in range(n):
            h = 1e-6 * max(1.0, abs(p[j]))
            q = p.copy()
            q[j] += h
            J[:, j] = (resid(q) - r) / h
            evals += 1
        A = J.T.dot(J)
        g = J.T.dot(r)
        improved = False
        for _ in range(60):
            try:
                dp = np.linalg.solve(A + lam * np.diag(np.diag(A) + 1e-12), -g)
            except np.linalg.LinAlgError:
                lam *= 10.0
                continue
            p_new = np.clip(p + dp, lo, hi)
            r_new = resid(p_new)
            evals += 1
            c_new = float(r_new.dot(r_new))
            if c_new <= cost:
                improved = True
                break
            lam *= 10.0
        if not improved:
            break
        rel_step = float(np.max(np.abs(p_new - p) / np.maximum(1e-12, np.abs(p_new))))
        rel_drop = (cost - c_new) / max(cost, 1e-300)
        p, r, cost = p_new, r_new, c_new
        lam = max(lam * 0.3, 1e-12)
        if rel_drop < ftol or rel_step < xtol:
            break
    return p, r


def curve_fit(f, xdata, ydata, p0=None, bounds=(-np.inf, np.inf), maxfev=10000, ftol=1e-8, xtol=1e-8, **_ignored):
    x = np.asarray(xdata, dtype=float)
    y = np.asarray(ydata, dtype=float)
    n = _param_count(f, p0)
    lo, hi = _as_bounds(bounds, n)

    linear = _probe_linear(f, x, n)
    if linear is not None:
        A, c = linear
        p = _bounded_linear_lstsq(A, y - c, lo, hi)
        r = A.dot(p) + c - y
        J = A
    else:
        p = np.ones(n) if p0 is None else np.asarray(p0, dtype=float)
        p = np.clip(p, lo, hi)
        p, r = _lm_fit(f, x, y, p, lo, hi, maxfev, ftol, xtol)
        J = np.empty((y.size, n))
        for j in range(n):
            h = 1e-6 * max(1.0, abs(p[j]))
            q = p.copy()
            q[j] += h
            J[:, j] = (np.asarray(f(x, *q), dtype=float) - (np.asarray(f(x, *p), dtype=float))) / h

    dof = max(1, y.size - n)
    try:
        pcov = np.linalg.inv(J.T.dot(J)) * (float(r.dot(r)) / dof)
    except np.linalg.LinAlgError:
        pcov = np.full((n, n), np.inf)
    return p, pcov

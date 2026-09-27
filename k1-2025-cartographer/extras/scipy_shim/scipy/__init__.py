# scipy SHIM for the 2025 K1C / K1 Max (X2600) — NOT the real scipy.
#
# Real scipy cannot be installed here: no mips32el wheels exist and a source
# build needs BLAS/LAPACK plus hours of compile on a 2-core 200MB-RAM SoC.
#
# cartographer3d-plugin only needs scipy.optimize.curve_fit, and only to fit
# functions that are LINEAR IN THEIR PARAMETERS (see cartographer/coil/
# helpers.py: a*x+b, a*x^2+b*x+c and two constrained quadratics). Those are
# exact linear least-squares problems, which numpy solves directly. This
# package provides a curve_fit that solves the linear case exactly and falls
# back to a small Levenberg-Marquardt loop for anything else.
#
# scipy.interpolate (RBFInterpolator, used only for [bed_mesh] faulty_regions
# interpolation) is intentionally NOT provided; that feature stays unavailable
# exactly as it was without scipy.
#
# Install location: /usr/data/cartographer/lib/scipy/ (already on klippy's
# sys.path via the cartographer scaffold).

__version__ = "1.10.1"
__scipy_shim__ = "k1-2025-cartographer numpy-only stand-in"

from . import optimize  # noqa: F401

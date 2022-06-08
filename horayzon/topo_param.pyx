#cython: boundscheck=False, wraparound=False, cdivision=True, language_level=3

# Copyright (c) 2022 ETH Zurich, Christian R. Steger
# MIT License

# Load modules
import numpy as np
from libc.math cimport sin, cos, sqrt, atan
from libc.math cimport M_PI
from libc.math cimport NAN
from libc.stdio cimport printf
from cython.parallel import prange
from scipy.linalg.cython_lapack cimport sgesv


# -----------------------------------------------------------------------------

def slope_plane_meth(float[:, :] x, float[:, :] y, float[:, :] z,
                     float[:, :, :, :] rot_mat=np.empty((0, 0, 3, 3),
                                                        dtype=np.float32)):
    """Plane-based slope computation.

    Compute surface slope of DEM from central and 8 neighbouring grid cells.
    Plane-based method that computes the surface normal by fitting a plane
    to the central and 8 neighbouring grid cells. The optimal fit is computed
    by minimising the sum of the squared errors in the z-direction. The same
    method is used in ArcGIS.

    Parameters
    ----------
    x : ndarray of float
        Array (two-dimensional) with x-coordinates [metre]
    y : ndarray of float
        Array (two-dimensional) with y-coordinates [metre]
    z : ndarray of float
        Array (two-dimensional) with z-coordinates [metre]
    rot_mat: ndarray of float, optional
        Array (four-dimensional) with rotation matrix (y, x, 3, 3) to transform
        coordinates to a local coordinate system in which the z-axis aligns
        with local up

    Returns
    -------
    vec_tilt : ndarray of float
        Array (three-dimensional) with titled surface normal components
        (y, x, components) [metre]

    Sources
    -------
    - ArcGIS: https://pro.arcgis.com/en/pro-app/tool-reference/spatial-analyst/
              how-slope-works.htm

    To do
    -----
    Parallelise function with OpenMP. Consider that various arrays
    (vec, mat, ...) must be thread-private."""

    cdef int len_0 = x.shape[0]
    cdef int len_1 = x.shape[1]
    cdef int i, j, k, l
    cdef float vec_x, vec_y, vec_z, vec_mag
    cdef int num, nrhs, lda, ldb, info
    cdef float x_l_sum, y_l_sum, z_l_sum
    cdef float x_l_x_l_sum, x_l_y_l_sum, x_l_z_l_sum, y_l_y_l_sum, y_l_z_l_sum
    cdef int count
    cdef float[:, :, :] vec_tilt = np.empty((len_0, len_1, 3),
                                            dtype=np.float32)
    cdef float[:] vec = np.empty(3, dtype=np.float32)
    cdef float[:] mat = np.zeros(9, dtype=np.float32)
    cdef int[:] ipiv = np.empty(3, dtype=np.int32)
    cdef float[:, :] coord = np.empty((9, 3), dtype=np.float32)

    # Settings for solving system of linear equations
    num = 3 # number of linear equations [-]
    nrhs = 1 # number of columns of matrix B [-]
    lda = 3 # leading dimension of array A [-]
    ldb = 3 # leading dimension of array B [-]

    # Initialise array
    vec_tilt[:] = NAN

    # Loop through grid cells
    if rot_mat.shape[0] == 0:
        printf("Translate input coordinates\n")

        for i in range(1, (len_0 - 1)):
            for j in range(1, (len_1 - 1)):

                # Translate input coordinates
                count = 0
                for k in range((i - 1), (i + 2)):
                    for l in range((j - 1), (j + 2)):
                        coord[count, 0] = x[k, l] - x[i, j]
                        coord[count, 1] = y[k, l] - y[i, j]
                        coord[count, 2] = z[k, l] - z[i, j]
                        count = count + 1

                # Compute normal vector of plane
                x_l_sum = 0.0
                y_l_sum = 0.0
                z_l_sum = 0.0
                x_l_x_l_sum = 0.0
                x_l_y_l_sum = 0.0
                x_l_z_l_sum = 0.0
                y_l_y_l_sum = 0.0
                y_l_z_l_sum = 0.0
                for k in range(9):
                    x_l_sum = x_l_sum + coord[k, 0]
                    y_l_sum = y_l_sum + coord[k, 1]
                    z_l_sum = z_l_sum + coord[k, 2]
                    x_l_x_l_sum = x_l_x_l_sum + (coord[k, 0] * coord[k, 0])
                    x_l_y_l_sum = x_l_y_l_sum + (coord[k, 0] * coord[k, 1])
                    x_l_z_l_sum = x_l_z_l_sum + (coord[k, 0] * coord[k, 2])
                    y_l_y_l_sum = y_l_y_l_sum + (coord[k, 1] * coord[k, 1])
                    y_l_z_l_sum = y_l_z_l_sum + (coord[k, 1] * coord[k, 2])
                # Fortran-contiguous
                mat[0] = x_l_x_l_sum
                mat[3] = x_l_y_l_sum
                mat[6] = x_l_sum
                mat[1] = x_l_y_l_sum
                mat[4] = y_l_y_l_sum
                mat[7] = y_l_sum
                mat[2] = x_l_sum
                mat[5] = y_l_sum
                mat[8] = 9.0
                vec[0] = x_l_z_l_sum
                vec[1] = y_l_z_l_sum
                vec[2] = z_l_sum
                sgesv(&num, &nrhs, &mat[0], &lda, &ipiv[0], &vec[0], &ldb,
                      &info)
                vec[2] = -1.0

                vec_x = vec[0]
                vec_y = vec[1]
                vec_z = vec[2]

                # Normalise vector
                vec_mag = sqrt(vec_x ** 2 + vec_y ** 2 + vec_z ** 2)
                vec_x = vec_x / vec_mag
                vec_y = vec_y / vec_mag
                vec_z = vec_z / vec_mag

                # Reverse orientation of plane's normal vector (if necessary)
                if vec_z < 0.0:
                    vec_x = vec_x * -1.0
                    vec_y = vec_y * -1.0
                    vec_z = vec_z * -1.0

                vec_tilt[i, j, 0] = vec_x
                vec_tilt[i, j, 1] = vec_y
                vec_tilt[i, j, 2] = vec_z

    else:
        printf("Translate and rotate input coordinates\n")

        for i in range(1, (len_0 - 1)):
            for j in range(1, (len_1 - 1)):

                # Translate and rotate input coordinates
                count = 0
                for k in range((i - 1), (i + 2)):
                    for l in range((j - 1), (j + 2)):
                        coord[count, 0] = x[k, l] - x[i, j]
                        coord[count, 1] = y[k, l] - y[i, j]
                        coord[count, 2] = z[k, l] - z[i, j]
                        count = count + 1
                for k in range(9):
                    vec_x = rot_mat[i, j, 0, 0] * coord[k, 0] \
                            + rot_mat[i, j, 0, 1] * coord[k, 1] \
                            + rot_mat[i, j, 0, 2] * coord[k, 2]
                    vec_y = rot_mat[i, j, 1, 0] * coord[k, 0] \
                            + rot_mat[i, j, 1, 1] * coord[k, 1] \
                            + rot_mat[i, j, 1, 2] * coord[k, 2]
                    vec_z = rot_mat[i, j, 2, 0] * coord[k, 0] \
                            + rot_mat[i, j, 2, 1] * coord[k, 1] \
                            + rot_mat[i, j, 2, 2] * coord[k, 2]
                    coord[k, 0] = vec_x
                    coord[k, 1] = vec_y
                    coord[k, 2] = vec_z

                # Compute normal vector of plane
                x_l_sum = 0.0
                y_l_sum = 0.0
                z_l_sum = 0.0
                x_l_x_l_sum = 0.0
                x_l_y_l_sum = 0.0
                x_l_z_l_sum = 0.0
                y_l_y_l_sum = 0.0
                y_l_z_l_sum = 0.0
                for k in range(9):
                    x_l_sum = x_l_sum + coord[k, 0]
                    y_l_sum = y_l_sum + coord[k, 1]
                    z_l_sum = z_l_sum + coord[k, 2]
                    x_l_x_l_sum = x_l_x_l_sum + (coord[k, 0] * coord[k, 0])
                    x_l_y_l_sum = x_l_y_l_sum + (coord[k, 0] * coord[k, 1])
                    x_l_z_l_sum = x_l_z_l_sum + (coord[k, 0] * coord[k, 2])
                    y_l_y_l_sum = y_l_y_l_sum + (coord[k, 1] * coord[k, 1])
                    y_l_z_l_sum = y_l_z_l_sum + (coord[k, 1] * coord[k, 2])
                # Fortran-contiguous
                mat[0] = x_l_x_l_sum
                mat[3] = x_l_y_l_sum
                mat[6] = x_l_sum
                mat[1] = x_l_y_l_sum
                mat[4] = y_l_y_l_sum
                mat[7] = y_l_sum
                mat[2] = x_l_sum
                mat[5] = y_l_sum
                mat[8] = 9.0
                vec[0] = x_l_z_l_sum
                vec[1] = y_l_z_l_sum
                vec[2] = z_l_sum
                sgesv(&num, &nrhs, &mat[0], &lda, &ipiv[0], &vec[0], &ldb,
                      &info)
                vec[2] = -1.0

                vec_x = vec[0]
                vec_y = vec[1]
                vec_z = vec[2]

                # Normalise vector
                vec_mag = sqrt(vec_x ** 2 + vec_y ** 2 + vec_z ** 2)
                vec_x = vec_x / vec_mag
                vec_y = vec_y / vec_mag
                vec_z = vec_z / vec_mag

                # Reverse orientation of plane's normal vector (if necessary)
                if vec_z < 0.0:
                    vec_x = vec_x * -1.0
                    vec_y = vec_y * -1.0
                    vec_z = vec_z * -1.0

                vec_tilt[i, j, 0] = vec_x
                vec_tilt[i, j, 1] = vec_y
                vec_tilt[i, j, 2] = vec_z

    return np.asarray(vec_tilt)


# -----------------------------------------------------------------------------

def slope_vector_meth(float[:, :] x, float[:, :] y, float[:, :] z,
                      float[:, :, :, :] rot_mat=np.empty((0, 0, 3, 3),
                                                         dtype=np.float32)):
    """Vector-based slope computation.

    Compute surface slope of DEM from central and 4 neighbouring grid cells.
    Vector-based method that averages the surface normals of the 4 adjacent
    triangles. Concept based on Corripio (2003).

    Parameters
    ----------
    x : ndarray of float
        Array (two-dimensional) with x-coordinates [metre]
    y : ndarray of float
        Array (two-dimensional) with y-coordinates [metre]
    z : ndarray of float
        Array (two-dimensional) with z-coordinates [metre]
    rot_mat: ndarray of float, optional
        Array (four-dimensional) with rotation matrix (y, x, 3, 3) to transform
        coordinates to a local coordinate system in which the z-axis aligns
        with local up

    Returns
    -------
    vec_tilt : ndarray of float
        Array (three-dimensional) with titled surface normal components
        (y, x, components) [metre]

    References
    ----------
    - Javier G. Corripio (2003): Vectorial algebra algorithms for calculating
      terrain parameters from DEMs and solar radiation modelling in mountainous
      terrain, International Journal of Geographical Information Science,
      17:1, 1-23."""

    cdef int len_0 = x.shape[0]
    cdef int len_1 = x.shape[1]
    cdef int i, j
    cdef float vec_x, vec_y, vec_z, vec_mag
    cdef float a_x, a_y, a_z, b_x, b_y, b_z, c_x, c_y, c_z, d_x, d_y, d_z
    cdef float[:, :, :] vec_tilt = np.empty((len_0, len_1, 3),
                                            dtype=np.float32)

    # Initialise array
    vec_tilt[:] = NAN

    # Loop through grid cells
    # for i in range(1, (len_0 - 1)):
    for i in prange(1, (len_0 - 1), nogil=True, schedule="static"):
        for j in range(1, (len_1 - 1)):

            # Compute normal vector of plane (average of 4 triangles)
            a_x = x[i, j - 1] - x[i, j]
            a_y = y[i, j - 1] - y[i, j]
            a_z = z[i, j - 1] - z[i, j]
            b_x = x[i + 1, j] - x[i, j]
            b_y = y[i + 1, j] - y[i, j]
            b_z = z[i + 1, j] - z[i, j]
            c_x = x[i, j + 1] - x[i, j]
            c_y = y[i, j + 1] - y[i, j]
            c_z = z[i, j + 1] - z[i, j]
            d_x = x[i - 1, j] - x[i, j]
            d_y = y[i - 1, j] - y[i, j]
            d_z = z[i - 1, j] - z[i, j]
            # ((a x b) + (b x c) + (c x d) + (d x a))) / 4.0
            vec_x = ((a_y * b_z - a_z * b_y)
                     + (b_y * c_z - b_z * c_y)
                     + (c_y * d_z - c_z * d_y)
                     + (d_y * a_z - d_z * a_y)) / 4.0
            vec_y = ((a_z * b_x - a_x * b_z)
                     + (b_z * c_x - b_x * c_z)
                     + (c_z * d_x - c_x * d_z)
                     + (d_z * a_x - d_x * a_z)) / 4.0
            vec_z = ((a_x * b_y - a_y * b_x)
                     + (b_x * c_y - b_y * c_x)
                     + (c_x * d_y - c_y * d_x)
                     + (d_x * a_y - d_y * a_x)) / 4.0

            # Normalise vector
            vec_mag = sqrt(vec_x ** 2 + vec_y ** 2 + vec_z ** 2)
            vec_x = vec_x / vec_mag
            vec_y = vec_y / vec_mag
            vec_z = vec_z / vec_mag

            # Reverse orientation of plane's normal vector (if necessary)
            if vec_z < 0.0:
                vec_x = vec_x * -1.0
                vec_y = vec_y * -1.0
                vec_z = vec_z * -1.0

            vec_tilt[i, j, 0] = vec_x
            vec_tilt[i, j, 1] = vec_y
            vec_tilt[i, j, 2] = vec_z

    # Rotate output vectors
    if rot_mat.shape[0] != 0:
        printf("Rotate output vectors\n")

        # for i in range(1, (len_0 - 1)):
        for i in prange(1, (len_0 - 1), nogil=True, schedule="static"):
            for j in range(1, (len_1 - 1)):
                vec_x = rot_mat[i, j, 0, 0] * vec_tilt[i, j, 0] \
                        + rot_mat[i, j, 0, 1] * vec_tilt[i, j, 1] \
                        + rot_mat[i, j, 0, 2] * vec_tilt[i, j, 2]
                vec_y = rot_mat[i, j, 1, 0] * vec_tilt[i, j, 0] \
                        + rot_mat[i, j, 1, 1] * vec_tilt[i, j, 1] \
                        + rot_mat[i, j, 1, 2] * vec_tilt[i, j, 2]
                vec_z = rot_mat[i, j, 2, 0] * vec_tilt[i, j, 0] \
                        + rot_mat[i, j, 2, 1] * vec_tilt[i, j, 1] \
                        + rot_mat[i, j, 2, 2] * vec_tilt[i, j, 2]
                vec_tilt[i, j, 0] = vec_x
                vec_tilt[i, j, 1] = vec_y
                vec_tilt[i, j, 2] = vec_z

    return np.asarray(vec_tilt)


# -----------------------------------------------------------------------------

def sky_view_factor(float[:] azim, float[:, :, :] hori,
    float[:, :, :] vec_tilt):
    """Sky view factor (SVF) computation.

    Compute sky view factor (SVF) in local horizontal coordinate system. The
    SVF is defined as the fraction of sky radiation received at a certain
    location in case of isotropic sky radiation.

    Parameters
    ----------
    azim : ndarray of float
        Array (one-dimensional) with azimuth [radian]
    hori : ndarray of float
        Array (three-dimensional) with horizon (y, x, azim) [radian]
    vec_tilt : ndarray of float
        Array (three-dimensional) with titled surface normal components
        (y, x, components) [metre]

    Returns
    -------
    svf : ndarray of float
        Array (two-dimensional) with sky view factor [-]"""

    cdef int len_0 = hori.shape[0]
    cdef int len_1 = hori.shape[1]
    cdef int len_2 = hori.shape[2]
    cdef int i, j, k
    cdef float azim_spac
    cdef float agg, hori_plane, hori_elev
    cdef float[:, :] svf = np.empty((len_0, len_1), dtype=np.float32)
    cdef float[:] azim_sin = np.empty(len_2, dtype=np.float32)
    cdef float[:] azim_cos = np.empty(len_2, dtype=np.float32)

    # Precompute values of trigonometric functions
    for i in range(len_2):
        azim_sin[i] = sin(azim[i])
        azim_cos[i] = cos(azim[i])
    # -> these arrays can be shared between threads (read-only)

    # Compute sky view factor
    azim_spac = (azim[1] - azim[0])
    for i in prange(len_0, nogil=True, schedule="static"):
        for j in range(len_1):

            # Iterate over azimuth directions
            agg = 0.0
            for k in range(len_2):

                # Compute plane-sphere intersection
                hori_plane = atan(- azim_sin[k] * vec_tilt[i, j, 0]
                                  / vec_tilt[i, j, 2]
                                  - azim_cos[k] * vec_tilt[i, j, 1]
                                  / vec_tilt[i, j, 2])
                if hori[i, j, k] >= hori_plane:
                    hori_elev = hori[i, j, k]
                else:
                    hori_elev =  hori_plane

                # Compute inner integral
                agg = agg + ((vec_tilt[i, j, 0] * azim_sin[k]
                              + vec_tilt[i, j, 1] * azim_cos[k])
                             * ((M_PI / 2.0) - hori_elev
                                - (sin(2.0 * hori_elev) / 2.0))
                             + vec_tilt[i, j, 2] * cos(hori_elev) ** 2)

            svf[i, j] = (azim_spac / (2.0 * M_PI)) * agg

    return np.asarray(svf)


# -----------------------------------------------------------------------------

def visible_sky_fraction(float[:] azim, float[:, :, :] hori,
    float[:, :, :] vec_tilt):
    """Visible sky fraction (VSF) computation.

    Compute visible sky fraction (VSF) in local horizontal coordinate system.
    The visible sky fraction is defined as the solid angle of the visible sky.

    Parameters
    ----------
    azim : ndarray of float
        Array (one-dimensional) with azimuth [radian]
    hori : ndarray of float
        Array (three-dimensional) with horizon (y, x, azim) [radian]
    vec_tilt : ndarray of float
        Array (three-dimensional) with titled surface normal components
        (y, x, components) [metre]

    Returns
    -------
    vsf : ndarray of float
        Array (two-dimensional) with Visible Sky Fraction [-]"""

    cdef int len_0 = hori.shape[0]
    cdef int len_1 = hori.shape[1]
    cdef int len_2 = hori.shape[2]
    cdef int i, j, k
    cdef float azim_spac
    cdef float agg, hori_plane, hori_elev
    cdef float[:, :] vsf = np.empty((len_0, len_1), dtype=np.float32)
    cdef float[:] azim_sin = np.empty(len_2, dtype=np.float32)
    cdef float[:] azim_cos = np.empty(len_2, dtype=np.float32)

    # Precompute values of trigonometric functions
    for i in range(len_2):
        azim_sin[i] = sin(azim[i])
        azim_cos[i] = cos(azim[i])
    # -> these arrays can be shared between threads (read-only)

    # Compute visible sky fraction
    azim_spac = (azim[1] - azim[0])
    for i in prange(len_0, nogil=True, schedule="static"):
        for j in range(len_1):

            # Iterate over azimuth directions
            agg = 0.0
            for k in range(len_2):

                # Compute plane-sphere intersection
                hori_plane = atan(- azim_sin[k] * vec_tilt[i, j, 0]
                                  / vec_tilt[i, j, 2]
                                  - azim_cos[k] * vec_tilt[i, j, 1]
                                  / vec_tilt[i, j, 2])
                if hori[i, j, k] >= hori_plane:
                    hori_elev = hori[i, j, k]
                else:
                    hori_elev = hori_plane

                # Compute inner integral
                agg = agg + (1.0 - cos((M_PI / 2.0) - hori_elev))

            vsf[i, j] = (azim_spac / (2.0 * M_PI)) * agg

    return np.asarray(vsf)


# -----------------------------------------------------------------------------

def topographic_openness(float[:] azim, float[:, :, :] hori):
    """Topographic openness (positive) computation.

    Compute positive topographic openness. The definition is based on
    Yokoyama et al. (2002).

    Parameters
    ----------
    azim : ndarray of float
        Array (one-dimensional) with azimuth [radian]
    hori : ndarray of float
        Array (three-dimensional) with horizon (y, x, azim) [radian]

    Returns
    -------
    top : ndarray of float
        Array (two-dimensional) with positive topographic openness [radian]

    References
    ----------
    - Yokoyama, R., Shirasawa, M., & Pike, R. J. (2002): Visualizing Topography
      by Openness: A New Application of Image Processing to Digital Elevation
      Models, Photogrammetric Engineering and Remote Sensing, 68, 257-265."""

    cdef int len_0 = hori.shape[0]
    cdef int len_1 = hori.shape[1]
    cdef int len_2 = hori.shape[2]
    cdef int i, j, k
    cdef float agg
    cdef float[:, :] top = np.empty((len_0, len_1), dtype=np.float32)

    # Compute positive topographic openness
    for i in prange(len_0, nogil=True, schedule="static"):
        for j in range(len_1):

            # Iterate over azimuth directions
            agg = 0.0
            for k in range(len_2):
                agg = agg + (M_PI / 2.0) - hori[i, j, k]
            top[i, j] = agg / float(len_2)

    return np.asarray(top)

/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright (c) 2024-2025 CodePros */

/*
 * ts_abi.h -- C ABI for the Zig time-series library (libai_ts).
 *
 * This header is consumed by the Go module devnw.dev/ts via CGO.
 *
 * ABI version 2: Added capacity parameters to output-buffer functions,
 * changed ts_lb_keogh and ts_cosine_similarity to int return + output pointer.
 */

#ifndef TS_ABI_H
#define TS_ABI_H

#ifdef __cplusplus
extern "C" {
#endif

/* Library version (returns 2). */
int ts_version(void);

/* Constrained DTW with Sakoe-Chiba band.
 * Returns 0 on success, -1 on error.
 * path_cap: maximum number of entries the path_i/path_j buffers can hold.
 *           If the path length exceeds path_cap, returns -1. */
int ts_dtw(
    const double *a, int a_len,
    const double *b, int b_len,
    int band,
    double *dist,
    int *path_i, int *path_j,
    int *path_len,
    int path_cap);

/* Derivative DTW.
 * path_cap: maximum number of entries the path_i/path_j buffers can hold. */
int ts_dtw_derivative(
    const double *a, int a_len,
    const double *b, int b_len,
    int band,
    double *dist,
    int *path_i, int *path_j,
    int *path_len,
    int path_cap);

/* Open-end DTW.
 * path_cap: maximum number of entries the path_i/path_j buffers can hold. */
int ts_dtw_open_end(
    const double *a, int a_len,
    const double *b, int b_len,
    int band,
    double *dist,
    int *path_i, int *path_j,
    int *path_len,
    int path_cap);

/* Shape DTW with local shape descriptors.
 * path_cap: maximum number of entries the path_i/path_j buffers can hold. */
int ts_dtw_shape(
    const double *a, int a_len,
    const double *b, int b_len,
    int band,
    int descriptor_len,
    double *dist,
    int *path_i, int *path_j,
    int *path_len,
    int path_cap);

/* Soft DTW (differentiable). */
int ts_soft_dtw(
    const double *a, int a_len,
    const double *b, int b_len,
    double gamma,
    double *dist);

/* LB_Keogh lower bound on DTW distance.
 * Returns 0 on success (result written to *result), -1 on error. */
int ts_lb_keogh(
    const double *a, int a_len,
    const double *b, int b_len,
    int band,
    double *result);

/* Normalized cross-correlation with lag. */
int ts_cross_correlate(
    const double *a, int a_len,
    const double *b, int b_len,
    int *lag,
    double *corr);

/* Shape-based distance (range [0, 2]). */
int ts_sbd(
    const double *a, int a_len,
    const double *b, int b_len,
    double *dist);

/* PELT change-point detection.
 * cps_cap: maximum number of entries the cps buffer can hold.
 *          If the number of change points exceeds cps_cap, returns -1. */
int ts_pelt(
    const double *values, int values_len,
    double penalty,
    int min_size,
    int *cps,
    int *cps_len,
    int cps_cap);

/* LCSS distance. */
int ts_lcss(
    const double *a, int a_len,
    const double *b, int b_len,
    double epsilon,
    int delta,
    double *dist);

/* EDR distance. */
int ts_edr(
    const double *a, int a_len,
    const double *b, int b_len,
    double epsilon,
    double *dist);

/* ERP distance. */
int ts_erp(
    const double *a, int a_len,
    const double *b, int b_len,
    double gap_value,
    double *dist);

/* TWED distance. */
int ts_twed(
    const double *a, int a_len,
    const double *a_times,
    const double *b, int b_len,
    const double *b_times,
    double lambda,
    double nu,
    double *dist);

/* Matrix profile and profile index.
 * out_cap: maximum number of entries the profile/indices buffers can hold.
 *          Profile length is (values_len - window_len + 1).
 *          If profile length exceeds out_cap, returns -1. */
int ts_matrix_profile(
    const double *values, int values_len,
    int window_len,
    double *profile,
    int *indices,
    int *profile_len,
    int out_cap);

/* Matrix Profile distance between two series. */
int ts_mp_dist(
    const double *a, int a_len,
    const double *b, int b_len,
    int window_len,
    double *dist);

/* 22-element feature vector extraction.
 * The features buffer must hold at least 22 doubles. */
int ts_extract_features(
    const double *values, int values_len,
    double *features);

/* Cosine similarity between two vectors.
 * Returns 0 on success (result written to *result), -1 on error. */
int ts_cosine_similarity(
    const double *a,
    const double *b,
    int len,
    double *result);

#ifdef __cplusplus
}
#endif

#endif /* TS_ABI_H */

/*******************************************************************************
* Copyright 2020-2021 Intel Corporation
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*******************************************************************************/

#define VECT_DT_N VECT_SIZE

#include "gpu/ocl/ocl_types.h"

#define HAS_STAT_SP_TAIL (STAT_SP_TAIL != STAT_SP_NBLOCKS)
#define HAS_SP_TAIL (SP != SP_TAIL)

#define LOAD_FLOAT_1x16(ptr) \
    as_float(intel_sub_group_block_read((const __global uint *)(ptr)));

#define LOAD_UINT_1x16(ptr) \
    as_uint(intel_sub_group_block_read((const __global uint *)(ptr)));

#define LOAD_UINT_8x16(ptr) \
    convert_uint8(as_uint8( \
            intel_sub_group_block_read8((const __global uint *)(ptr))))

#define LOAD_CHAR_1x16(ptr) \
    as_char(intel_sub_group_block_read_uc((const __global uchar *)(ptr)));

#define LOAD_CHAR_8x16(ptr) \
    convert_char8(as_char8( \
            intel_sub_group_block_read_uc8((const __global uchar *)(ptr))))

#define LOAD_DATA_1x16(ptr) \
    CONVERT_FLOAT_T(AS_DATA_T(BLOCK_READ((const __global BLOCK_DATA_T *)(ptr))))

#define LOAD_DATA_8x16(ptr) \
    CONVERT_FLOAT8_T( \
            AS_DATA8_T(BLOCK_READ8((const __global BLOCK_DATA_T *)(ptr))))

#define STORE_DATA_1x16(ptr, val) \
    BLOCK_WRITE((__global BLOCK_DATA_T *)(ptr), \
            AS_BLOCK_DATA_T(CONVERT_DATA_T(val)));

#define STORE_DATA_8x16(ptr, val) \
    BLOCK_WRITE8((__global BLOCK_DATA_T *)ptr, \
            AS_BLOCK_DATA8_T(CONVERT_DATA8_T(val)))

#define STORE_FLOAT_1x16(ptr, val) \
    intel_sub_group_block_write((__global uint *)(ptr), as_uint(val));

#define STORE_FLOAT_8x16(ptr, val) \
    intel_sub_group_block_write8((__global uint *)(ptr), as_uint8(val));

#define STORE_CHAR_1x16(ptr, val) \
    intel_sub_group_block_write_uc((__global uchar *)(ptr), as_uchar(val));

#define STORE_CHAR_8x16(ptr, val) \
    intel_sub_group_block_write_uc8((__global uchar *)(ptr), as_uchar8(val));

#if USE_NHWC
#define IC_BLOCK_STRIDE IC
#else
#define IC_BLOCK_STRIDE 16
#endif

#if IS_FWD

void gen9_reduce_common(__global float *reduce_temp, __local float *local_sum,
        __global float *dst) {
    const int ic_sub_group = get_global_id(0) / 16;
    const int group_c = get_global_id(1);
    const int simd_id = get_sub_group_local_id();
    const int c = group_c * 16 + simd_id;
    float sum = 0.0f;

    reduce_temp
            += REDUCE_STAT_NBLOCKS / REDUCE_IC_SUB_GROUPS * 16 * ic_sub_group
            + REDUCE_STAT_NBLOCKS * 16 * group_c + simd_id;
    for (int i = 0; i < REDUCE_STAT_NBLOCKS / REDUCE_IC_SUB_GROUPS; i++) {
        sum += reduce_temp[i * 16];
    }

    if (ic_sub_group > 0) { local_sum[ic_sub_group * 16 + simd_id] = sum; }
    barrier(CLK_LOCAL_MEM_FENCE);
    if (ic_sub_group == 0 && c < IC) {
        for (int i = 1; i < REDUCE_IC_SUB_GROUPS; i++) {
            sum += local_sum[i * 16 + simd_id];
        }
        dst[c] = sum / (MB * ID * IH * IW);
    }
}

NAMED_KERNEL_ATTR(CALC)
__kernel void gen9_calc_mean(
        __global DATA_T *src, __global float *reduce_temp) {
    const int mb = GWS_GET_STAT_MB();
    const int c = GWS_GET_STAT_IC();
    const int sp_block_idx = GWS_GET_STAT_SP();
    const int mb_sp_idx = mb * STAT_SP_NBLOCKS + sp_block_idx;
    const int group_c_offset = REDUCE_STAT_NBLOCKS * 16 * (int)(c / 16);
    const int simd_id = get_sub_group_local_id();

#if USE_NHWC
    src += c + sp_block_idx * STAT_SP_BLOCK * IC;
#else
    src += (c & 15) + sp_block_idx * STAT_SP_BLOCK * 16 + (c & ~15) * SP
            + mb * SP * IC_PADDED;
#endif

    float8 res0 = 0.0f, res1 = 0.0f;
    float v_mean = 0.0f;

#if HAS_STAT_SP_TAIL
    if (sp_block_idx == STAT_SP_TAIL) {
        int sp = SP - STAT_SP_TAIL * STAT_SP_BLOCK;
        while (sp >= 16) {
#if USE_NHWC
            float8 s0, s1;
            for (int k = 0; k < 8; ++k)
                s0[k] = LOAD_DATA_1x16(&src[k * IC]);
            for (int k = 0; k < 8; ++k)
                s1[k] = LOAD_DATA_1x16(&src[(k + 8) * IC]);
#else
            float8 s0 = LOAD_DATA_8x16(&src[0]);
            float8 s1 = LOAD_DATA_8x16(&src[8 * 16]);
#endif
            res0 += s0;
            res1 += s1;

            src += 16 * IC_BLOCK_STRIDE;
            sp -= 16;
        }
        while (sp >= 1) {
            float s0 = LOAD_DATA_1x16(&src[0]);
            v_mean += s0;
            src += IC_BLOCK_STRIDE;
            --sp;
        }
    } else
#endif
    {
        for (int sp = 0; sp < STAT_SP_BLOCK / 16; ++sp) {
#if USE_NHWC
            float8 s0, s1;
            for (int k = 0; k < 8; ++k)
                s0[k] = LOAD_DATA_1x16(&src[k * IC]);
            for (int k = 0; k < 8; ++k)
                s1[k] = LOAD_DATA_1x16(&src[(k + 8) * IC]);
#else
            float8 s0 = LOAD_DATA_8x16(&src[0]);
            float8 s1 = LOAD_DATA_8x16(&src[8 * 16]);
#endif
            res0 += s0;
            res1 += s1;
            src += 16 * IC_BLOCK_STRIDE;
        }
    }

    for (int i = 0; i < 8; i++) {
        v_mean += res0[i] + res1[i];
    }

    STORE_FLOAT_1x16(
            &reduce_temp[group_c_offset + mb_sp_idx * 16 + simd_id], v_mean);
}

NAMED_KERNEL_ATTR(REDUCE)
__kernel void gen9_reduce_mean(
        __global float *reduce_temp, __global float *mean) {
    __local float local_sum[16 * REDUCE_IC_SUB_GROUPS];
    gen9_reduce_common(reduce_temp, local_sum, mean);
}

NAMED_KERNEL_ATTR(CALC)
__kernel void gen9_calc_variance(__global DATA_T *src, __global float *mean,
        __global float *reduce_temp) {
    const int mb = GWS_GET_STAT_MB();
    const int c = GWS_GET_STAT_IC();
    const int sp_block_idx = GWS_GET_STAT_SP();
    const int mb_sp_idx = mb * STAT_SP_NBLOCKS + sp_block_idx;
    const int group_c_offset = REDUCE_STAT_NBLOCKS * 16 * (int)(c / 16);
    const int simd_id = get_sub_group_local_id();
    const bool out_of_range = (c + simd_id) >= IC ? true : false;
    const bool tail_channel = (c + get_sub_group_size()) > IC ? true : false;

    reduce_temp += REDUCE_STAT_NBLOCKS * IC_PADDED;

#if USE_NHWC
    src += c + sp_block_idx * STAT_SP_BLOCK * IC;
#else
    src += (c & 15) + sp_block_idx * STAT_SP_BLOCK * 16 + (c & ~15) * SP
            + mb * SP * IC_PADDED;
#endif

    float8 res0 = 0.0f, res1 = 0.0f;
    float v_var = 0.0f;

    float v_mean = 0.0f;

    if (!tail_channel) {
        v_mean = LOAD_FLOAT_1x16(&mean[c]);
    } else if (!out_of_range) {
        v_mean = mean[c + simd_id];
    }

#if HAS_STAT_SP_TAIL
    if (sp_block_idx == STAT_SP_TAIL) {
        int sp = SP - STAT_SP_TAIL * STAT_SP_BLOCK;
        while (sp >= 16) {
#if USE_NHWC
            float8 s0, s1;
            for (int k = 0; k < 8; ++k)
                s0[k] = LOAD_DATA_1x16(&src[k * IC_PADDED]);
            for (int k = 0; k < 8; ++k)
                s1[k] = LOAD_DATA_1x16(&src[(k + 8) * IC_PADDED]);
#else
            float8 s0 = LOAD_DATA_8x16(&src[0]);
            float8 s1 = LOAD_DATA_8x16(&src[8 * 16]);
#endif
            float8 v0 = s0 - v_mean;
            float8 v1 = s1 - v_mean;
            res0 = fma(v0, v0, res0);
            res1 = fma(v1, v1, res1);

            src += 16 * IC_BLOCK_STRIDE;
            sp -= 16;
        }
        while (sp >= 1) {
            float s0 = LOAD_DATA_1x16(&src[0]);
            float v0 = s0 - v_mean;
            v_var = fma(v0, v0, v_var);

            src += IC_BLOCK_STRIDE;
            --sp;
        }
    } else
#endif // HAS_STAT_SP_TAIL
    {
        for (int sp = 0; sp < STAT_SP_BLOCK / 16; ++sp) {
#if USE_NHWC
            float8 s0, s1;
            for (int k = 0; k < 8; ++k)
                s0[k] = LOAD_DATA_1x16(&src[k * IC_PADDED]);
            for (int k = 0; k < 8; ++k)
                s1[k] = LOAD_DATA_1x16(&src[(k + 8) * IC_PADDED]);
#else
            float8 s0 = LOAD_DATA_8x16(&src[0]);
            float8 s1 = LOAD_DATA_8x16(&src[8 * 16]);
#endif
            float8 v0 = s0 - v_mean;
            float8 v1 = s1 - v_mean;
            res0 = fma(v0, v0, res0);
            res1 = fma(v1, v1, res1);

            src += 16 * IC_BLOCK_STRIDE;
        }
    }

    for (int i = 0; i < 8; i++) {
        v_var += res0[i] + res1[i];
    }

    STORE_FLOAT_1x16(
            &reduce_temp[group_c_offset + mb_sp_idx * 16 + simd_id], v_var);
}

NAMED_KERNEL_ATTR(REDUCE)
__kernel void gen9_reduce_variance(
        __global float *reduce_temp, __global float *variance) {
    __local float local_sum[16 * REDUCE_IC_SUB_GROUPS];
    gen9_reduce_common(
            reduce_temp + REDUCE_STAT_NBLOCKS * IC_PADDED, local_sum, variance);
}

__kernel void gen9_bnorm_fwd(__global DATA_T *src, __global float *mean,
        __global float *variance, __global DATA_T *dst,
        __global float *scaleshift, __global float *shift, __global char *ws,
        float eps) {
    const int n = GWS_GET_MB();
    const int c = GWS_GET_IC();
    const int sp = GWS_GET_SP() * VECT_SIZE;
    const int simd_id = get_sub_group_local_id();
    const bool out_of_range = (c + simd_id) >= IC ? true : false;
    const bool tail_channel = (c + get_sub_group_size()) > IC ? true : false;

#if USE_NHWC
    const uint d_off = sp * IC + c;
#else
    const uint d_off = (c & 15) + sp * 16 + (c & ~15) * SP + n * SP * IC_PADDED;
#endif
    src += d_off;
    dst += d_off;

    float8 blockS0 = 0.0f, blockD0;
#if HAS_SP_TAIL
    if (sp == SP_TAIL) {
        for (int k = 0; k < SP - SP_TAIL; ++k)
            blockS0[k] = LOAD_DATA_1x16(&src[k * IC_BLOCK_STRIDE]);
    } else
#endif // HAS_SP_TAIL
    {
#if USE_NHWC
        for (int k = 0; k < 8; ++k)
            blockS0[k] = LOAD_DATA_1x16(&src[k * IC_PADDED]);
#else
        blockS0 = LOAD_DATA_8x16(&src[0]);
#endif
    }

    float sm = 0.0f;
    float sv = 0.0f;
    float v_mean = 0.0f;
    float v_variance = 0.0f;

    if (!tail_channel) {
#if USE_SCALESHIFT == 1
        sm = LOAD_FLOAT_1x16(&scaleshift[c]);
        sv = LOAD_FLOAT_1x16(&scaleshift[IC + c]);
#else
#if USE_SCALE == 1
        sm = LOAD_FLOAT_1x16(&scaleshift[c]);
#else
        sm = 1.0f;
#endif
#if USE_SHIFT == 1
        sv = LOAD_FLOAT_1x16(&shift[c]);
#else
        sv = 0.0f;
#endif
#endif
        v_mean = LOAD_FLOAT_1x16(&mean[c]);
        v_variance = LOAD_FLOAT_1x16(&variance[c]);

    } else if (!out_of_range) {
#if USE_SCALESHIFT == 1
        sm = scaleshift[c + simd_id];
        sv = scaleshift[IC + c + simd_id];
#else
#if USE_SCALE == 1
        sm = scaleshift[c + simd_id];
#else
        sm = 1.0f;
#endif
#if USE_SHIFT == 1
        sv = shift[c + simd_id];
#else
        sv = 0.0f;
#endif
#endif
        v_mean = mean[c + simd_id];
        v_variance = variance[c + simd_id];
    }

    float sqrt_variance = sm / sqrt(v_variance + eps);

    blockD0 = fma(blockS0 - (float8)v_mean, (float8)sqrt_variance, (float8)sv);

#if FUSE_BN_RELU
    int8 blockWS0 = isgreater(blockD0, (float8)0.0f);
    blockD0 = select((float8)0.0f, blockD0, blockWS0);
#if IS_TRAINING
    ws += d_off;
#if HAS_SP_TAIL
    if (sp == SP_TAIL) {
        for (int k = 0; k < SP - SP_TAIL; ++k) {
            STORE_CHAR_1x16(
                    &ws[k * IC_BLOCK_STRIDE], convert_char(blockWS0[k]));
        }
    } else
#endif // HAS_SP_TAIL
    {
#if USE_NHWC
        for (int k = 0; k < 8; ++k)
            STORE_CHAR_1x16(
                    &ws[k * IC_BLOCK_STRIDE], convert_char(blockWS0[k]));
#else
        STORE_CHAR_8x16(&ws[0], convert_char8(blockWS0));
#endif
    }
#endif // IS_TRAINING
#endif // FUSE_BN_RELU

#if WITH_RELU
    blockD0 = max(blockD0, (VECT_FLOAT_T)0.0f);
#endif

#if HAS_SP_TAIL
    if (sp == SP_TAIL) {
        for (int k = 0; k < SP - SP_TAIL; ++k) {
            STORE_DATA_1x16(&dst[k * IC_BLOCK_STRIDE], blockD0[k]);
            printf("%d, %d, %f\n", d_off, k, blockD0[k]);
        }
    } else
#endif // HAS_SP_TAIL
    {
#if USE_NHWC
        for (int k = 0; k < 8; ++k)
            STORE_DATA_1x16(&dst[k * IC_BLOCK_STRIDE], blockD0[k]);
#else
        STORE_DATA_8x16(&dst[0], blockD0);
#endif
    }
}

#endif // IS_FWD

#if IS_BWD == 1

#define LOAD_DATA_Nx16_USING_LOOP(n, dest, src) \
    { \
        for (int k = 0; k < n; ++k) { \
            dest[k] = LOAD_DATA_1x16(&src[k * IC_BLOCK_STRIDE]); \
        } \
    }

#define LOAD_UINT_Nx16_USING_LOOP(n, dest, src) \
    { \
        for (int k = 0; k < n; ++k) { \
            dest[k] = LOAD_UINT_1x16(&src[k * IC_BLOCK_STRIDE]); \
        } \
    }

#define LOAD_CHAR_Nx16_USING_LOOP(n, dest, src) \
    { \
        for (int k = 0; k < n; ++k) { \
            dest[k] = LOAD_CHAR_1x16(&src[k * IC_BLOCK_STRIDE]); \
        } \
    }

#define LOAD_DATA_8x16_USING_LAYOUT(dest, src) \
    { \
        if (USE_NHWC) { \
            LOAD_DATA_Nx16_USING_LOOP(8, dest, src); \
        } else { \
            dest = LOAD_DATA_8x16(src); \
        } \
    }

#define LOAD_UINT_8x16_USING_LAYOUT(dest, src) \
    { \
        if (USE_NHWC) { \
            LOAD_UINT_Nx16_USING_LOOP(8, dest, src); \
        } else { \
            dest = LOAD_UINT_8x16(src); \
        } \
    }

#define LOAD_CHAR_8x16_USING_LAYOUT(dest, src) \
    { \
        if (USE_NHWC) { \
            LOAD_CHAR_Nx16_USING_LOOP(8, dest, src); \
        } else { \
            dest = LOAD_CHAR_8x16(src); \
        } \
    }

NAMED_KERNEL_ATTR(CALC)
__kernel void gen9_calculate_stats(__global DATA_T *src, __global float *mean,
        __global DATA_T *diff_dst, __global char *ws,
        __global float *diff_scaleshift) {
    const int mb = GWS_GET_STAT_MB();
    const int c = GWS_GET_STAT_IC();
    const int sp_block_idx = GWS_GET_STAT_SP();
    const int mb_sp_idx = mb * STAT_SP_NBLOCKS + sp_block_idx;
    const int group_c_offset = REDUCE_STAT_NBLOCKS * 16 * (int)(c / 16);
    const int simd_id = get_sub_group_local_id();
    const bool out_of_range = (c + simd_id) >= IC ? true : false;
    diff_scaleshift += group_c_offset;

#if USE_NHWC
    const int offset = c + sp_block_idx * STAT_SP_BLOCK * IC_PADDED;
#else
    const int offset = (c & 15) + sp_block_idx * STAT_SP_BLOCK * 16
            + (c & ~15) * SP + mb * SP * IC_PADDED;
#endif
    src += offset;
    diff_dst += offset;
    ws += offset;

    float v_mean = 0.0f;
    if (c + get_sub_group_size() <= IC) {
        v_mean = LOAD_FLOAT_1x16(&mean[c]);
    } else if ((c + simd_id) < IC) {
        v_mean = mean[c + simd_id];
    }

    float8 diff_gamma = 0.0f;
    float8 diff_beta = 0.0f;

#if HAS_STAT_SP_TAIL
    int sp;
    if (sp_block_idx == STAT_SP_TAIL) {
        sp = SP - STAT_SP_TAIL * STAT_SP_BLOCK;
    } else {
        sp = STAT_SP_BLOCK;
    }
#else
    int sp = STAT_SP_BLOCK;
#endif

    const int C_PARALLEL_FACTOR = 8;

    for (; sp > C_PARALLEL_FACTOR - 1; sp -= C_PARALLEL_FACTOR) {
        float8 src_data;
        float8 dd_data;

#if FUSE_BN_RELU == 1
        char8 ws_data;
        LOAD_CHAR_8x16_USING_LAYOUT(ws_data, ws);
#endif // #if FUSE_BN_RELU == 1

        LOAD_DATA_8x16_USING_LAYOUT(src_data, src);
        LOAD_DATA_8x16_USING_LAYOUT(dd_data, diff_dst);

        src += C_PARALLEL_FACTOR * IC_BLOCK_STRIDE;
        diff_dst += C_PARALLEL_FACTOR * IC_BLOCK_STRIDE;
#if FUSE_BN_RELU == 1
        ws += C_PARALLEL_FACTOR * IC_BLOCK_STRIDE;
#endif // #if FUSE_BN_RELU == 1

#if FUSE_BN_RELU == 1
        const float8 C_ZERO = 0.0;
        dd_data = select(C_ZERO, dd_data, convert_int8(ws_data));
#endif // #if FUSE_BN_RELU == 1

        const float8 v0 = src_data - v_mean;
        diff_gamma = fma(v0, dd_data, diff_gamma);
        diff_beta += dd_data;
    }

#if HAS_STAT_SP_TAIL
    if (sp_block_idx == STAT_SP_TAIL) {
        sp = (SP - STAT_SP_TAIL * STAT_SP_BLOCK)
                % C_PARALLEL_FACTOR; // replace with "and 0x7" ?????
        while (sp-- >= 1) {
#if FUSE_BN_RELU == 1
            const char ws_data = LOAD_CHAR_1x16(&ws[0]);
#else
            const char ws_data = 1;
#endif // #if FUSE_BN_RELU == 1

            const float src_data = LOAD_DATA_1x16(&src[0]);
            const float dd_data = LOAD_DATA_1x16(&diff_dst[0]);

            src += IC_BLOCK_STRIDE;
            diff_dst += IC_BLOCK_STRIDE;
#if FUSE_BN_RELU == 1
            ws += IC_BLOCK_STRIDE;
#endif // #if FUSE_BN_RELU == 1

            if (ws_data != 0) {
                const float v0 = src_data - v_mean;
                const float diff_gamma_tmp = fma(v0, dd_data, diff_gamma[0]);
                diff_gamma[0] = diff_gamma_tmp;
                diff_beta[0] += dd_data;
            }
        }
    }
#endif // #if HAS_STAT_SP_TAIL

    for (int i = 1; i < 8; i++) {
        diff_gamma[0] += diff_gamma[i];
        diff_beta[0] += diff_beta[i];
    }

    STORE_FLOAT_1x16(&diff_scaleshift[mb_sp_idx * 16 + simd_id], diff_gamma[0]);
    STORE_FLOAT_1x16(&diff_scaleshift[REDUCE_STAT_NBLOCKS * IC_PADDED
                             + mb_sp_idx * 16 + simd_id],
            diff_beta[0]);
}

NAMED_KERNEL_ATTR(REDUCE)
__kernel void gen9_reduce_stats(__global float *reduce_temp,
        __global float *diff_scaleshift, __global float *diff_shift,
        __global float *variance, float eps) {
    __local float local_gamma[16 * REDUCE_IC_SUB_GROUPS];
    __local float local_beta[16 * REDUCE_IC_SUB_GROUPS];
    const int ic_sub_group = get_global_id(0) / 16;
    const int group_c = get_global_id(1);
    const int simd_id = get_sub_group_local_id();
    const int c = group_c * 16 + simd_id;
    float diff_gamma = 0.0f;
    float diff_beta = 0.0f;

    reduce_temp += REDUCE_STAT_NBLOCKS * 16 * group_c
            + REDUCE_STAT_NBLOCKS / REDUCE_IC_SUB_GROUPS * 16 * ic_sub_group
            + simd_id;
    for (int i = 0; i < REDUCE_STAT_NBLOCKS / REDUCE_IC_SUB_GROUPS; i++) {
        diff_gamma += reduce_temp[i * 16];
    }
    reduce_temp += IC_PADDED * REDUCE_STAT_NBLOCKS;
    for (int i = 0; i < REDUCE_STAT_NBLOCKS / REDUCE_IC_SUB_GROUPS; i++) {
        diff_beta += reduce_temp[i * 16];
    }

    if (ic_sub_group > 0) {
        local_gamma[ic_sub_group * 16 + simd_id] = diff_gamma;
        local_beta[ic_sub_group * 16 + simd_id] = diff_beta;
    }
    barrier(CLK_LOCAL_MEM_FENCE);
    if (ic_sub_group == 0 && c < IC) {
        for (int i = 1; i < REDUCE_IC_SUB_GROUPS; i++) {
            diff_gamma += local_gamma[i * 16 + simd_id];
            diff_beta += local_beta[i * 16 + simd_id];
        }

        float sqrt_variance = 1.0f / sqrt(variance[c] + eps);

        diff_scaleshift[c] = diff_gamma * sqrt_variance;
#if DIFF_SCALESHIFT == 1
        diff_scaleshift[IC + c] = diff_beta;
#elif DIFF_SCALE == 1 || DIFF_SHIFT == 1
        diff_shift[c] = diff_beta;
#else
        diff_scaleshift[IC_PADDED * REDUCE_STAT_NBLOCKS + c] = diff_beta;
#endif // #if DIFF_SCALESHIFT == 1
    }
}

__kernel void gen9_bnorm_bwd(__global DATA_T *src, __global float *mean,
        __global float *variance, __global DATA_T *diff_dst,
        __global float *scaleshift, __global char *ws,
        __global DATA_T *diff_src, __global float *diff_scaleshift,
        __global float *diff_shift, float eps) {
    const int c = GWS_GET_IC();
    const int simd_id = get_sub_group_local_id();
    bool out_of_range = (c + simd_id) >= IC ? true : false;
    const bool tail_channel = (c + get_sub_group_size()) > IC ? true : false;

    float v_variance = 1.0f;
    float v_mean = 0.0f;
    float diff_gamma = 0.0f;
    float diff_beta = 0.0f;
    float gamma = 0.0f;

    if (!tail_channel) {
        v_variance = LOAD_FLOAT_1x16(&variance[c]);

#if CALCULATE_DIFF_STATS == 1
        v_mean = LOAD_FLOAT_1x16(&mean[c]);
        diff_gamma = LOAD_FLOAT_1x16(&diff_scaleshift[c]);
#if DIFF_SCALESHIFT == 1
        diff_beta = LOAD_FLOAT_1x16(&diff_scaleshift[IC + c]);
#elif DIFF_SCALE == 1 || DIFF_SHIFT == 1
        diff_beta = LOAD_FLOAT_1x16(&diff_shift[c]);
#else
        diff_beta = LOAD_FLOAT_1x16(
                &diff_scaleshift[REDUCE_STAT_NBLOCKS * IC_PADDED + c]);
#endif // #if DIFF_SCALESHIFT == 1
#endif // #if CALCULATE_DIFF_STATS == 1

#if USE_SCALESHIFT == 1 || USE_SCALE == 1
        gamma = LOAD_FLOAT_1x16(&scaleshift[c]);
#else
        gamma = 1;
#endif // #if USE_SCALESHIFT == 1 || USE_SCALE == 1
    } else if (!out_of_range) {
        v_variance = variance[c + simd_id];
#if CALCULATE_DIFF_STATS == 1
        v_mean = mean[c + simd_id];
        diff_gamma = diff_scaleshift[c + simd_id];
#if DIFF_SCALESHIFT == 1
        diff_beta = diff_scaleshift[IC + c + simd_id];
#elif DIFF_SCALE == 1 || DIFF_SHIFT == 1
        diff_beta = diff_shift[c + simd_id];
#else
        diff_beta = diff_scaleshift[REDUCE_STAT_NBLOCKS * IC_PADDED + c
                + simd_id];
#endif // #if DIFF_SCALESHIFT == 1
#endif // #if CALCULATE_DIFF_STATS == 1

#if USE_SCALESHIFT == 1 || USE_SCALE == 1
        gamma = scaleshift[c + simd_id];
#else
        gamma = 1;
#endif // #if USE_SCALESHIFT == 1 || USE_SCALE == 1
    }

    const int sp_block_idx = GWS_GET_SP();
#if USE_NHWC
    const int offset = c + sp_block_idx * VECT_SIZE * IC;
#else
    const int mb = GWS_GET_MB();
    const int offset = (c & 15) + sp_block_idx * VECT_SIZE * 16 + (c & ~15) * SP
            + mb * SP * IC_PADDED;
#endif
    src += offset;
    diff_dst += offset;
    ws += offset;
    diff_src += offset;

#if HAS_SP_TAIL
    int sp;
    if (sp_block_idx == SP_TAIL / VECT_SIZE) {
        sp = SP - SP_TAIL;
    } else {
        sp = VECT_SIZE;
    }
#else
    int sp = VECT_SIZE;
#endif

    const float sqrt_variance = 1.0f / sqrt(v_variance + eps);

    const int C_PARALLEL_FACTOR = 8;
    for (; sp > C_PARALLEL_FACTOR - 1; sp -= C_PARALLEL_FACTOR) {
        float8 src_data;
        float8 dd_data;

#if FUSE_BN_RELU == 1
        char8 ws_data;
        LOAD_CHAR_8x16_USING_LAYOUT(ws_data, ws);
#endif // #if FUSE_BN_RELU == 1

        LOAD_DATA_8x16_USING_LAYOUT(dd_data, diff_dst);
        LOAD_DATA_8x16_USING_LAYOUT(src_data, src);

        src += C_PARALLEL_FACTOR * IC_BLOCK_STRIDE;
        diff_dst += C_PARALLEL_FACTOR * IC_BLOCK_STRIDE;
#if FUSE_BN_RELU == 1
        ws += C_PARALLEL_FACTOR * IC_BLOCK_STRIDE;
#endif // #if FUSE_BN_RELU == 1

#if FUSE_BN_RELU == 1
        const float8 C_ZERO = 0.0;
        dd_data = select(C_ZERO, dd_data, convert_int8(ws_data));
#endif // #if FUSE_BN_RELU == 1

#if CALCULATE_DIFF_STATS == 1
        dd_data -= (diff_beta
                           + (src_data - v_mean) * diff_gamma * sqrt_variance)
                / (MB * ID * IH * IW);
#endif // #if CALCULATE_DIFF_STATS == 1

        dd_data *= gamma * sqrt_variance;

#if USE_NHWC
        for (int k = 0; k < 8; ++k)
            STORE_DATA_1x16(&diff_src[k * IC_BLOCK_STRIDE], dd_data[k]);
#else
        STORE_DATA_8x16(&diff_src[0], dd_data);
#endif // #if USE_NHWC
        diff_src += C_PARALLEL_FACTOR * IC_BLOCK_STRIDE;
    }

#if HAS_SP_TAIL
    if (sp_block_idx == SP_TAIL / VECT_SIZE) {
        sp = (SP - SP_TAIL) % C_PARALLEL_FACTOR; // replace with "and 0x7" ?????
        while (sp-- >= 1) {
#if FUSE_BN_RELU == 1
            const char ws_data = LOAD_CHAR_1x16(&ws[0]);
#endif // #if FUSE_BN_RELU == 1

            float dd_data = LOAD_DATA_1x16(&diff_dst[0]);
#if CALCULATE_DIFF_STATS == 1
            const float src_data = LOAD_DATA_1x16(&src[0]);
#endif // #if CALCULATE_DIFF_STATS == 1

            src += IC_BLOCK_STRIDE;
            diff_dst += IC_BLOCK_STRIDE;
#if FUSE_BN_RELU == 1
            ws += IC_BLOCK_STRIDE;
#endif // #if FUSE_BN_RELU == 1

#if FUSE_BN_RELU == 1
            if (ws_data == 0) dd_data = 0;
#endif // #if FUSE_BN_RELU == 1

#if CALCULATE_DIFF_STATS == 1
            dd_data -= (diff_beta
                               + (src_data - v_mean) * diff_gamma
                                       * sqrt_variance)
                    / (MB * ID * IH * IW);
#endif // #if CALCULATE_DIFF_STATS == 1

            dd_data *= gamma * sqrt_variance;

            STORE_DATA_1x16(&diff_src[0], dd_data);
            diff_src += IC_BLOCK_STRIDE;
        }
    }
#endif // #if HAS_SP_TAIL
}

#endif // IS_BWD

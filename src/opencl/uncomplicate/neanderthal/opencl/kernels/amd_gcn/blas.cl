#ifndef REAL
    #define REAL float
#endif

#ifndef WGS
    #define WGS 256
#endif

#ifndef WGSm
    #define WGSm 16
#endif

#ifndef WGSn
    #define WGSn 16
#endif

#ifndef TS
   #define TS 32
#endif

#ifndef WPT
    #define WPT 4
#endif

#define RTS (TS/WPT)
//|||||||||||||||||       BLAS 1       |||||||||||||||||||||||||||||||||||||||||

// ================ Embarassingly parallel kernels =============================

__attribute__((reqd_work_group_size(WGS, 1, 1)))
__kernel void swp (__global REAL* x, __global REAL* y) {
    uint gid = get_global_id(0);
    REAL temp = x[gid];
    x[gid] = y[gid];
    y[gid] = temp;
}

__attribute__((reqd_work_group_size(WGS, 1, 1)))
__kernel void scal (const REAL alpha, __global REAL* x) {
    uint gid = get_global_id(0);
    x[gid] = alpha * x[gid];
}

__attribute__((reqd_work_group_size(WGS, 1, 1)))
__kernel void axpy (const REAL alpha, __global const REAL* x,
                    __global REAL* y) {
    uint gid = get_global_id(0);
    y[gid] = alpha * x[gid] + y[gid];
}

__attribute__((reqd_work_group_size(WGS, 1, 1)))
__kernel void axpby (const REAL alpha, __global const REAL* x,
                     const REAL beta, __global REAL* y) {
    uint gid = get_global_id(0);
    y[gid] = alpha * x[gid] + beta * y[gid];
}

// ================= Sum reduction =============================================

inline void work_group_reduction_sum (__global double* acc, const double value) {

    uint local_size = get_local_size(0);
    uint local_id = get_local_id(0);

    __local double lacc[WGS];
    lacc[local_id] = value;

    work_group_barrier(CLK_LOCAL_MEM_FENCE);

    double pacc = value;
    uint i = local_size;
    while (i > 0) {
        bool include_odd = (i > ((i >> 1) << 1)) && (local_id == ((i >> 1) - 1));
        i >>= 1;
        if (include_odd) {
            pacc += lacc[local_id + i + 1];
        }
        if (local_id < i) {
            pacc += lacc[local_id + i];
            lacc[local_id] = pacc;
        }
        work_group_barrier(CLK_LOCAL_MEM_FENCE);
    }

    if(local_id == 0) {
        acc[get_group_id(0)] = pacc;
    }
}

__attribute__((reqd_work_group_size(WGS, 1, 1)))
__kernel void sum_reduction (__global double* acc) {
    work_group_reduction_sum(acc, acc[get_global_id(0)]);
}

// ================== Dot product ==============================================
__attribute__((reqd_work_group_size(WGS, 1, 1)))
__kernel void dot_reduce (__global double* acc,
                          __global const REAL* x, __global const REAL* y) {
    uint gid = get_global_id(0);
    work_group_reduction_sum(acc, (double)(x[gid] * y[gid]));
}

// ================== asum =====================================================
__attribute__((reqd_work_group_size(WGS, 1, 1)))
__kernel void asum_reduce (__global double* acc, __global const REAL* x) {
    work_group_reduction_sum(acc, (double)fabs(x[get_global_id(0)]));
}

// ================== sum =====================================================
__attribute__((reqd_work_group_size(WGS, 1, 1)))
__kernel void sum_reduce (__global double* acc, __global const REAL* x) {
    work_group_reduction_sum(acc, (double)x[get_global_id(0)]);
}

// ================== nrm2 =====================================================

__attribute__((reqd_work_group_size(WGS, 1, 1)))
__kernel void nrm2_reduce (__global double* acc, __global const REAL* x) {
    work_group_reduction_sum(acc, (double)pown(x[get_global_id(0)], 2));
}

// ================ Max reduction ==============================================
inline void work_group_reduction_imax (__global uint* iacc,
                                       __global double* vacc,
                                       uint const ind, const double val) {

    uint local_id = get_local_id(0);
    uint local_size = get_local_size(0);

    __local uint liacc[WGS];
    __local double lvacc[WGS];
    liacc[local_id] = ind;
    lvacc[local_id] = val;

    work_group_barrier(CLK_LOCAL_MEM_FENCE);

    uint index = ind;
    double value = val;

    uint i = local_size;
    while (i > 0) {
        bool include_odd = (i > ((i >> 1) << 1)) && (local_id == ((i >> 1) - 1));
        i >>= 1;
        if (include_odd) {
            double other_value = lvacc[local_id + i + 1];
            if (other_value > value) {
                value = other_value;
                index = liacc[local_id + i + 1];
                lvacc[local_id] = value;
                liacc[local_id] = index;
            }
        }
        if (local_id < i) {
            double other_value = lvacc[local_id + i];
            if (other_value > value) {
                value = other_value;
                index = liacc[local_id + i];
                lvacc[local_id] = value;
                liacc[local_id] = index;
            }
        }
        work_group_barrier(CLK_LOCAL_MEM_FENCE);
    }

    if(local_id == 0) {
        uint group_id = get_group_id(0);
        iacc[group_id] = index;
        vacc[group_id] = value;
    }

}

__attribute__((reqd_work_group_size(WGS, 1, 1)))
__kernel void imax_reduction (__global uint* iacc, __global double* vacc) {
    uint gid = get_global_id(0);
    work_group_reduction_imax(iacc, vacc, iacc[gid], (double)(vacc[gid]));
}

// ================== iamax reduce  ============================================

__attribute__((reqd_work_group_size(WGS, 1, 1)))
__kernel void iamax_reduce (__global uint* iacc, __global double* vacc,
                            __global const REAL* x) {
    uint gid = get_global_id(0);
    work_group_reduction_imax(iacc, vacc, gid, (double)(fabs(x[gid])));
}

// ||||||||||||||||       BLAS 2      ||||||||||||||||||||||||||||||||||||||||||

// ================== GEMV =====================================================

inline void work_group_reduction_sum_horizontal
(__global REAL* acc, const REAL value) {

    uint global_size_m = get_global_size(0);
    uint group_id_m = get_group_id(0);
    uint group_id_n = get_group_id(1);

    uint local_m = get_local_size(0);
    uint local_n = get_local_size(1);
    uint local_row = get_local_id(0);
    uint local_col = get_local_id(1);

    __local REAL lacc[WGSm][WGSn];
    lacc[local_row][local_col] = value;

    work_group_barrier(CLK_LOCAL_MEM_FENCE);

    REAL pacc = value;
    uint i = local_n;
    while (i > 0) {
        bool include_odd = (i > ((i >> 1) << 1)) && (local_col == ((i >> 1) - 1));
        i >>= 1;
        if (include_odd) {
            pacc += lacc[local_row][local_col + i + 1];
        }
        if (local_col < i) {
            pacc += lacc[local_row][local_col + i];
            lacc[local_row][local_col] = pacc;
        }
        work_group_barrier(CLK_LOCAL_MEM_FENCE);
    }

    if(local_col == 0) {
        acc[(global_size_m * group_id_n)
            + (group_id_m  * WGSm)
            + (global_size_m * local_col) + local_row] = pacc;
    }
}

__attribute__((reqd_work_group_size(WGSm, WGSn, 1)))
__kernel void sum_reduction_horizontal (__global REAL* acc) {

    uint global_size_m = get_global_size(0);
    uint group_id_m = get_group_id(0);
    uint group_id_n = get_group_id(1);
    uint local_row = get_local_id(0);
    uint local_col = get_local_id(1);

    uint a_id = (global_size_m * WGSn * group_id_n)
        + (group_id_m  * WGSm)
        + (global_size_m * local_col) + local_row;

    work_group_reduction_sum_horizontal(acc, acc[a_id]);
}

// ========================= gemv ==============================================

__attribute__((reqd_work_group_size(WGSm, WGSn, 1)))
__kernel void gemv_reduce (__global REAL* acc,
                           const REAL alpha, __global const REAL* a,
                           __global const REAL* x) {

    uint global_size_m = get_global_size(0);
    uint group_id_m = get_group_id(0);
    uint group_id_n = get_group_id(1);
    uint local_row = get_local_id(0);
    uint local_col = get_local_id(1);

    uint a_id = (global_size_m * WGSn * group_id_n)
        + (group_id_m  * WGSm)
        + (global_size_m * local_col) + local_row;

    uint x_id = WGSn * group_id_n + local_col;

    work_group_reduction_sum_horizontal(acc, alpha * a[a_id] * x[x_id]);
}

// ||||||||||||||||       BLAS 3      ||||||||||||||||||||||||||||||||||||||||||

// ================== GEMM =====================================================

inline uint index (const uint m, const uint row, const uint col) {
    return m * col + row;
}

inline uint globalize (const uint tile_size, const uint tile_id,
                       const uint id){
    return tile_id * tile_size + id;
}

// ========================= gemm ==============================================

__attribute__((reqd_work_group_size(TS, RTS, 1)))
__kernel void gemm_tiled (const REAL alpha, __global const REAL* a,
                          __global const REAL* b,
                          const REAL beta, __global REAL* c,
                          const uint m, const uint k, const uint n) {

    const uint row = get_local_id(0);
    const uint col = get_local_id(1);
    const uint c_row = globalize(TS, get_group_id(0), row);
    const uint c_col = globalize(TS, get_group_id(1), col);

    // Local tiles of matrices A and B
    __local REAL a_tile[TS][TS];
    __local REAL b_tile[TS][TS];

    REAL acc[WPT];

    // Elements that are in partial m-tiles and n-tiles need to be
    // loaded, but only if they exist.
    const bool load_row = c_row < m;
    bool load_col[WPT];

    #pragma unroll
    for (uint w = 0; w < WPT; w++) {
        acc[w] = 0.0f;
        load_col[w] = c_col + w * RTS < n;
    }

    // Compute full k-tiles
    const uint tc = k / TS;
    for (uint t = 0; t < tc; t++) {

        const uint tile_row = TS * t + row;
        const uint tile_col = TS * t + col;

        for (uint w = 0; w < WPT; w++) {
            a_tile[col + w * RTS][row] = load_row ?
                a[(tile_col + w * RTS) * m + c_row] : 0.0f;
            b_tile[col + w * RTS][row] = load_col[w] ?
                b[(c_col + w * RTS) * k + tile_row] : 0.0f;
        }

        work_group_barrier(CLK_LOCAL_MEM_FENCE);

        #pragma unroll
        for(uint i = 0; i < TS; i++) {

            #pragma unroll
            for(uint w = 0; w < WPT; w++) {
                acc[w] += a_tile[i][row] * b_tile[col + w * RTS][i];
            }
        }

        work_group_barrier(CLK_LOCAL_MEM_FENCE);
    }

    // Compute partial k-tiles.
    const uint rest_k = k - tc * TS;
    if (0 < rest_k) {

        const uint tile_row = TS * tc + row;
        const uint tile_col = TS * tc + col;

        for (uint w = 0; w < WPT; w++) {
            a_tile[col + w * RTS][row] = load_row ?
                a[(tile_col + w * RTS) * m + c_row] : 0.0f;
            b_tile[col + w * RTS][row] = load_col[w] ?
                b[(c_col + w * RTS) * k + tile_row] : 0.0f;
        }

        work_group_barrier(CLK_LOCAL_MEM_FENCE);

        #pragma unroll
        for(uint i = 0; i < rest_k; i++) {

            #pragma unroll
            for(uint w = 0; w < WPT; w++) {
                acc[w] += a_tile[i][row] * b_tile[col + w * RTS][i];
            }
        }

    }

    //Only the elements that exist in partial c-tiles should be stored.
    #pragma unroll
    for (uint w = 0; w < WPT; w++) {
        const bool store = load_row && load_col[w];
        if (store) {
            const uint c_id = index(m, c_row, c_col + w * RTS);
            c[c_id] = alpha * acc[w] + beta * c[c_id];
        }
    }

}

// Simpler version that requires dimensions that fit tiles

__attribute__((reqd_work_group_size(TS, TS/WPT, 1)))
__kernel void gemm_tiled_fit (const REAL alpha, __global const REAL* a,
                              __global const REAL* b,
                              const REAL beta, __global REAL* c,
                              const uint m, const uint k, const uint n) {

    const uint row = get_local_id(0);
    const uint col = get_local_id(1);
    const uint c_row = globalize(TS, get_group_id(0), row);
    const uint c_col = globalize(TS, get_group_id(1), col);

    // Local tiles of matrices A and B
    __local REAL a_tile[TS][TS];
    __local REAL b_tile[TS][TS];

    REAL acc[WPT];

    #pragma unroll
    for (uint w = 0; w < WPT; w++) {
        acc[w] = 0.0f;
    }

    // Compute full k-tiles
    const uint tc = k / TS;
    for (uint t = 0; t < tc; t++) {
        for (uint w = 0; w < WPT; w++) {
            const uint tile_row = TS * t + row;
            const uint tile_col = TS * t + col;
            a_tile[col + w * RTS][row] = a[(tile_col + w * RTS) * m + c_row];
            b_tile[col + w * RTS][row] = b[(c_col + w * RTS) * k + tile_row];
        }

        work_group_barrier(CLK_LOCAL_MEM_FENCE);

        #pragma unroll
        for(uint i = 0; i < TS; i++) {

            #pragma unroll
            for(uint w = 0; w < WPT; w++) {
                acc[w] += a_tile[i][row] * b_tile[col + w * RTS][i];
            }
        }

        work_group_barrier(CLK_LOCAL_MEM_FENCE);
    }

    #pragma unroll
    for (uint w = 0; w < WPT; w++) {
        const uint c_id = index(m, c_row, c_col + w * RTS);
        c[c_id] = alpha * acc[w] + beta * c[c_id];
    }

}

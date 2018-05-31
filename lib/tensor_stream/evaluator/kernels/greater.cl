 // same dimension add floating point op
 __kernel void greater_fp(const int M, const int N, const int switch_op, __global const float *A, __global const float *B, __global int2 *C) {
    // Get the index of the current element to be processed
    const int globalRow = get_global_id(0); // Row ID of C (0..M)
    const int globalCol = get_global_id(1); // Col ID of C (0..N)

    C[globalRow * N + globalCol] = A[globalRow * N + globalCol] > B[globalRow * N + globalCol] ? 1 : 0
}

 // 1D + Scalar floating point add op
 __kernel void greater_c_fp(const int M, const int N, const int switch_op, __global const float *A, __global const float *B, __global int2 *C) {
    // Get the index of the current element to be processed
    const int globalRow = get_global_id(0); // Row ID of C (0..M)
    const int globalCol = get_global_id(1); // Col ID of C (0..N)
    
    if (switch_op == 0) {
      C[globalRow * N + globalCol] = A[globalRow * N + globalCol] > B[0] ? 1 : 0;
    } else {
      C[globalRow * N + globalCol] = B[0] > A[globalRow * N + globalCol] ? 1 : 0;
    }
}

 // 1D + Scalar floating point add op broadcast
 __kernel void greater_b_fp(const int M, const int N, const int M2, const int N2, const int switch_op, __global const float *A, __global const float *B, __global int2 *C) {
    // Get the index of the current element to be processed
    const int globalRow = get_global_id(0); // Row ID of C (0..M)
    const int globalCol = get_global_id(1); // Col ID of C (0..N)
    
    int b_m_index = globalRow;
    int b_n_index = globalCol;

    if ( b_m_index >= M2) {
      b_m_index = b_m_index % M2;
    };

    if (b_n_index >= N2) {
      b_n_index = b_n_index % N2;
    }

    if (switch_op == 0) {
      C[globalRow * N + globalCol] = A[globalRow * N + globalCol] > B[b_m_index * N2 + b_n_index] ? 1 : 0;
    } else {
      C[globalRow * N + globalCol] = B[b_m_index * N2 + b_n_index] > A[globalRow * N + globalCol] ? 1 : 0;
    }
}
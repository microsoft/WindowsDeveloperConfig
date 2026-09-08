#include <cuda_runtime.h>

#include <cstdio>

__global__ void write_marker(int* value) {
    *value = 42;
}

int main() {
    int* device_value = nullptr;
    int host_value = 0;

    if (cudaMalloc(&device_value, sizeof(int)) != cudaSuccess) {
        return 1;
    }
    write_marker<<<1, 1>>>(device_value);
    if (cudaDeviceSynchronize() != cudaSuccess) {
        cudaFree(device_value);
        return 2;
    }
    if (cudaMemcpy(&host_value, device_value, sizeof(int), cudaMemcpyDeviceToHost) != cudaSuccess) {
        cudaFree(device_value);
        return 3;
    }
    cudaFree(device_value);

    if (host_value != 42) {
        return 4;
    }
    std::puts("CUDA_KERNEL_READY");
    return 0;
}

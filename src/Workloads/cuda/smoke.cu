#include <cuda_runtime.h>

#include <cstdio>
#include <cstdlib>

__global__ void write_marker(int* value) {
    *value = 42;
}

int main(int argc, char** argv) {
    const int device_index = argc > 1 ? std::atoi(argv[1]) : 0;
    int device_count = 0;
    if (cudaGetDeviceCount(&device_count) != cudaSuccess || device_index < 0 || device_index >= device_count) {
        return 5;
    }
    if (cudaSetDevice(device_index) != cudaSuccess) {
        return 6;
    }
    cudaDeviceProp properties{};
    if (cudaGetDeviceProperties(&properties, device_index) != cudaSuccess) {
        return 7;
    }
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
    std::printf("CUDA_KERNEL_READY device_index=%d device=%s\n", device_index, properties.name);
    return 0;
}

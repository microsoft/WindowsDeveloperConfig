#include <hip/hip_runtime.h>

#include <cstdio>

#define CHECK(call)                                                        \
    do {                                                                   \
        hipError_t error = (call);                                         \
        if (error != hipSuccess) {                                         \
            std::fprintf(stderr, "%s: %s\n", #call, hipGetErrorString(error)); \
            return 1;                                                      \
        }                                                                  \
    } while (0)

__global__ void write_marker(int* value) {
    if (blockIdx.x == 0 && threadIdx.x == 0) {
        *value = 42;
    }
}

int main() {
    int device_count = 0;
    CHECK(hipGetDeviceCount(&device_count));
    if (device_count < 1) return 2;

    hipDeviceProp_t properties{};
    CHECK(hipGetDeviceProperties(&properties, 0));

    int* device_value = nullptr;
    int host_value = 0;
    CHECK(hipMalloc(reinterpret_cast<void**>(&device_value), sizeof(host_value)));
    hipLaunchKernelGGL(write_marker, dim3(1), dim3(1), 0, 0, device_value);
    CHECK(hipGetLastError());
    CHECK(hipDeviceSynchronize());
    CHECK(hipMemcpy(&host_value, device_value, sizeof(host_value), hipMemcpyDeviceToHost));
    CHECK(hipFree(device_value));

    std::printf("HIP_KERNEL_READY device=%s value=%d\n", properties.name, host_value);
    return host_value == 42 ? 0 : 3;
}

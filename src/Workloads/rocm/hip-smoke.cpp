#include <hip/hip_runtime.h>

#include <cstdio>
#include <cstdlib>

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

int main(int argc, char** argv) {
    const int device_index = argc > 1 ? std::atoi(argv[1]) : 0;
    int device_count = 0;
    CHECK(hipGetDeviceCount(&device_count));
    if (device_index < 0 || device_index >= device_count) return 2;
    CHECK(hipSetDevice(device_index));

    hipDeviceProp_t properties{};
    CHECK(hipGetDeviceProperties(&properties, device_index));

    int* device_value = nullptr;
    int host_value = 0;
    CHECK(hipMalloc(reinterpret_cast<void**>(&device_value), sizeof(host_value)));
    hipLaunchKernelGGL(write_marker, dim3(1), dim3(1), 0, 0, device_value);
    CHECK(hipGetLastError());
    CHECK(hipDeviceSynchronize());
    CHECK(hipMemcpy(&host_value, device_value, sizeof(host_value), hipMemcpyDeviceToHost));
    CHECK(hipFree(device_value));

    std::printf("HIP_KERNEL_READY device_index=%d device=%s value=%d\n", device_index, properties.name, host_value);
    return host_value == 42 ? 0 : 3;
}

#include <sycl/sycl.hpp>

#include <iostream>
#include <vector>

int main() {
    sycl::queue queue{sycl::gpu_selector_v};
    std::vector<int> values(16, 0);
    {
        sycl::buffer<int> buffer(values.data(), sycl::range<1>(values.size()));
        queue.submit([&](sycl::handler& handler) {
            auto output = buffer.get_access<sycl::access::mode::write>(handler);
            handler.parallel_for(sycl::range<1>(values.size()), [=](sycl::id<1> i) {
                output[i] = static_cast<int>(i[0]) + 1;
            });
        });
    }
    for (std::size_t i = 0; i < values.size(); ++i) {
        if (values[i] != static_cast<int>(i) + 1) return 2;
    }
    std::cout << "SYCL_DEVICE_READY:" << queue.get_device().get_info<sycl::info::device::name>() << '\n';
    return 0;
}

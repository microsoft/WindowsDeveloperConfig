import torch
import triton
import triton.language as tl


@triton.jit
def add_kernel(x_ptr, y_ptr, output_ptr, size: tl.constexpr, block_size: tl.constexpr):
    offsets = tl.arange(0, block_size)
    mask = offsets < size
    x = tl.load(x_ptr + offsets, mask=mask)
    y = tl.load(y_ptr + offsets, mask=mask)
    tl.store(output_ptr + offsets, x + y, mask=mask)


size = 1024
x = torch.arange(size, device="cuda", dtype=torch.float32)
y = torch.full((size,), 2.0, device="cuda")
output = torch.empty_like(x)
add_kernel[(1,)](x, y, output, size=size, block_size=1024)
torch.cuda.synchronize()
if not torch.equal(output, x + y):
    raise RuntimeError("Triton vector-add result did not match PyTorch.")
print("TRITON_SMOKE=vector-add")

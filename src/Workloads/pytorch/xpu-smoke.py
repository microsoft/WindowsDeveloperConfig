import torch
import triton


def fn(x):
    return torch.sin(x) + torch.cos(x)


if not torch.xpu.is_available():
    raise RuntimeError("torch.xpu is unavailable")

x = torch.randn(4096, device="xpu")
expected = fn(x)
compiled = torch.compile(fn)
actual = compiled(x)
torch.xpu.synchronize()
torch.testing.assert_close(actual, expected)
print(f"TRITON_XPU_READY:{triton.__version__}")

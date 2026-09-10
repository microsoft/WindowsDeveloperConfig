import json
import argparse
import torch
import triton


parser = argparse.ArgumentParser()
parser.add_argument("--device-index", type=int, default=0)
args = parser.parse_args()


def fn(x):
    return torch.sin(x) + torch.cos(x)


if not torch.xpu.is_available():
    raise RuntimeError("torch.xpu is unavailable")

torch.xpu.set_device(args.device_index)
device = f"xpu:{args.device_index}"
x = torch.randn(4096, device=device)
expected = fn(x)
compiled = torch.compile(fn)
actual = compiled(x)
torch.xpu.synchronize()
torch.testing.assert_close(actual, expected)
print(
    "TRITON_XPU_READY="
    + json.dumps(
        {
            "backend": "XPU",
            "vendor": "Intel",
            "device": torch.xpu.get_device_name(args.device_index),
            "device_index": args.device_index,
            "torch": torch.__version__,
            "triton_xpu": triton.__version__,
            "torch_compile_executed": True,
        },
        sort_keys=True,
    )
)

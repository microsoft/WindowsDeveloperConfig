import argparse
import json

import numpy
import torch


parser = argparse.ArgumentParser()
parser.add_argument("--backend", choices=("CPU", "CUDA", "ROCm", "XPU"), required=True)
args = parser.parse_args()

device = "xpu" if args.backend == "XPU" else ("cuda" if args.backend in ("CUDA", "ROCm") else "cpu")
if device == "cuda" and not torch.cuda.is_available():
    raise RuntimeError("The CUDA wheel imported, but torch.cuda.is_available() is false.")
if device == "xpu" and not torch.xpu.is_available():
    raise RuntimeError("The XPU wheel imported, but torch.xpu.is_available() is false.")

tensor = torch.tensor([1.0, 2.0], device=device)
result = (tensor * 2).cpu().tolist()
if result != [2.0, 4.0]:
    raise RuntimeError(f"Unexpected tensor result: {result}")
if device == "cuda":
    torch.cuda.synchronize()
elif device == "xpu":
    torch.xpu.synchronize()
array = (tensor * 2).cpu().numpy()
if not numpy.array_equal(array, numpy.array([2.0, 4.0])):
    raise RuntimeError(f"Unexpected NumPy bridge result: {array}")

details = {
    "backend": args.backend,
    "device": (
        torch.cuda.get_device_name(0)
        if device == "cuda"
        else (torch.xpu.get_device_name(0) if device == "xpu" else "CPU")
    ),
    "torch": torch.__version__,
    "torch_cuda_runtime": torch.version.cuda,
    "numpy": numpy.__version__,
    "torch_hip_runtime": torch.version.hip,
}
print("PYTORCH_SMOKE=" + json.dumps(details, sort_keys=True))

import argparse
import json

import numpy
import torch


parser = argparse.ArgumentParser()
parser.add_argument("--backend", choices=("CPU", "CUDA", "ROCm", "XPU"), required=True)
parser.add_argument("--device-index", type=int, default=0)
args = parser.parse_args()

device_type = "xpu" if args.backend == "XPU" else ("cuda" if args.backend in ("CUDA", "ROCm") else "cpu")
device = f"{device_type}:{args.device_index}" if device_type != "cpu" else "cpu"
if device_type == "cuda" and not torch.cuda.is_available():
    stack = "ROCm/HIP" if args.backend == "ROCm" else "CUDA"
    raise RuntimeError(f"The {stack} PyTorch stack imported, but torch.cuda.is_available() is false.")
if device_type == "xpu" and not torch.xpu.is_available():
    raise RuntimeError("The XPU wheel imported, but torch.xpu.is_available() is false.")
if args.backend == "ROCm" and not torch.version.hip:
    raise RuntimeError("The ROCm PyTorch stack imported, but torch.version.hip is null.")
if args.backend == "CUDA" and not torch.version.cuda:
    raise RuntimeError("The CUDA PyTorch stack imported, but torch.version.cuda is null.")

tensor = torch.tensor([1.0, 2.0], device=device)
result = (tensor * 2).cpu().tolist()
if result != [2.0, 4.0]:
    raise RuntimeError(f"Unexpected tensor result: {result}")
if device_type == "cuda":
    torch.cuda.synchronize(args.device_index)
elif device_type == "xpu":
    torch.xpu.synchronize()
array = (tensor * 2).cpu().numpy()
if not numpy.array_equal(array, numpy.array([2.0, 4.0])):
    raise RuntimeError(f"Unexpected NumPy bridge result: {array}")

model = torch.nn.Sequential(
    torch.nn.Linear(2, 4),
    torch.nn.ReLU(),
    torch.nn.Linear(4, 1),
).to(device)
with torch.no_grad():
    model_result = model(torch.tensor([[1.0, 2.0]], device=device)).cpu().item()
if not numpy.isfinite(model_result):
    raise RuntimeError(f"Minimal neural-network forward pass was not finite: {model_result}")

details = {
    "backend": args.backend,
    "vendor": {
        "CUDA": "NVIDIA",
        "ROCm": "AMD",
        "XPU": "Intel",
        "CPU": "CPU",
    }[args.backend],
    "device": (
        torch.cuda.get_device_name(args.device_index)
        if device_type == "cuda"
        else (torch.xpu.get_device_name(args.device_index) if device_type == "xpu" else "CPU")
    ),
    "torch": torch.__version__,
    "torch_cuda_runtime": torch.version.cuda,
    "numpy": numpy.__version__,
    "torch_hip_runtime": torch.version.hip,
    "tensor_device_type": tensor.device.type,
    "device_index": args.device_index,
    "tensor_operation_verified": True,
    "model_forward_verified": True,
}
print("PYTORCH_SMOKE=" + json.dumps(details, sort_keys=True))

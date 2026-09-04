import argparse
import json

import torch


parser = argparse.ArgumentParser()
parser.add_argument("--backend", choices=("CPU", "CUDA"), required=True)
args = parser.parse_args()

device = "cuda" if args.backend == "CUDA" else "cpu"
if device == "cuda" and not torch.cuda.is_available():
    raise RuntimeError("The CUDA wheel imported, but torch.cuda.is_available() is false.")

tensor = torch.tensor([1.0, 2.0], device=device)
result = (tensor * 2).cpu().tolist()
if result != [2.0, 4.0]:
    raise RuntimeError(f"Unexpected tensor result: {result}")
if device == "cuda":
    torch.cuda.synchronize()

details = {
    "backend": args.backend,
    "device": torch.cuda.get_device_name(0) if device == "cuda" else "CPU",
    "torch": torch.__version__,
    "torch_cuda_runtime": torch.version.cuda,
}
print("PYTORCH_SMOKE=" + json.dumps(details, sort_keys=True))

import json
import sys

import numpy as np
import openvino as ov


requested = sys.argv[1]
core = ov.Core()
available = list(core.available_devices)
if requested not in available:
    raise RuntimeError(f"{requested} is unavailable; devices={available}")

x = ov.opset13.parameter([4], np.float32, name="x")
one = ov.opset13.constant(np.ones(4, dtype=np.float32))
model = ov.Model([ov.opset13.add(x, one)], [x], "intel_ai_smoke")
compiled = core.compile_model(model, requested)
actual = compiled([np.arange(4, dtype=np.float32)])[0]
expected = np.array([1, 2, 3, 4], dtype=np.float32)
if not np.array_equal(actual, expected):
    raise RuntimeError(f"unexpected output: {actual}")

print(
    "OPENVINO_SMOKE="
    + json.dumps(
        {
            "requested_device": requested,
            "full_device_name": core.get_property(requested, "FULL_DEVICE_NAME"),
            "available_devices": available,
            "output_verified": True,
        },
        sort_keys=True,
    )
)

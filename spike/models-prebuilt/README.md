# Detector model prebuilts (M3 Task 1)

These artifacts are the result of a one-time host conversion and are committed
so the snap build remains self-contained without repeating the conversion.

## Why prebuilt (not build-time conversion)

Upstream's `build_ov_model.py` uses `openvino.tools.mo.convert_model()` — an API
deprecated in openvino 2023.2 and **removed** in openvino 2024.0. The snap's
staged openvino is 2025.3.0, which ships only `openvino.tools.ovc` (the new
converter). `ovc` dropped the TF Object Detection API parameters
(`tensorflow_object_detection_api_pipeline_config`, `transformations_config`,
`reverse_input_channels`) that are required to convert an SSD frozen graph to
the `[1, 1, N, 7]` output format Frigate's `ModelTypeEnum.ssd` handler expects.

Build-time conversion using `openvino-dev` (which still ships `mo`) would also
require tensorflow (~600 MB) as an additional pip dependency, making the build
excessively slow and fragile. Prebuilt is the documented fallback.

## Conversion procedure

Performed on the host (2026-07-05) in a temporary Python 3.12 venv:

```bash
# Set up conversion environment
python3 -m venv /tmp/ov-conv-venv
/tmp/ov-conv-venv/bin/pip install "openvino-dev==2024.6.0" "tensorflow==2.17.*"

# Download source TF model (sha256: 542445cce834dbfbb7df1991425d475e85a2d7ec68c60a4f262bb18aac10c8b2)
wget http://download.tensorflow.org/models/object_detection/ssdlite_mobilenet_v2_coco_2018_05_09.tar.gz
tar -xzf ssdlite_mobilenet_v2_coco_2018_05_09.tar.gz

# Locate the ssd_v2_support.json shipped with openvino-dev
SSD_JSON=$(/tmp/ov-conv-venv/bin/python3 -c "
import openvino, os
base = os.path.dirname(openvino.__file__)
for r,d,fs in os.walk(base):
    for f in fs:
        if f == 'ssd_v2_support.json': print(os.path.join(r,f))
")

# Convert
/tmp/ov-conv-venv/bin/python3 - <<EOF
import openvino as ov
from openvino.tools import mo

ov_model = mo.convert_model(
    "ssdlite_mobilenet_v2_coco_2018_05_09/frozen_inference_graph.pb",
    compress_to_fp16=True,
    transformations_config="${SSD_JSON}",
    tensorflow_object_detection_api_pipeline_config="ssdlite_mobilenet_v2_coco_2018_05_09/pipeline.config",
    reverse_input_channels=True,
)
ov.save_model(ov_model, "ssdlite_mobilenet_v2.xml")
EOF
```

## Pinned SHA-256 hashes

| File | SHA-256 |
|------|---------|
| `ssdlite_mobilenet_v2.xml` | `1de65ab321104005ae89713cd062432bb49663f84c69756a80e565acb0b8e4c4` |
| `ssdlite_mobilenet_v2.bin` | `e9ae61499b401144f6fa3bc08785d55bdfbb8ab706b58c870755830cc04663d3` |
| `coco_91cl_bkgr.txt`       | `710061971626db24bab3bae6ff4e9ce6e66650565990123f3f86f12d385b37d1` |
| `labelmap.txt`              | `e23585f859d6a93827443fde9fe99ece7195dd856648af9ecb6bc6cf05f9b4d2` |

Source TF model tarball sha256: `542445cce834dbfbb7df1991425d475e85a2d7ec68c60a4f262bb18aac10c8b2`

CPU tflite (downloaded at build time):
`90bb33a634e041914cc1819aa5df99818e6c396c4d2db952c0fd7a9cffc4724f`
(url: https://github.com/google-coral/test_data/raw/c21de4450f88a20ac5968628d375787745932a5a/ssdlite_mobiledet_coco_qat_postprocess.tflite)

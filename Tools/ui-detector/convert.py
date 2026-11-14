# /// script
# requires-python = "==3.12.*"
# # coremltools 9 converts torch 2.7; newer torch traces ops it can't (int() on tensors).
# dependencies = ["ultralytics", "coremltools==9.0", "torch==2.7.*", "torchvision==0.22.*", "numpy<2.3"]
# ///
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Rebuild App/MCP/UIElementDetector.mlpackage from OmniParser's icon detector.

    uv run --exclude-newer 2026-11-06 Tools/ui-detector/convert.py

Downloads microsoft/OmniParser-v2.0's icon_detect/model.pt (YOLOv8, AGPL-3.0)
at a pinned revision, checks its SHA-256, and exports it to Core ML with
non-maximum suppression inside the model, so Vision hands back finished boxes.
"""
import hashlib
import shutil
import sys
import tempfile
import urllib.request
from pathlib import Path

REVISION = "f55d0750e5b94db2125ef0b45b0fa4a85ddc59b4"
SHA256 = "dab3d4351ad00b035db829909a4db98354d5a90f6990e4ac00222a9a95d4bf57"
BASE = f"https://huggingface.co/microsoft/OmniParser-v2.0/resolve/{REVISION}/icon_detect"
SIZE = 1280                         # the input the model sees; frames are letterboxed into it
OUT = Path(__file__).resolve().parents[2] / "App/MCP/UIElementDetector.mlpackage"

work = Path(tempfile.mkdtemp())
weights = work / "icon_detect.pt"
urllib.request.urlretrieve(f"{BASE}/model.pt", weights)
if hashlib.sha256(weights.read_bytes()).hexdigest() != SHA256:
    sys.exit("model.pt does not match the pinned SHA-256")

from ultralytics import YOLO  # noqa: E402  (after the check: loading a .pt runs pickle)

exported = Path(YOLO(str(weights)).export(format="coreml", nms=True, half=True, imgsz=SIZE,
                                           conf=0.05, iou=0.5))
shutil.rmtree(OUT, ignore_errors=True)
shutil.move(exported, OUT)
urllib.request.urlretrieve(f"{BASE}/LICENSE", OUT.parent / "UIElementDetector.LICENSE")
print(f"wrote {OUT}")

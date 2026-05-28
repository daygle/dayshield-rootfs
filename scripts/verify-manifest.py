#!/usr/bin/env python3
"""Validate a rootfs release manifest against the expected image-based update schema."""
import json
import sys

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as fh:
    data = json.load(fh)

assert data.get("component") == "rootfs", (
    f"Expected component 'rootfs', got {data.get('component')!r}"
)
strategy = data.get("update_strategy", {})
assert strategy.get("type") == "initramfs-image", (
    f"Expected update_strategy.type 'initramfs-image', got {strategy.get('type')!r}"
)
image = data.get("artifacts", {}).get("image", {})
assert image.get("format") == "squashfs", (
    f"Expected image format 'squashfs', got {image.get('format')!r}"
)
print(f"  [PASS] manifest schema OK  component={data['component']}  version={data.get('version', '?')}")

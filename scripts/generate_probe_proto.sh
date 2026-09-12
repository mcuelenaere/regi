#!/usr/bin/env bash
# Regenerate Swift bindings for ProbeKit's telemetry contract.
#
# Run after editing Packages/ProbeKit/Proto/telemetry.proto and commit the
# result. The schema is shared by RegiProbe (encoder, on the target) and
# regi-e2e (decoder, on the driver) — they are separately built, so drift here
# shows up as unreadable telemetry rather than a compile error.
#
# Toolchain: brew install protobuf swift-protobuf

set -euo pipefail

command -v protoc >/dev/null || { echo "Error: protoc not on PATH. brew install protobuf" >&2; exit 1; }
command -v protoc-gen-swift >/dev/null || { echo "Error: protoc-gen-swift not on PATH. brew install swift-protobuf" >&2; exit 1; }

cd "$(dirname "$0")/.."

PROTO_DIR="Packages/ProbeKit/Proto"
OUT_DIR="Packages/ProbeKit/Sources/ProbeKit/Wire/generated"

mkdir -p "$OUT_DIR"
protoc \
    --swift_out="$OUT_DIR" \
    --swift_opt=Visibility=Public \
    -I "$PROTO_DIR" \
    "$PROTO_DIR/telemetry.proto"

echo "Regenerated: $OUT_DIR/telemetry.pb.swift"

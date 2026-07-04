#!/usr/bin/env bash
# Regenerate Swift bindings for the vendored agent.proto.
#
# Run after updating Packages/KVMKit/Sources/JetKVMKit/Clipboard/agent.proto
# (typically: re-pulling from the JetKVM firmware repo). Commits the result.
#
# Toolchain: `brew install swift-protobuf` provides protoc-gen-swift.

set -euo pipefail

if ! command -v protoc >/dev/null; then
    echo "Error: protoc not on PATH. Install via: brew install protobuf" >&2
    exit 1
fi

if ! command -v protoc-gen-swift >/dev/null; then
    echo "Error: protoc-gen-swift not on PATH. Install via: brew install swift-protobuf" >&2
    exit 1
fi

cd "$(dirname "$0")/.."

PROTO_DIR="Packages/KVMKit/Sources/JetKVMKit/Clipboard"
OUT_DIR="$PROTO_DIR/generated"

mkdir -p "$OUT_DIR"

protoc \
    --swift_out="$OUT_DIR" \
    --swift_opt=Visibility=Public \
    -I "$PROTO_DIR" \
    "$PROTO_DIR/agent.proto"

echo "Regenerated: $OUT_DIR/agent.pb.swift"

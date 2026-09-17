#!/usr/bin/env bash
# Regenerate the Swift bindings for every vendored .proto, and commit the
# result. Regenerating all of them is idempotent, so it does not matter which
# one you edited.
#
#   agent.proto     — the JetKVM clipboard agent contract. Re-copied from the
#                     tinypipe repo, crates/tinypipe-protocol/proto/agent.proto;
#                     see that file's header for the vendored commit.
#   telemetry.proto — ProbeKit's telemetry contract, shared by RegiProbe (the
#                     encoder, on the target) and regi-e2e (the decoder, on the
#                     driver). They are separately built, so drift here shows up
#                     as unreadable telemetry rather than a compile error.
#
# Toolchain: brew install protobuf swift-protobuf

set -euo pipefail

command -v protoc >/dev/null || { echo "Error: protoc not on PATH. brew install protobuf" >&2; exit 1; }
command -v protoc-gen-swift >/dev/null || { echo "Error: protoc-gen-swift not on PATH. brew install swift-protobuf" >&2; exit 1; }

cd "$(dirname "$0")/.."

# <proto file>:<output dir>
for spec in \
    "Packages/KVMKit/Sources/JetKVMKit/Clipboard/agent.proto:Packages/KVMKit/Sources/JetKVMKit/Clipboard/generated" \
    "Packages/ProbeKit/Proto/telemetry.proto:Packages/ProbeKit/Sources/ProbeKit/Wire/generated"
do
    proto="${spec%:*}"
    out_dir="${spec#*:}"
    mkdir -p "$out_dir"
    protoc \
        --swift_out="$out_dir" \
        --swift_opt=Visibility=Public \
        -I "$(dirname "$proto")" \
        "$proto"
    echo "Regenerated: $out_dir/$(basename "${proto%.proto}").pb.swift"
done

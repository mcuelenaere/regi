#!/usr/bin/env bash
#
# Stamps `// SPDX-License-Identifier: AGPL-3.0-or-later` on every tracked
# Swift source file, and verifies the same in CI.
#
# Why a check and not just a convention: a header nobody enforces drifts out
# of date silently, and the one file that matters is always the one that got
# missed. `--check` is wired into .github/workflows/build.yml so a new file
# without a header fails the PR rather than being noticed a year later.
#
# What the header buys is narrow and worth stating honestly: comments do not
# survive compilation, so this proves nothing about a copied *binary*. It only
# helps where the source itself travels — a file vendored into someone else's
# repo, or a corporate license scanner walking a source tree, which classifies
# unheadered files as "unknown" and often assumes permissive.
#
# Usage:
#   scripts/license-headers.sh            # add missing headers in place
#   scripts/license-headers.sh --check    # exit 1 and list offenders
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Pinned rather than @latest so a new upstream release can't change what CI
# considers a valid header underneath us.
ADDLICENSE_VERSION="v1.2.0"

# Generated protobuf sources are excluded. protoc rewrites them wholesale from
# the .proto on every scripts/generate_*_proto.sh run, so any header added here
# would be silently dropped on the next regeneration and CI would then fail on a
# file nobody edited. They carry no original authorship worth marking anyway.
#
# Package.swift manifests are excluded too, and this one is not cosmetic:
# SwiftPM requires the `// swift-tools-version:` comment to be the *first* line
# of the file. addlicense prepends, which pushes it to line 3 and makes the
# manifest unparseable ("the manifest is backward-incompatible with Swift <
# 6.0"). A build manifest is a dependency list, not creative work worth marking.
EXCLUDE_PATTERN='/generated/|(^|/)Package\.swift$'

# git ls-files rather than find: the SwiftPM checkout under
# Packages/KVMKit/.build/ holds ~1500 third-party .swift files from
# swift-protobuf. Those are gitignored, are not ours, and must not be stamped.
# A read loop rather than `mapfile`: macOS ships bash 3.2, which has neither
# mapfile nor readarray, and this script runs on both a dev Mac and the runner.
FILES=()
while IFS= read -r f; do
    FILES+=("$f")
done < <(git ls-files '*.swift' | grep -Ev "$EXCLUDE_PATTERN")

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "error: no tracked Swift files found — wrong working directory?" >&2
    exit 1
fi

# A repo-local template keeps the exact header text in one place, shared by the
# apply and check paths so they can't disagree about what counts as present.
HEADER_FILE="$(mktemp)"
trap 'rm -f "$HEADER_FILE"' EXIT
printf 'SPDX-License-Identifier: AGPL-3.0-or-later\n' > "$HEADER_FILE"

# Prefer a locally installed binary (brew install addlicense); fall back to
# `go run` at the pinned version so neither CI nor a fresh clone needs a
# separate install step.
if command -v addlicense >/dev/null 2>&1; then
    run_addlicense() { addlicense "$@"; }
elif command -v go >/dev/null 2>&1; then
    run_addlicense() { go run "github.com/google/addlicense@${ADDLICENSE_VERSION}" "$@"; }
else
    echo "error: needs either 'addlicense' on PATH or a Go toolchain" >&2
    echo "       brew install addlicense" >&2
    exit 1
fi

if [[ "${1:-}" == "--check" ]]; then
    if ! run_addlicense -check -f "$HEADER_FILE" "${FILES[@]}"; then
        echo >&2
        echo "The files above are missing their SPDX header." >&2
        echo "Fix with: scripts/license-headers.sh" >&2
        exit 1
    fi
    echo "All ${#FILES[@]} tracked Swift files carry the SPDX header."
else
    # addlicense is idempotent and inserts above any existing leading doc
    # comment, so re-running is safe. It skips files that already carry a
    # Copyright line, which is what we want for anything vendored.
    run_addlicense -v -f "$HEADER_FILE" "${FILES[@]}"
    echo "Checked ${#FILES[@]} tracked Swift files."
fi

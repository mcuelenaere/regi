#!/usr/bin/env python3
"""Add a Swift file in App/ to Regi.xcodeproj.

Regi.xcodeproj is hand-maintained with synthetic object ids, so a new source
file has to be registered in four places or it simply is not compiled — and the
failure reads as "cannot find X in scope", which does not point at the project
file. This does the registration.

    ./scripts/add_app_source.py App/Foo.swift
"""
import hashlib
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PBX = ROOT / "Regi.xcodeproj" / "project.pbxproj"


def oid(kind: str, name: str) -> str:
    """24 uppercase hex digits, stable per (kind, filename)."""
    return hashlib.sha256(f"regi|{kind}|{name}".encode()).hexdigest()[:24].upper()


def add(rel_path: str) -> int:
    name = pathlib.PurePosixPath(rel_path).name
    text = PBX.read_text()

    if f"/* {name} */" in text:
        print(f"{name} is already in the project")
        return 0

    file_ref, build_file = oid("fileref", name), oid("buildfile", name)

    text = text.replace(
        "/* End PBXBuildFile section */",
        f"\t\t{build_file} /* {name} in Sources */ = {{isa = PBXBuildFile; "
        f"fileRef = {file_ref} /* {name} */; }};\n/* End PBXBuildFile section */", 1)
    text = text.replace(
        "/* End PBXFileReference section */",
        f"\t\t{file_ref} /* {name} */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = sourcecode.swift; path = {name}; "
        f"sourceTree = \"<group>\"; }};\n/* End PBXFileReference section */", 1)

    # Group membership: put it beside the other App sources.
    anchor = re.search(r"(\t+)([0-9A-F]{24}) /\* HostKeyDetector\.swift \*/,\n", text)
    if not anchor:
        print("could not find the App group anchor; project layout changed", file=sys.stderr)
        return 1
    text = text[:anchor.end()] + f"{anchor.group(1)}{file_ref} /* {name} */,\n" + text[anchor.end():]

    # Sources build phase — the one that actually compiles it.
    phase = re.search(r"(\t+)([0-9A-F]{24}) /\* HostKeyDetector\.swift in Sources \*/,\n", text)
    if not phase:
        print("could not find the Sources phase anchor", file=sys.stderr)
        return 1
    text = (text[:phase.end()]
            + f"{phase.group(1)}{build_file} /* {name} in Sources */,\n"
            + text[phase.end():])

    PBX.write_text(text)
    print(f"added {name} to Regi.xcodeproj")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.exit(add(sys.argv[1]))

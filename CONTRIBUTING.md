# Contributing to Regi

Bug reports, feature requests and pull requests are all welcome.

## Licensing of contributions

Regi is licensed under the **AGPL-3.0-or-later**. Contributions are accepted
under that same license.

This project uses the [Developer Certificate of Origin](https://developercertificate.org/)
(DCO) rather than a CLA. Sign off each commit:

```bash
git commit -s -m "Your message"
```

The `-s` appends a `Signed-off-by:` line, which certifies that you wrote the
patch (or otherwise have the right to submit it) and that you're submitting it
under the project's license. That's the whole ceremony — no copyright
assignment, no separate paperwork.

You keep the copyright on what you write.

## What to know before a large PR

Open an issue first for anything substantial. Regi has opinions about how its
backends are layered (`Packages/KVMKit`), and a design conversation up front is
cheaper than a rewrite after the fact.

## Building

See the README. `xcodegen` regenerates `Regi.xcodeproj` from `project.yml` —
edit the YAML, not the project file.

## Third-party code

Don't paste in code from other projects without flagging it in the PR, and
never from a GPLv2-only, proprietary or noncommercial-licensed source. Note
that Apache-2.0 and BSD/MIT code can be incorporated; GPLv2-only code cannot.

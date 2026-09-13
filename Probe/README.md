# RegiProbe

Runs on the **target** machine — the one the KVM's USB gadget is plugged into.
Records what input actually arrived via a `CGEventTap`, and renders it as a QR
telemetry stream on screen. That screen travels back over the KVM's own video,
so `regi-e2e` reads the results out of Regi's window with no network connection
to this machine.

## Build and install

Run this on the **target** machine. `INSTALL_PATH` is `/Applications`, so
`DSTROOT=/` puts the app straight at `/Applications/RegiProbe.app` — already
ad-hoc signed with the hardened runtime, no separate copy or re-sign step.

```bash
xcodegen generate                       # only needed when sources were added
xcodebuild -project Regi.xcodeproj -scheme RegiProbe -configuration Release \
    -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" DSTROOT=/ install
```

The install path is not cosmetic. TCC keys an Accessibility grant on the
binary's code designated requirement; for an ad-hoc-signed binary that
degenerates to path + cdhash, so running out of DerivedData means a new grant on
every rebuild and a trail of dead entries in System Settings.

Ad-hoc signing still re-prompts on each rebuild, because the cdhash moves. To
make the grant survive, create a self-signed code-signing certificate once
(Keychain Access → Certificate Assistant → Create a Certificate, type "Code
Signing") and sign with it instead — the requirement is then anchored to that
leaf rather than a hash of the bits:

```bash
xcodebuild -project Regi.xcodeproj -scheme RegiProbe -configuration Release \
    -destination 'platform=macOS' CODE_SIGN_IDENTITY="RegiProbeSelfSigned" \
    DSTROOT=/ install
```

Then launch it, press **Grant Accessibility…**, approve, and confirm the
**Event tap** row turns green. Check what the grant is actually keyed on with:

```bash
codesign -d --requirements - /Applications/RegiProbe.app
```

RegiProbe is a target of the root `Regi.xcodeproj`, which
[XcodeGen](https://xcodegen.com) generates from [`project.yml`](../project.yml),
so `brew install xcodegen` is the only prerequisite. Adding a source file needs
no pbxproj editing — add the file under `Probe/RegiProbe/` and regenerate.

## Running a session

1. Launch RegiProbe. Check the three readiness rows are green.
2. Press **Start run**. A full-screen window opens.
3. Drive the test from the driver Mac.
4. Press **Stop** — clickable through Regi, so no physical access is needed.

## The shield

While the run window is up, the keyboard is swallowed so a stray ⌘Q cannot reach
this machine's other apps. The pointer is deliberately **not** swallowed: the
full-screen window already absorbs clicks onto an inert surface, and leaving the
pointer alone is what keeps the Stop button reachable.

Window lifetime *is* shield lifetime — no separate armed state, no TTL, no
heartbeat. Backstops: **Esc ×5 within 2 seconds** always passes through and
force-closes the window; sleep, screen lock and session switch all end a run;
`pkill -x RegiProbe` always works.

## Permissions

**Accessibility** only (no Input Monitoring — there is no HID capture).

The failure worth recognising: System Settings shows the app enabled while the
"Event tap" row stays red. That means the code signature changed and the grant
no longer matches. The UI reports `tapCreate` failure separately from the trust
check for exactly this reason.

```bash
tccutil reset Accessibility app.regi.probe   # quit the app first
codesign -d --requirements - /Applications/RegiProbe.app
xattr -d com.apple.quarantine /Applications/RegiProbe.app   # after AirDrop/download
```

## Secure Input

Secure Input starves **every** event tap in the session while `tapCreate` still
reports success. The tap is this probe's only witness, so a run overlapping it
would record nothing while looking healthy. The probe therefore refuses to start
a run whenever a holder is detected, and names the holding process.

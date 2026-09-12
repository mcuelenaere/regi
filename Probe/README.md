# RegiProbe

Runs on the **target** machine — the one the KVM's USB gadget is plugged into.
Records what input actually arrived via a `CGEventTap`, and renders it as a QR
telemetry stream on screen. That screen travels back over the KVM's own video,
so `regi-e2e` reads the results out of Regi's window with no network connection
to this machine.

## Build and install

```bash
./Probe/install.sh                      # ad-hoc signed
./Probe/install.sh "RegiProbeSelfSigned"  # stable identity — grant survives rebuilds
```

`install.sh` generates the Xcode project itself, so `brew install xcodegen` is
the only prerequisite. RegiProbe is a target of the root `Regi.xcodeproj`, which
[XcodeGen](https://xcodegen.com) generates from [`project.yml`](../project.yml):

```bash
xcodegen generate
```

Adding a source file needs no pbxproj editing — add the file under
`Probe/RegiProbe/` and regenerate.

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

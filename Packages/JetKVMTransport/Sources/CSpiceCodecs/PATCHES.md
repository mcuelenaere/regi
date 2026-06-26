# Local patches to vendored SPICE codec sources

All edits exist only to compile the upstream codec files glib-free as a
standalone C target. Each is marked in-file with a `Regi patch:` comment.
Keep this list in sync so re-vendoring from upstream is mechanical.

## `vendor/lz.c`
- Replaced `#include <glib.h>` with `#include "regi_compat.h"`. `lz.c` used
  glib only for the `GUINT32_TO_LE` macro (LZ-magic store, encode path),
  which `regi_compat.h` provides. No glib symbols are otherwise referenced.

## `vendor/config.h` (new, not from upstream)
- Empty shim so the unconditional `#include <config.h>` in `quic.c`
  resolves without autotools.

## `vendor/regi_compat.h` (new, not from upstream)
- Defines `GUINT32_TO_LE` (endian-aware) — the only glib helper used by the
  vendored codec `.c` files.

## TODO (GLZ, not yet vendored)
- `decode-glz.c` uses glib for image-window bookkeeping (`g_new0`,
  `g_free`) and pulls `gio-coroutine.h` / `spice-util.h`. Plan: replace the
  `g_new0`/`g_free` calls with `calloc`/`free`, drop the coroutine/util
  includes (not needed for pure decode), and provide any small remaining
  shims here.

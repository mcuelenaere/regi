# Local patches to vendored SPICE codec sources

All edits exist only to compile/link the upstream codec files glib-free as a
standalone C target. Each is marked in-file with a `Regi patch:` comment.
Keep this list in sync so re-vendoring from upstream stays mechanical.

## Non-vendored files added by Regi
- `include/CSpiceCodecs.h` — public C API (decode-to-BGRA wrappers).
- `include/module.modulemap` — exposes only `CSpiceCodecs.h` to Swift.
- `regi_codecs.c` — QUIC + LZ decode wrappers (usr callbacks, setjmp/longjmp
  error handling, one-time `quic_init()` via `pthread_once`).
- `regi_log.c` — minimal `spice_log`/`spice_logv` (upstream's live in
  `log.c`, which pulls glib). Warnings → stderr, ERROR → abort.
- `vendor/config.h` — empty shim for `#include <config.h>`.
- `vendor/regi_compat.h` — `GUINT32_TO_LE` (only glib macro used by lz.c).
- `vendor/glz_shim.h` — glib memory/assert/log macro shims, the tiny
  `SpiceGlzDecoder`/`SpiceGlzDecoderOps` structs (from canvas_base.h),
  `SPICE_ALIGNED_CAST`, and the GLZ window API decls.

## `vendor/lz.c`
- Replaced `#include <glib.h>` with `#include "regi_compat.h"`.

## `vendor/decode-glz.c` (from spice-gtk)
- Replaced the glib / gio-coroutine / spice-util / decode.h / canvas_utils
  (pixman) includes with `glz_shim.h` (+ stdio/inttypes).
- `struct glz_image`: dropped the pixman `surface` field; `data` is now a
  plain `calloc(gross_pixels, 4)` BGRA buffer. `glz_image_new`/`_destroy`
  use malloc/free, no negative-stride/top-down pointer fixup (buffer is
  indexed in decode order; the header's top_down flag is returned to the
  caller instead).
- `glz_decoder_window_bits`: removed the `g_coroutine_condition_wait` (we
  decode in id order, so the referenced older image is always present) and
  deleted the now-unused `wait_for_image` callback + `wait_for_image_data`.
- Appended Regi's public GLZ API (`regi_glz_window_*`, `regi_glz_decode_bgra`)
  which needs the file-static `GlibGlzDecoder`/`glz_image`/`decode()`.

## `Package.swift`
- `CSpiceCodecs` target excludes the `*_tmpl.c` files (textual `#include`s,
  not standalone translation units) and sets header search paths.

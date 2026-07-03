# Vendored SPICE codecs — provenance & licensing

`CSpiceCodecs` vendors the SPICE image decoders (QUIC, LZ, and — pending —
GLZ) so the pure-Swift `SPICEBackend` can decode display data without the
glib/gstreamer/pixman stack. We deliberately vendor **only** the codec
files, not the spice canvas/pixman — QXL draw-op compositing is done in
Swift; the C here only turns compressed image blobs into pixels.

## Sources (fetched 2026-06-26)

| Files | Upstream repo | License | Commit |
|-------|---------------|---------|--------|
| `quic.c`, `quic.h`, `quic_config.h`, `quic_tmpl.c`, `quic_rgb_tmpl.c`, `quic_family_tmpl.c`, `lz.c`, `lz.h`, `lz_common.h`, `lz_config.h`, `lz_compress_tmpl.c`, `lz_decompress_tmpl.c`, `mem.c`, `mem.h`, `bitops.h`, `macros.h`, `spice_common.h`, `log.h`, `draw.h`, `verify.h`, `backtrace.h` | spice-common (mirror `freedesktop-unofficial-mirror/spice__spice-common`) | LGPL-2.1-or-later (lz.c also bears an MIT notice for the LZSS core) | `c6e6dacb30b8130a069d522054718d757eefa0db` |
| `include/spice/*.h` (`macros.h`, `types.h`, `enums.h`, `qxl_dev.h`, `start-packed.h`, `end-packed.h`, `error_codes.h`, `barrier.h`) | spice-protocol (`elmarco/spice-protocol`) | BSD-3-Clause | `1f6f9097c306704b2be3a34fdbb9ec93e6c3f229` |
| `decode-glz.c`, `decode-glz-tmpl.c` (TODO — GLZ decoder) | spice-gtk (`flexVDI/spice-gtk`) | LGPL-2.1-or-later | `2777d583ff624362b21e4244e1f5893f5e9a3797` |

## Licensing note

Regi is Apache-2.0. The codecs are LGPL-2.1-**or-later**; we use them under
LGPL-3.0, which is compatible with Apache-2.0. Because Regi's source is
public and these files are kept as a separable, relinkable unit, the LGPL
obligations (provide the codec source, allow relinking) are satisfied by
this directory. The BSD-3 spice-protocol headers carry no copyleft.

Do **not** add `PureSpice` (GPL-2.0, viral) or full spice-gtk/glib here.

## Local patches (see PATCHES.md)

Kept to the minimum needed to build glib-free. Every edit is marked with a
`Regi patch:` comment in-file and listed in `PATCHES.md`.

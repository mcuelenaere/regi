/* Regi compatibility shim for the vendored SPICE codecs.
 *
 * The upstream spice-common codec files (quic.c, lz.c) include <glib.h>
 * only for a couple of trivial helpers. To keep CSpiceCodecs glib-free we
 * drop the glib include and provide the handful of macros actually used
 * here. See PATCHES.md for the exact upstream edits.
 */
#ifndef REGI_SPICE_COMPAT_H
#define REGI_SPICE_COMPAT_H

#include <stdint.h>

/* glib's little-endian store macro. SPICE writes the LZ magic in LE. */
#ifndef GUINT32_TO_LE
#if defined(__BIG_ENDIAN__)
#define GUINT32_TO_LE(x) ((uint32_t)__builtin_bswap32((uint32_t)(x)))
#else
#define GUINT32_TO_LE(x) ((uint32_t)(x))
#endif
#endif

#endif /* REGI_SPICE_COMPAT_H */

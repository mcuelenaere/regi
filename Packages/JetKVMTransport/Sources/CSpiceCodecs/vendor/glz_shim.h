/* Regi shim for the vendored spice-gtk GLZ decoder (decode-glz.c).
 *
 * Upstream decode-glz.c pulls glib, gio-coroutine, spice-util, pixman
 * (via canvas_utils) and the full sw-canvas headers. We need none of that:
 * the GLZ decoder is used synchronously and in-order, decoding into plain
 * malloc'd BGRA buffers. This header provides:
 *   - minimal glib macro shims (memory, assertions, logging),
 *   - the tiny SpiceGlzDecoder / SpiceGlzDecoderOps base structs
 *     (from spice-common canvas_base.h),
 *   - the GLZ decoder window API.
 * See PATCHES.md for the matching edits inside decode-glz.c.
 */
#ifndef REGI_GLZ_SHIM_H
#define REGI_GLZ_SHIM_H

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

#include <spice/macros.h>   /* SPICE_CONTAINEROF, SPICE_ATTR_* */
#include "lz_common.h"      /* LzImageType, LZ_MAGIC, LZ_IMAGE_TYPE_* */
#include "draw.h"           /* SpicePalette */

/* ---- glib shims (only what decode-glz.c / decode-glz-tmpl.c use) ---- */
#ifndef TRUE
#define TRUE 1
#endif
#ifndef FALSE
#define FALSE 0
#endif
typedef int gboolean;

#define g_new(T, n)   ((T *)malloc(sizeof(T) * (size_t)(n)))
#define g_new0(T, n)  ((T *)calloc((size_t)(n), sizeof(T)))
#define g_free(p)     free(p)
#define g_clear_pointer(pp, fn) \
    do { if (*(pp)) { (fn)(*(pp)); *(pp) = NULL; } } while (0)
#define g_return_if_fail(expr) \
    do { if (!(expr)) return; } while (0)
#define g_return_val_if_fail(expr, val) \
    do { if (!(expr)) return (val); } while (0)
#define SPICE_DEBUG(...) do { } while (0)

/* Alignment-safe cast macro used by decode-glz-tmpl.c; present in newer
   spice/macros.h than the codec headers we vendor. */
#ifndef SPICE_ALIGNED_CAST
#define SPICE_ALIGNED_CAST(type, ptr) ((type)(void *)(ptr))
#endif

/* ---- SpiceGlzDecoder base (spice-common common/canvas_base.h) ---- */
typedef struct _SpiceGlzDecoder SpiceGlzDecoder;
typedef struct SpiceGlzDecoderOps {
    void (*decode)(SpiceGlzDecoder *decoder,
                   uint8_t *data, SpicePalette *palette,
                   void *usr_data);
} SpiceGlzDecoderOps;
struct _SpiceGlzDecoder {
    SpiceGlzDecoderOps *ops;
};

/* ---- GLZ decoder window API (implemented in decode-glz.c) ---- */
typedef struct SpiceGlzDecoderWindow SpiceGlzDecoderWindow;
SpiceGlzDecoderWindow *glz_decoder_window_new(void);
void glz_decoder_window_clear(SpiceGlzDecoderWindow *w);
void glz_decoder_window_destroy(SpiceGlzDecoderWindow *w);
SpiceGlzDecoder *glz_decoder_new(SpiceGlzDecoderWindow *w);
void glz_decoder_destroy(SpiceGlzDecoder *d);

#endif /* REGI_GLZ_SHIM_H */

/* CSpiceCodecs — thin C API over the vendored SPICE image decoders.
 *
 * Each decode function turns a raw SPICE image payload into a top-down
 * BGRA8888 buffer (byte order B,G,R,A — i.e. kCVPixelFormatType_32BGRA /
 * pixman LE a8r8g8b8), which is what CoreVideo/Metal want. On success the
 * output buffer is heap-allocated and must be released with regi_free().
 *
 * Orientation: QUIC carries no top-down bit (the SPICE image header does),
 * so regi_quic_decode_bgra always yields the codec's natural order and the
 * caller applies the image-level flag. LZ/GLZ headers carry their own
 * top_down bit, returned via *out_top_down.
 *
 * These wrappers cover the RGB/RGBA paths used by QXL desktops. Palette
 * (PLT) images decode best-effort. Returns 0 on success, non-zero on error.
 */
#ifndef REGI_CSPICECODECS_H
#define REGI_CSPICECODECS_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* SPICE QUIC image → BGRA8888. */
int regi_quic_decode_bgra(const uint8_t *data, size_t len,
                          uint8_t **out_bgra,
                          uint32_t *out_width, uint32_t *out_height);

/* SPICE LZ_RGB image → BGRA8888. `palette` may be NULL. */
int regi_lz_decode_bgra(const uint8_t *data, size_t len, const void *palette,
                        uint8_t **out_bgra,
                        uint32_t *out_width, uint32_t *out_height,
                        int *out_top_down);

/* GLZ needs a decoder window persisted across the display channel's
   lifetime (images back-reference earlier ones). Not thread-safe; use one
   window per display channel and decode in message order. */
typedef struct SpiceGlzDecoderWindow RegiGlzWindow;
RegiGlzWindow *regi_glz_window_new(void);
void regi_glz_window_reset(RegiGlzWindow *w);
void regi_glz_window_free(RegiGlzWindow *w);

/* SPICE GLZ_RGB image → BGRA8888. `palette` may be NULL. */
int regi_glz_decode_bgra(RegiGlzWindow *w,
                         const uint8_t *data, size_t len, const void *palette,
                         uint8_t **out_bgra,
                         uint32_t *out_width, uint32_t *out_height,
                         int *out_top_down);

/* Release a buffer returned by a regi_*_decode_bgra function. */
void regi_free(void *ptr);

#ifdef __cplusplus
}
#endif

#endif /* REGI_CSPICECODECS_H */

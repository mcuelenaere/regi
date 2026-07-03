/* CSpiceCodecs QUIC + LZ wrappers. GLZ lives in decode-glz.c (needs its
 * internal structs). See CSpiceCodecs.h for the contract. */
#include "CSpiceCodecs.h"

#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <setjmp.h>
#include <pthread.h>

#include "quic.h"
#include "lz.h"
#include "lz_common.h"

void regi_free(void *ptr) { free(ptr); }

/* QUIC relies on global model tables built by quic_init(); run it once. */
static pthread_once_t quic_init_once = PTHREAD_ONCE_INIT;
static void regi_quic_init(void) { quic_init(); }

/* ---------------------------------------------------------------- QUIC */

/* The codecs signal fatal decode errors through usr->error(), which is
 * expected never to return. We longjmp back to the wrapper and fail. */
typedef struct {
    QuicUsrContext usr;
    jmp_buf jb;
} QuicCtx;

static void quic_on_error(QuicUsrContext *u, const char *fmt, ...) {
    (void)fmt;
    longjmp(((QuicCtx *)u)->jb, 1);
}
static void quic_on_msg(QuicUsrContext *u, const char *fmt, ...) { (void)u; (void)fmt; }
static void *quic_do_malloc(QuicUsrContext *u, int size) { (void)u; return malloc((size_t)size); }
static void quic_do_free(QuicUsrContext *u, void *p) { (void)u; free(p); }
/* Not exercised on the single-buffer decode path, but must be non-NULL. */
static int quic_more_space(QuicUsrContext *u, uint32_t **io, int rows) { (void)u; (void)io; (void)rows; return 0; }
static int quic_more_lines(QuicUsrContext *u, uint8_t **lines) { (void)u; (void)lines; return 0; }

int regi_quic_decode_bgra(const uint8_t *data, size_t len,
                          uint8_t **out_bgra,
                          uint32_t *out_width, uint32_t *out_height) {
    if (!data || len < 4 || !out_bgra || !out_width || !out_height) return -1;

    pthread_once(&quic_init_once, regi_quic_init);

    QuicCtx ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.usr.error = quic_on_error;
    ctx.usr.warn = quic_on_msg;
    ctx.usr.info = quic_on_msg;
    ctx.usr.malloc = quic_do_malloc;
    ctx.usr.free = quic_do_free;
    ctx.usr.more_space = quic_more_space;
    ctx.usr.more_lines = quic_more_lines;

    QuicContext *quic = quic_create(&ctx.usr);
    if (!quic) return -1;

    uint8_t *out = NULL;
    uint8_t *tmp24 = NULL;
    int rc = -1;

    if (setjmp(ctx.jb)) { free(out); free(tmp24); quic_destroy(quic); return -1; }

    QuicImageType type;
    int w = 0, h = 0;
    if (quic_decode_begin(quic, (uint32_t *)(void *)data,
                          (unsigned)(len / 4), &type, &w, &h) == QUIC_ERROR)
        goto done;
    if (w <= 0 || h <= 0) goto done;

    const size_t px = (size_t)w * (size_t)h;
    const size_t stride = (size_t)w * 4;
    out = (uint8_t *)malloc(stride * (size_t)h);
    if (!out) goto done;

    switch (type) {
    case QUIC_IMAGE_TYPE_RGBA:
        if (quic_decode(quic, QUIC_IMAGE_TYPE_RGBA, out, (int)stride) == QUIC_ERROR) goto done;
        break;
    case QUIC_IMAGE_TYPE_RGB32:
        if (quic_decode(quic, QUIC_IMAGE_TYPE_RGB32, out, (int)stride) == QUIC_ERROR) goto done;
        for (size_t i = 0; i < px; i++) out[i * 4 + 3] = 0xFF;   /* opaque */
        break;
    case QUIC_IMAGE_TYPE_RGB16:
        /* codec supports RGB16 → RGB32 expansion into a 4bpp buffer */
        if (quic_decode(quic, QUIC_IMAGE_TYPE_RGB32, out, (int)stride) == QUIC_ERROR) goto done;
        for (size_t i = 0; i < px; i++) out[i * 4 + 3] = 0xFF;
        break;
    case QUIC_IMAGE_TYPE_RGB24: {
        const size_t stride24 = (size_t)w * 3;
        tmp24 = (uint8_t *)malloc(stride24 * (size_t)h);
        if (!tmp24) goto done;
        if (quic_decode(quic, QUIC_IMAGE_TYPE_RGB24, tmp24, (int)stride24) == QUIC_ERROR) goto done;
        for (size_t i = 0; i < px; i++) {
            out[i * 4 + 0] = tmp24[i * 3 + 0];
            out[i * 4 + 1] = tmp24[i * 3 + 1];
            out[i * 4 + 2] = tmp24[i * 3 + 2];
            out[i * 4 + 3] = 0xFF;
        }
        break;
    }
    default:
        goto done;   /* GRAY / INVALID unsupported in v1 */
    }

    *out_bgra = out;
    *out_width = (uint32_t)w;
    *out_height = (uint32_t)h;
    out = NULL;   /* transferred to caller */
    rc = 0;

done:
    free(out);
    free(tmp24);
    quic_destroy(quic);
    return rc;
}

/* ------------------------------------------------------------------ LZ */

typedef struct {
    LzUsrContext usr;
    jmp_buf jb;
} LzCtx;

static void lz_on_error(LzUsrContext *u, const char *fmt, ...) { (void)fmt; longjmp(((LzCtx *)u)->jb, 1); }
static void lz_on_msg(LzUsrContext *u, const char *fmt, ...) { (void)u; (void)fmt; }
static void *lz_do_malloc(LzUsrContext *u, int size) { (void)u; return malloc((size_t)size); }
static void lz_do_free(LzUsrContext *u, void *p) { (void)u; free(p); }
static int lz_more_space(LzUsrContext *u, uint8_t **io) { (void)u; (void)io; return 0; }
static int lz_more_lines(LzUsrContext *u, uint8_t **lines) { (void)u; (void)lines; return 0; }

int regi_lz_decode_bgra(const uint8_t *data, size_t len, const void *palette,
                        uint8_t **out_bgra,
                        uint32_t *out_width, uint32_t *out_height,
                        int *out_top_down) {
    if (!data || len == 0 || !out_bgra || !out_width || !out_height || !out_top_down) return -1;

    LzCtx ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.usr.error = lz_on_error;
    ctx.usr.warn = lz_on_msg;
    ctx.usr.info = lz_on_msg;
    ctx.usr.malloc = lz_do_malloc;
    ctx.usr.free = lz_do_free;
    ctx.usr.more_space = lz_more_space;
    ctx.usr.more_lines = lz_more_lines;

    LzContext *lz = lz_create(&ctx.usr);
    if (!lz) return -1;

    uint8_t *out = NULL;
    int rc = -1;

    if (setjmp(ctx.jb)) { free(out); lz_destroy(lz); return -1; }

    LzImageType type;
    int w = 0, h = 0, n_pixels = 0, top_down = 0;
    lz_decode_begin(lz, (uint8_t *)(void *)data, (unsigned)len,
                    &type, &w, &h, &n_pixels, &top_down,
                    (const SpicePalette *)palette);
    if (w <= 0 || h <= 0 || n_pixels <= 0) goto done;

    out = (uint8_t *)malloc((size_t)n_pixels * 4);
    if (!out) goto done;

    LzImageType to_type = (type == LZ_IMAGE_TYPE_RGBA) ? LZ_IMAGE_TYPE_RGBA : LZ_IMAGE_TYPE_RGB32;
    lz_decode(lz, to_type, out);
    if (to_type == LZ_IMAGE_TYPE_RGB32) {
        const size_t px = (size_t)w * (size_t)h;
        for (size_t i = 0; i < px; i++) out[i * 4 + 3] = 0xFF;
    }

    *out_bgra = out;
    *out_width = (uint32_t)w;
    *out_height = (uint32_t)h;
    *out_top_down = top_down ? 1 : 0;
    out = NULL;
    rc = 0;

done:
    free(out);
    lz_destroy(lz);
    return rc;
}

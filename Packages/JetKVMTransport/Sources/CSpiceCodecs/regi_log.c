/* Minimal spice-common logger backing the vendored codecs.
 *
 * quic.c / lz.c / decode-glz.c call spice_log() through their assertion and
 * warning macros. Upstream's implementation lives in log.c (which pulls in
 * glib); we provide a tiny glib-free replacement: warnings/criticals go to
 * stderr, ERROR aborts (matching upstream's fatal semantics). Decode-time
 * errors in our wrappers are surfaced via the usr->error longjmp path, so
 * this is mostly a last-resort safety net. */
#include "log.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>

void spice_logv(const char *log_domain,
                SpiceLogLevel log_level,
                const char *strloc,
                const char *function,
                const char *format,
                va_list args) {
    const char *lvl = "LOG";
    switch (log_level) {
    case SPICE_LOG_LEVEL_ERROR:    lvl = "ERROR"; break;
    case SPICE_LOG_LEVEL_CRITICAL: lvl = "CRITICAL"; break;
    case SPICE_LOG_LEVEL_WARNING:  lvl = "WARNING"; break;
    case SPICE_LOG_LEVEL_INFO:     lvl = "INFO"; break;
    case SPICE_LOG_LEVEL_DEBUG:    lvl = "DEBUG"; break;
    }
    fprintf(stderr, "[CSpiceCodecs %s] %s %s: ",
            lvl,
            strloc ? strloc : "",
            function ? function : "");
    vfprintf(stderr, format, args);
    fputc('\n', stderr);
    (void)log_domain;
    if (log_level == SPICE_LOG_LEVEL_ERROR)
        abort();
}

void spice_log(const char *log_domain,
               SpiceLogLevel log_level,
               const char *strloc,
               const char *function,
               const char *format,
               ...) {
    va_list args;
    va_start(args, format);
    spice_logv(log_domain, log_level, strloc, function, format, args);
    va_end(args);
}

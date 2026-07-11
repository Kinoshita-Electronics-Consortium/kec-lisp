/*
** embed_portability.c — strict-C11 compile probe for the generated embed
** headers (GWP-700). Not a runtime test: ctest compiles this TU with
** -std=c11 -Wall -Wextra -Wpedantic -Woverlength-strings -Werror
** -fsyntax-only (see CMakeLists, c/embed-portability).
**
** mkembed used to emit each embed as one concatenated string literal; ISO
** C11 only requires 4095 characters per literal (5.2.4.1) — the ~32 KB Core
** embed was a pedantic-compiler hard error, and MSVC caps literals at 65535
** bytes outright. The headers must stay char-array-initializer form, which
** carries no such limit.
*/
#include "kec_core_embed.h"
#include "kec_editor_embed.h"
#include "kec_harness_embed.h"
#include "kec_suite_embed.h"

/* Reference every embed so no unused-variable warning trips -Werror. */
int kec_embed_portability_probe(void) {
    return (int)(unsigned char)KEC_CORE_SRC[0]
         + (int)(unsigned char)KEC_EDITOR_SRC[0]
         + (int)(unsigned char)KEC_HARNESS_SRC[0]
         + (int)(unsigned char)KEC_SUITE_SRC[0];
}

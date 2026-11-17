// Fuzz the public sorter interface that telescope's Lua FFI wrapper
// (lua/fzf_lib.lua) drives: parse a user search pattern (fzf extended syntax:
// ' ^ $ ! | and escaped spaces), then score and highlight every candidate line
// with it, reusing one slab across lines the way the sorter does.
//
// Input layout:
//   byte 0      flags: case_mode = b % 3 (smart/ignore/respect),
//                      normalize = bit 2, fuzzy = !(bit 3)
//   bytes 1..   "<pattern>\0<candidate lines separated by '\n'>"
//               (no NUL: the whole rest is the pattern, with no candidates)
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "fzf.h"

static char *dup_nul(const uint8_t *p, size_t n) {
  char *s = (char *)malloc(n + 1);
  if (n) memcpy(s, p, n);
  s[n] = '\0';
  return s;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size < 1) return -1;
  uint8_t flags = data[0];
  data++;
  size--;

  const uint8_t *nul = memchr(data, 0, size);
  size_t pat_len = nul ? (size_t)(nul - data) : size;
  const uint8_t *rest = nul ? nul + 1 : data + size;
  size_t rest_len = nul ? size - pat_len - 1 : 0;

  // fzf_parse_pattern takes a mutable NUL-terminated string and edits it.
  char *pattern_str = dup_nul(data, pat_len);
  fzf_pattern_t *pattern =
      fzf_parse_pattern((fzf_case_types)(flags % 3), (flags & 4) != 0,
                        pattern_str, (flags & 8) == 0);
  fzf_slab_t *slab = fzf_make_default_slab();

  // Each '\n'-separated line is one candidate (NUL-terminated, as the
  // interface requires).
  size_t off = 0;
  do {
    const uint8_t *nl = memchr(rest + off, '\n', rest_len - off);
    size_t line_len = nl ? (size_t)(nl - (rest + off)) : rest_len - off;
    char *line = dup_nul(rest + off, line_len);

    int32_t score = fzf_get_score(line, pattern, slab);
    if (score > 0) {
      fzf_position_t *pos = fzf_get_positions(line, pattern, slab);
      if (pos) {
        // Positions must index into the candidate.
        for (size_t i = 0; i < pos->size; i++) {
          if (pos->data[i] >= line_len) __builtin_trap();
        }
      }
      fzf_free_positions(pos);
    }
    free(line);
    off += line_len + (nl ? 1 : 0);
  } while (off < rest_len);

  fzf_free_slab(slab);
  fzf_free_pattern(pattern);
  free(pattern_str);
  return 0;
}

// Fuzz the exported matcher functions directly (fzf.h), the way test/test.c
// calls them: length-delimited (not NUL-terminated) fzf_string_t text and
// pattern, a positions array, and a slab whose sizes the fuzzer picks — so the
// slab-exhaustion / heap-fallback paths of alloc16/alloc32 and the
// fuzzy v2 -> v1 fallback are reached, which the default 100K/2048 slab used
// by the sorter interface practically never triggers.
//
// Input layout:
//   byte 0   flags: bit0 case_sensitive, bit1 normalize, bit2 no slab,
//                   bits 3..5 matcher (v1, v2, exact, prefix, suffix, equal,
//                   all six), bit6 no positions array
//   byte 1   slab int16 capacity  = b * 16
//   byte 2   slab int32 capacity  = b
//   bytes 3.. "<pattern>\0<text>" (no NUL: everything is the pattern, empty text)
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "fzf.h"

static const fzf_algo_t kAlgos[] = {
    fzf_fuzzy_match_v1, fzf_fuzzy_match_v2, fzf_exact_match_naive,
    fzf_prefix_match,   fzf_suffix_match,   fzf_equal_match,
};
#define N_ALGOS (sizeof(kAlgos) / sizeof(kAlgos[0]))

static void run_one(fzf_algo_t fn, bool cs, bool norm, fzf_string_t *text,
                    fzf_string_t *pat, bool want_pos, fzf_slab_t *slab) {
  fzf_position_t *pos = want_pos ? fzf_pos_array(0) : NULL;
  fzf_result_t res = fn(cs, norm, text, pat, pos, slab);
  if (res.start >= 0) {
    if (res.start > res.end || (size_t)res.end > text->size) __builtin_trap();
    if (pos) {
      for (size_t i = 0; i < pos->size; i++) {
        if (pos->data[i] >= text->size) __builtin_trap();
      }
    }
  }
  fzf_free_positions(pos);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size < 3) return -1;
  uint8_t flags = data[0];
  size_t size16 = (size_t)data[1] * 16;
  size_t size32 = data[2];
  data += 3;
  size -= 3;

  const uint8_t *nul = memchr(data, 0, size);
  size_t pat_len = nul ? (size_t)(nul - data) : size;
  size_t text_len = nul ? size - pat_len - 1 : 0;

  // Exact-size heap copies, NOT NUL-terminated: the matchers take
  // (data, size) and must not read past size.
  char *pat_buf = (char *)malloc(pat_len ? pat_len : 1);
  char *text_buf = (char *)malloc(text_len ? text_len : 1);
  if (pat_len) memcpy(pat_buf, data, pat_len);
  if (text_len) memcpy(text_buf, nul + 1, text_len);

  bool cs = flags & 1;
  bool norm = (flags & 2) != 0;
  // Contract (fzf_parse_pattern, src/fzf.c): a case-insensitive term is
  // lower-cased before it reaches a matcher, which then lower-cases only the
  // text. Mirror that precondition here.
  if (!cs) {
    for (size_t i = 0; i < pat_len; i++) {
      if (pat_buf[i] >= 'A' && pat_buf[i] <= 'Z') pat_buf[i] += 'a' - 'A';
    }
  }
  fzf_string_t text = {.data = text_buf, .size = text_len};
  fzf_string_t pat = {.data = pat_buf, .size = pat_len};

  fzf_slab_t *slab =
      (flags & 4) ? NULL
                  : fzf_make_slab((fzf_slab_config_t){size16, size32});
  bool want_pos = (flags & 64) == 0;
  unsigned sel = (flags >> 3) & 7;
  if (sel < N_ALGOS) {
    run_one(kAlgos[sel], cs, norm, &text, &pat, want_pos, slab);
  } else {
    for (size_t i = 0; i < N_ALGOS; i++) {
      run_one(kAlgos[i], cs, norm, &text, &pat, want_pos, slab);
    }
  }

  fzf_free_slab(slab);
  free(pat_buf);
  free(text_buf);
  return 0;
}

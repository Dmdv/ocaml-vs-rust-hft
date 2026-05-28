#include <caml/mlvalues.h>
#include <stdint.h>

/* Monotonic nanosecond clock returning an OCaml immediate int (no allocation), so per-op timing
   never perturbs the GC. On macOS we use mach_absolute_time (the same high-resolution source
   Rust's std::time::Instant uses) so the OCaml/Rust latency comparison is apples-to-apples;
   plain clock_gettime(CLOCK_MONOTONIC) is only ~microsecond-granular on macOS. */

#if defined(__APPLE__)
#include <mach/mach_time.h>
static inline uint64_t now_ns_impl(void) {
  static mach_timebase_info_data_t tb = {0, 0};
  if (tb.denom == 0) mach_timebase_info(&tb);
  return mach_absolute_time() * tb.numer / tb.denom;
}
#else
#include <time.h>
static inline uint64_t now_ns_impl(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}
#endif

CAMLprim value ocaml_now_ns(value unit) {
  (void)unit;
  return Val_long((intnat)now_ns_impl());
}

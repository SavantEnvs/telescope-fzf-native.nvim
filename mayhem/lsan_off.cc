// Leak detection off by default for every target (fleet rule): leaks are not
// the bug class fuzzed here; ASan and UBSan stay fully active.
extern "C" int __lsan_is_turned_off() { return 1; }

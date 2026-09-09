#include "cpu-features.h"

AndroidCpuFamily android_getCpuFamily(void) {
#if defined(__aarch64__)
  return ANDROID_CPU_FAMILY_ARM64;
#elif defined(__arm__)
  return ANDROID_CPU_FAMILY_ARM;
#elif defined(__x86_64__)
  return ANDROID_CPU_FAMILY_X86_64;
#elif defined(__i386__)
  return ANDROID_CPU_FAMILY_X86;
#else
  return ANDROID_CPU_FAMILY_UNKNOWN;
#endif
}

uint64_t android_getCpuFeatures(void) {
  return 0;
}

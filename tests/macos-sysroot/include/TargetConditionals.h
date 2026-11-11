/*
 * TargetConditionals.h for the clean-room macOS sysroot (tests/macos-sysroot). Written from the public names and meanings of
 * the TARGET_OS_* and TARGET_CPU_* macros, for an Apple arm64 macOS target only. Not Apple's header; the values are the ones
 * a macOS arm64 build needs, and iOS, simulator and other platforms are reported as not set.
 */
#ifndef __TARGETCONDITIONALS__
#define __TARGETCONDITIONALS__

#define TARGET_OS_MAC 1
#define TARGET_OS_OSX 1
#define TARGET_OS_IPHONE 0
#define TARGET_OS_IOS 0
#define TARGET_OS_TV 0
#define TARGET_OS_WATCH 0
#define TARGET_OS_VISION 0
#define TARGET_OS_SIMULATOR 0
#define TARGET_OS_EMBEDDED 0
#define TARGET_OS_DRIVERKIT 0

#define TARGET_CPU_ARM64 1
#define TARGET_CPU_ARM 0
#define TARGET_CPU_X86 0
#define TARGET_CPU_X86_64 0
#define TARGET_CPU_PPC 0
#define TARGET_CPU_PPC64 0

#define TARGET_RT_LITTLE_ENDIAN 1
#define TARGET_RT_BIG_ENDIAN 0

#endif /* __TARGETCONDITIONALS__ */

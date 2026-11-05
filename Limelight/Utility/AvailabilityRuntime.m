//
//  AvailabilityRuntime.m
//  Moonlight
//
//  Runtime support for @available() checks.
//
//  Clang turns `if (@available(iOS 13.0, *))` into a call to
//  __isOSVersionAtLeast() / __isPlatformVersionAtLeast(), which normally
//  come from Xcode's compiler-rt (libclang_rt.ios.a). The iOS 8 build uses
//  a stock LLVM toolchain without that library, so they are provided here.
//
//  Note: upstream compiler-rt reads the version from SystemVersion.plist,
//  but -[NSProcessInfo operatingSystemVersion] is available since iOS 8.0,
//  which is all we need.
//

#import <Foundation/Foundation.h>
#include <stdint.h>

static NSOperatingSystemVersion GetOSVersion(void)
{
    static NSOperatingSystemVersion version;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        version = [[NSProcessInfo processInfo] operatingSystemVersion];
    });
    return version;
}

__attribute__((visibility("hidden")))
int32_t __isOSVersionAtLeast(int32_t major, int32_t minor, int32_t subminor)
{
    NSOperatingSystemVersion v = GetOSVersion();
    if (v.majorVersion != major) {
        return v.majorVersion > major;
    }
    if (v.minorVersion != minor) {
        return v.minorVersion > minor;
    }
    return v.patchVersion >= subminor;
}

// The platform argument is ignored because this binary only runs on iOS
__attribute__((visibility("hidden")))
int32_t __isPlatformVersionAtLeast(uint32_t platform, uint32_t major, uint32_t minor, uint32_t subminor)
{
    return __isOSVersionAtLeast((int32_t)major, (int32_t)minor, (int32_t)subminor);
}

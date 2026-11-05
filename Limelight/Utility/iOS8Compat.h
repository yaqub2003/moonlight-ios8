//
//  iOS8Compat.h
//  Moonlight
//
//  Definitions needed to build the iOS 8 version of Moonlight against
//  an older SDK (the build uses the iOS 14.5 SDK, the newest one that
//  can still produce 32-bit ARM binaries).
//

#ifndef iOS8Compat_h
#define iOS8Compat_h

#include <Availability.h>

#if defined(__OBJC__) && defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED < 150000
// GCInputButtonShare was added in the iOS 15 SDK. The code that uses it is
// guarded by @available(iOS 15.0, *), so we just need the constant's value.
#define GCInputButtonShare @"Button Share"
#endif

#endif /* iOS8Compat_h */

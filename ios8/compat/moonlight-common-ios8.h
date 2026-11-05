//
// Force-included when compiling moonlight-common-c for the iOS 8 build.
//
// moonlight-common-c uses clock_gettime_nsec_np(CLOCK_UPTIME_RAW) on Apple
// platforms, which only exists on iOS 10 and later. Calling it on iOS 8 would
// make dyld refuse to launch the app, so map it onto mach_absolute_time(),
// which is the same clock and has been available forever.
//

#ifndef MOONLIGHT_COMMON_IOS8_H
#define MOONLIGHT_COMMON_IOS8_H

#ifdef __APPLE__

#include <stdint.h>
#include <time.h>
#include <mach/mach_time.h>

static inline uint64_t ml_ios8_uptime_raw_ns(void)
{
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) {
        mach_timebase_info(&timebase);
    }
    return mach_absolute_time() * timebase.numer / timebase.denom;
}

#define clock_gettime_nsec_np(clock_id) ml_ios8_uptime_raw_ns()

#endif

#endif

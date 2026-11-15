//
//  AudioOutput.h
//  Moonlight
//
//  Audio output for the iOS 8 build (AudioQueue based; upstream uses SDL2,
//  which doesn't support iOS 8 or 32-bit ARM).
//

#import <Foundation/Foundation.h>

#include "Limelight.h"

int AudioOutputInit(POPUS_MULTISTREAM_CONFIGURATION opusConfig);
void AudioOutputCleanup(void);
void AudioOutputDecodeAndPlaySample(char* sampleData, int sampleLength);

// One line of live audio statistics for the stats overlay, or nil if audio isn't running
NSString* AudioOutputGetStatsText(void);

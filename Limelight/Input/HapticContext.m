//
//  HapticContext.m
//  Moonlight
//
//  Created by Cameron Gutman on 9/17/20.
//  Copyright © 2020 Moonlight Game Streaming Project. All rights reserved.
//

#import "HapticContext.h"

@implementation HapticContext

-(void)setMotorAmplitude:(unsigned short)amplitude {
    // Not supported before iOS 14
}

-(void)cleanup {
}

+(HapticContext*) createContextForHighFreqMotor:(GCController*)gamepad {
    return nil;
}

+(HapticContext*) createContextForLowFreqMotor:(GCController*)gamepad {
    return nil;
}

+(HapticContext*) createContextForLeftTrigger:(GCController*)gamepad {
    return nil;
}

+(HapticContext*) createContextForRightTrigger:(GCController*)gamepad {
    return nil;
}

@end

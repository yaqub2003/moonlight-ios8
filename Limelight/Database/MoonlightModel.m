//
//  MoonlightModel.m
//  Moonlight
//

#import "MoonlightModel.h"

// Scalar (BOOL / int32_t) properties are backed by NSNumber attributes in
// Core Data. On iOS 8 Core Data does not synthesize scalar accessors for
// @dynamic properties, so they are written out explicitly.
#define SCALAR_BOOL(getter, setter, key) \
    - (BOOL)getter { \
        [self willAccessValueForKey:key]; \
        NSNumber *v = [self primitiveValueForKey:key]; \
        [self didAccessValueForKey:key]; \
        return [v boolValue]; \
    } \
    - (void)setter:(BOOL)value { \
        [self willChangeValueForKey:key]; \
        [self setPrimitiveValue:@(value) forKey:key]; \
        [self didChangeValueForKey:key]; \
    }

#define SCALAR_INT32(getter, setter, key) \
    - (int32_t)getter { \
        [self willAccessValueForKey:key]; \
        NSNumber *v = [self primitiveValueForKey:key]; \
        [self didAccessValueForKey:key]; \
        return [v intValue]; \
    } \
    - (void)setter:(int32_t)value { \
        [self willChangeValueForKey:key]; \
        [self setPrimitiveValue:@(value) forKey:key]; \
        [self didChangeValueForKey:key]; \
    }

@implementation App
@dynamic id, name, host;
SCALAR_BOOL(hdrSupported, setHdrSupported, @"hdrSupported")
SCALAR_BOOL(hidden, setHidden, @"hidden")
@end

@implementation Host
@dynamic address, externalAddress, ipv6Address, localAddress, mac, name, pairState, serverCert, uuid, appList;
SCALAR_INT32(serverCodecModeSupport, setServerCodecModeSupport, @"serverCodecModeSupport")
@end

@implementation Settings
@dynamic audioConfig, bitrate, deviceGyroMode, framerate, height, onscreenControls, uniqueId, width;
SCALAR_BOOL(absoluteTouchMode, setAbsoluteTouchMode, @"absoluteTouchMode")
SCALAR_BOOL(btMouseSupport, setBtMouseSupport, @"btMouseSupport")
SCALAR_BOOL(enableHdr, setEnableHdr, @"enableHdr")
SCALAR_BOOL(multiController, setMultiController, @"multiController")
SCALAR_BOOL(optimizeGames, setOptimizeGames, @"optimizeGames")
SCALAR_BOOL(playAudioOnPC, setPlayAudioOnPC, @"playAudioOnPC")
SCALAR_INT32(preferredCodec, setPreferredCodec, @"preferredCodec")
SCALAR_BOOL(statsOverlay, setStatsOverlay, @"statsOverlay")
SCALAR_BOOL(swapABXYButtons, setSwapABXYButtons, @"swapABXYButtons")
SCALAR_BOOL(useFramePacing, setUseFramePacing, @"useFramePacing")
@end

@implementation MoonlightModel

static NSAttributeDescription *Attr(NSString *name, NSAttributeType type, BOOL optional, id defaultValue)
{
    NSAttributeDescription *attr = [[NSAttributeDescription alloc] init];
    attr.name = name;
    attr.attributeType = type;
    attr.optional = optional;
    attr.defaultValue = defaultValue;
    return attr;
}

+ (NSManagedObjectModel *)managedObjectModel
{
    static NSManagedObjectModel *model;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSEntityDescription *app = [[NSEntityDescription alloc] init];
        app.name = @"App";
        app.managedObjectClassName = @"App";

        NSEntityDescription *host = [[NSEntityDescription alloc] init];
        host.name = @"Host";
        host.managedObjectClassName = @"Host";

        NSEntityDescription *settings = [[NSEntityDescription alloc] init];
        settings.name = @"Settings";
        settings.managedObjectClassName = @"Settings";

        NSRelationshipDescription *appHost = [[NSRelationshipDescription alloc] init];
        NSRelationshipDescription *hostApps = [[NSRelationshipDescription alloc] init];

        appHost.name = @"host";
        appHost.destinationEntity = host;
        appHost.inverseRelationship = hostApps;
        appHost.minCount = 0;
        appHost.maxCount = 1;
        appHost.optional = NO;
        appHost.deleteRule = NSNullifyDeleteRule;

        hostApps.name = @"appList";
        hostApps.destinationEntity = app;
        hostApps.inverseRelationship = appHost;
        hostApps.minCount = 0;
        hostApps.maxCount = 0; // to-many
        hostApps.optional = YES;
        hostApps.deleteRule = NSCascadeDeleteRule;

        app.properties = @[
            Attr(@"hdrSupported", NSBooleanAttributeType, NO, @NO),
            Attr(@"hidden", NSBooleanAttributeType, NO, @NO),
            Attr(@"id", NSStringAttributeType, NO, nil),
            Attr(@"name", NSStringAttributeType, NO, nil),
            appHost,
        ];

        host.properties = @[
            Attr(@"address", NSStringAttributeType, YES, nil),
            Attr(@"externalAddress", NSStringAttributeType, YES, nil),
            Attr(@"ipv6Address", NSStringAttributeType, YES, nil),
            Attr(@"localAddress", NSStringAttributeType, YES, nil),
            Attr(@"mac", NSStringAttributeType, YES, nil),
            Attr(@"name", NSStringAttributeType, NO, nil),
            Attr(@"pairState", NSInteger32AttributeType, YES, @0),
            Attr(@"serverCert", NSBinaryDataAttributeType, YES, nil),
            Attr(@"serverCodecModeSupport", NSInteger32AttributeType, NO, @0),
            Attr(@"uuid", NSStringAttributeType, YES, nil),
            hostApps,
        ];

        settings.properties = @[
            Attr(@"absoluteTouchMode", NSBooleanAttributeType, NO, @NO),
            Attr(@"audioConfig", NSInteger32AttributeType, NO, @2),
            Attr(@"bitrate", NSInteger32AttributeType, NO, @10000),
            Attr(@"btMouseSupport", NSBooleanAttributeType, NO, @NO),
            Attr(@"deviceGyroMode", NSInteger32AttributeType, YES, @0),
            Attr(@"enableHdr", NSBooleanAttributeType, NO, @NO),
            Attr(@"framerate", NSInteger32AttributeType, NO, @60),
            Attr(@"height", NSInteger32AttributeType, NO, @720),
            Attr(@"multiController", NSBooleanAttributeType, NO, @YES),
            Attr(@"onscreenControls", NSInteger32AttributeType, NO, @1),
            Attr(@"optimizeGames", NSBooleanAttributeType, NO, @YES),
            Attr(@"playAudioOnPC", NSBooleanAttributeType, NO, @NO),
            Attr(@"preferredCodec", NSInteger32AttributeType, NO, @1),
            Attr(@"statsOverlay", NSBooleanAttributeType, NO, @NO),
            Attr(@"swapABXYButtons", NSBooleanAttributeType, NO, @NO),
            Attr(@"uniqueId", NSStringAttributeType, NO, nil),
            Attr(@"useFramePacing", NSBooleanAttributeType, NO, @NO),
            Attr(@"width", NSInteger32AttributeType, NO, @1280),
        ];

        model = [[NSManagedObjectModel alloc] init];
        model.entities = @[app, host, settings];
    });
    return model;
}

@end

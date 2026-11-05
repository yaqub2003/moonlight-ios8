//
//  MoonlightModel.h
//  Moonlight
//
//  Core Data entities and a model that is built in code.
//
//  The upstream project relies on Xcode's model compiler (momc) and its
//  automatic class generation. The iOS 8 build is produced without Xcode,
//  so the "Moonlight v1.10" model is reproduced here by hand.
//

#import <CoreData/CoreData.h>

@class App, Host;

NS_ASSUME_NONNULL_BEGIN

@interface App : NSManagedObject
@property (nonatomic) BOOL hdrSupported;
@property (nonatomic) BOOL hidden;
@property (nullable, nonatomic, copy) NSString *id;
@property (nullable, nonatomic, copy) NSString *name;
@property (nullable, nonatomic, retain) Host *host;
@end

@interface Host : NSManagedObject
@property (nullable, nonatomic, copy) NSString *address;
@property (nullable, nonatomic, copy) NSString *externalAddress;
@property (nullable, nonatomic, copy) NSString *ipv6Address;
@property (nullable, nonatomic, copy) NSString *localAddress;
@property (nullable, nonatomic, copy) NSString *mac;
@property (nullable, nonatomic, copy) NSString *name;
@property (nullable, nonatomic, copy) NSNumber *pairState;
@property (nullable, nonatomic, retain) NSData *serverCert;
@property (nonatomic) int32_t serverCodecModeSupport;
@property (nullable, nonatomic, copy) NSString *uuid;
@property (nullable, nonatomic, retain) NSSet<App *> *appList;
@end

@interface Settings : NSManagedObject
@property (nonatomic) BOOL absoluteTouchMode;
@property (nullable, nonatomic, copy) NSNumber *audioConfig;
@property (nullable, nonatomic, copy) NSNumber *bitrate;
@property (nonatomic) BOOL btMouseSupport;
@property (nullable, nonatomic, copy) NSNumber *deviceGyroMode;
@property (nonatomic) BOOL enableHdr;
@property (nullable, nonatomic, copy) NSNumber *framerate;
@property (nullable, nonatomic, copy) NSNumber *height;
@property (nonatomic) BOOL multiController;
@property (nullable, nonatomic, copy) NSNumber *onscreenControls;
@property (nonatomic) BOOL optimizeGames;
@property (nonatomic) BOOL playAudioOnPC;
@property (nonatomic) int32_t preferredCodec;
@property (nonatomic) BOOL statsOverlay;
@property (nonatomic) BOOL swapABXYButtons;
@property (nullable, nonatomic, copy) NSString *uniqueId;
@property (nonatomic) BOOL useFramePacing;
@property (nullable, nonatomic, copy) NSNumber *width;
@end

@interface MoonlightModel : NSObject
+ (NSManagedObjectModel *)managedObjectModel;
@end

NS_ASSUME_NONNULL_END

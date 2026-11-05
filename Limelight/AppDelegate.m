//
//  AppDelegate.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/17/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "AppDelegate.h"
#import "MoonlightModel.h"
#import "MainFrameViewController.h"
#import "SettingsViewController.h"
#import "SWRevealViewController.h"

@implementation AppDelegate

@synthesize managedObjectContext = _managedObjectContext;
@synthesize managedObjectModel = _managedObjectModel;
@synthesize persistentStoreCoordinator = _persistentStoreCoordinator;

static NSOperationQueue* mainQueue;

#if TARGET_OS_TV
static NSString* DB_NAME = @"Moonlight_tvOS.bin";
#else
static NSString* DB_NAME = @"Limelight_iOS.sqlite";
#endif

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // The iOS 8 build has no storyboards, so build the view controller
    // hierarchy that iPad.storyboard and iPhone.storyboard used to describe:
    //
    // SWRevealViewController
    //   rear:  SettingsViewController
    //   front: UINavigationController -> MainFrameViewController
    //            (pushes StreamFrameViewController when streaming)
    MainFrameViewController* mainFrame = [[MainFrameViewController alloc] init];
    UINavigationController* navController = [[UINavigationController alloc] initWithRootViewController:mainFrame];
    
    UIColor* barColor = [UIColor colorWithRed:0.667f green:0.667f blue:0.667f alpha:1.0f];
    navController.navigationBar.barStyle = UIBarStyleBlack;
    navController.navigationBar.translucent = NO;
    navController.navigationBar.barTintColor = barColor;
    navController.navigationBar.backgroundColor = barColor;
    navController.navigationBar.tintColor = [UIColor whiteColor];
    
    SettingsViewController* settings = [[SettingsViewController alloc] init];
    
    SWRevealViewController* revealController = [[SWRevealViewController alloc] initWithRearViewController:settings
                                                                                      frontViewController:navController];
    
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor blackColor];
    
    // Don't let the settings pane take over the entire screen on small iPhones
    CGFloat screenWidth = MAX([UIScreen mainScreen].bounds.size.width, [UIScreen mainScreen].bounds.size.height);
    revealController.rearViewRevealWidth = MIN(revealController.rearViewRevealWidth, screenWidth - 60);
    
    self.window.rootViewController = revealController;
    [self.window makeKeyAndVisible];
    
    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application
{
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    // Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    // Saves changes in the application's managed object context before the application terminates.
    [self saveContext];
}

- (void)saveContext
{
    NSManagedObjectContext *managedObjectContext = [self managedObjectContext];
    if (managedObjectContext != nil) {
        [managedObjectContext performBlock:^{
            if (![managedObjectContext hasChanges]) {
                return;
            }
            NSError *error = nil;
            if (![managedObjectContext save:&error]) {
                Log(LOG_E, @"Critical database error: %@, %@", error, [error userInfo]);
            }
            
#if TARGET_OS_TV
            NSData* dbData = [NSData dataWithContentsOfURL:[[[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] lastObject] URLByAppendingPathComponent:DB_NAME]];
            [[NSUserDefaults standardUserDefaults] setObject:dbData forKey:DB_NAME];
#endif
        }];
    }
}

#pragma mark - Core Data stack

// Returns the managed object context for the application.
// If the context doesn't already exist, it is created and bound to the persistent store coordinator for the application.
- (NSManagedObjectContext *)managedObjectContext
{
    if (_managedObjectContext != nil) {
        return _managedObjectContext;
    }
    
    NSPersistentStoreCoordinator *coordinator = [self persistentStoreCoordinator];
    if (coordinator != nil) {
        _managedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        [_managedObjectContext setPersistentStoreCoordinator:coordinator];
    }
    return _managedObjectContext;
}

// Returns the managed object model for the application.
// If the model doesn't already exist, it is created from the application's model.
- (NSManagedObjectModel *)managedObjectModel
{
    if (_managedObjectModel != nil) {
        return _managedObjectModel;
    }
    // The model is built in code because the iOS 8 build doesn't use Xcode's model compiler
    _managedObjectModel = [MoonlightModel managedObjectModel];
    return _managedObjectModel;
}

// Returns the persistent store coordinator for the application.
// If the coordinator doesn't already exist, it is created and the application's store added to it.
- (NSPersistentStoreCoordinator *)persistentStoreCoordinator
{
    if (_persistentStoreCoordinator != nil) {
        return _persistentStoreCoordinator;
    }
    
    NSError *error = nil;
    _persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:[self managedObjectModel]];
    NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
                             [NSNumber numberWithBool:YES], NSMigratePersistentStoresAutomaticallyOption,
                             [NSNumber numberWithBool:YES], NSInferMappingModelAutomaticallyOption, nil];
    NSString* storeType;
    
#if TARGET_OS_TV
    // Use a binary store for tvOS since we will need exclusive access to the file
    // to serialize into NSUserDefaults.
    storeType = NSBinaryStoreType;
#else
    storeType = NSSQLiteStoreType;
#endif
    
    // We must ensure the persistent store is ready to opened
    [self preparePersistentStore];
    
    if (![_persistentStoreCoordinator addPersistentStoreWithType:storeType configuration:nil URL:[self getStoreURL] options:options error:&error]) {
        // Log the error
        Log(LOG_E, @"Critical database error: %@, %@", error, [error userInfo]);
        
        // Drop the database
        [self dropDatabase];
        
        // Try again
        return [self persistentStoreCoordinator];
    }
    
    return _persistentStoreCoordinator;
}

#pragma mark - Application's Documents directory

// Returns the URL to the application's Documents directory.
- (NSURL *)applicationDocumentsDirectory
{
    return [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
}

- (void) dropDatabase
{
    // Delete the file on disk
    [[NSFileManager defaultManager] removeItemAtURL:[self getStoreURL] error:nil];
    
#if TARGET_OS_TV
    // Also delete the copy in the NSUserDefaults on tvOS
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:DB_NAME];
#endif
}

- (void) preparePersistentStore
{
#if TARGET_OS_TV
    // On tvOS, we may need to inflate the DB from NSUserDefaults
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cacheDirectory = [paths objectAtIndex:0];
    NSString *dbPath = [cacheDirectory stringByAppendingPathComponent:DB_NAME];
    
    // Always prefer the on disk version
    if (![[NSFileManager defaultManager] fileExistsAtPath:dbPath]) {
        // If that is unavailable, inflate it from NSUserDefaults
        NSData* data = [[NSUserDefaults standardUserDefaults] dataForKey:DB_NAME];
        if (data != nil) {
            Log(LOG_I, @"Inflating database from NSUserDefaults");
            [data writeToFile:dbPath atomically:YES];
        }
        else {
            Log(LOG_I, @"No database on disk or in NSUserDefaults");
        }
    }
    else {
        Log(LOG_I, @"Using cached database");
    }
#endif
}

- (NSURL*) getStoreURL {
#if TARGET_OS_TV
    // We use the cache folder to store our database on tvOS
    return [[[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] lastObject] URLByAppendingPathComponent:DB_NAME];
#else
    return [[self applicationDocumentsDirectory] URLByAppendingPathComponent:DB_NAME];
#endif
}

@end

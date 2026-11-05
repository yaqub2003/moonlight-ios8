//
//  LoadingFrameViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 2/24/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "LoadingFrameViewController.h"

@implementation LoadingFrameViewController {
    BOOL presented;
};

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        self.modalPresentationStyle = UIModalPresentationOverCurrentContext;
    }
    return self;
}

- (void)loadView {
    // This view used to come from the storyboard
    UIView* view = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    view.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.5f];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    
    self.loadingSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    self.loadingSpinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                                           UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self.loadingSpinner startAnimating];
    [view addSubview:self.loadingSpinner];
    
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // center the loading spinner
    self.loadingSpinner.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2);
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    self.loadingSpinner.center = CGPointMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2);
}

- (UIViewController*) activeViewController {
    UIViewController *topController = [UIApplication sharedApplication].keyWindow.rootViewController;
    
    while (topController.presentedViewController) {
        topController = topController.presentedViewController;
    }
    
    return topController;
}

- (void)showLoadingFrame:(void (^)(void))completion {
    if (!presented) {
        Log(LOG_I, @"Loading frame presenting start");
        presented = YES;
        [[self activeViewController] presentViewController:self animated:NO completion:^{
            Log(LOG_I, @"Loading frame presenting complete");
            if (completion) {
                completion();
            }
        }];
    }
    else if (completion) {
        Log(LOG_E, @"Loading frame already shown!");
        completion();
    }
}

- (void)dismissLoadingFrame:(void (^)(void))completion {
    if (presented) {
        Log(LOG_I, @"Loading frame hiding start");
        [self dismissViewControllerAnimated:NO completion:^{
            Log(LOG_I, @"Loading frame hiding complete");
            
            // Since presented is set to NO here rather than
            // immediately in dismissLoadingFrame, we may
            // falsely avoid displaying the loading frame if
            // a dismiss is in progress while attempting to show
            // the frame. That's preferable to crashing due to
            // displaying the same VC twice though.
            //
            // This scenario can happen if the app is suspended
            // while the dismiss is in progress then on resume
            // it attempts to display it again before the dismiss
            // completes. It can be reproduced by rapidly pressing
            // Home and switching back to Moonlight while in the app grid.
            // It reproduces more easily if the VC transitions are animated.
            self->presented = NO;
            
            if (completion) {
                completion();
            }
        }];
    }
    else if (completion) {
        completion();
    }
}

- (BOOL)isShown {
    return presented;
}

@end

//
//  SettingsViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 10/27/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "SettingsViewController.h"
#import "TemporarySettings.h"
#import "DataManager.h"


#import "SWRevealViewController.h"

@implementation SettingsViewController {
    NSInteger _bitrate;
    NSInteger _lastSelectedResolutionIndex;
    NSMutableArray* _layoutViews;
}

static NSString* bitrateFormat = @"Bitrate: %.1f Mbps";
static const int bitrateTable[] = {
    500,
    1000,
    1500,
    2000,
    2500,
    3000,
    4000,
    5000,
    6000,
    7000,
    8000,
    9000,
    10000,
    12000,
    15000,
    18000,
    20000,
    30000,
    40000,
    50000,
    60000,
    70000,
    80000,
    100000,
    120000,
    150000,
};

const int RESOLUTION_TABLE_SIZE = 7;
const int RESOLUTION_TABLE_CUSTOM_INDEX = RESOLUTION_TABLE_SIZE - 1;
CGSize resolutionTable[RESOLUTION_TABLE_SIZE];

-(int)getSliderValueForBitrate:(NSInteger)bitrate {
    int i;
    
    for (i = 0; i < (sizeof(bitrateTable) / sizeof(*bitrateTable)); i++) {
        if (bitrate <= bitrateTable[i]) {
            return i;
        }
    }
    
    // Return the last entry in the table
    return i - 1;
}

// The iOS 8 build has no storyboards (they can't be compiled for iOS 8
// with a current toolchain), so the settings view is built in code. The
// layout mirrors the upstream storyboard: a scroll view with a label and
// a selector for each option, stacked vertically.
static const CGFloat kSettingsMargin = 16;
static const CGFloat kSettingsLabelHeight = 21;
static const CGFloat kSettingsControlHeight = 29;
static const CGFloat kSettingsSpacing = 8;
static const CGFloat kSettingsGroupSpacing = 14;

- (UILabel*)newSettingsLabel:(NSString*)text {
    UILabel* label = [[UILabel alloc] init];
    label.text = text;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:17];
    [self.scrollView addSubview:label];
    [_layoutViews addObject:label];
    return label;
}

- (UISegmentedControl*)newSelectorWithTitles:(NSArray*)titles selected:(NSInteger)selected {
    UISegmentedControl* control = [[UISegmentedControl alloc] initWithItems:titles];
    control.selectedSegmentIndex = selected;
    control.tintColor = [UIColor whiteColor];
    [self.scrollView addSubview:control];
    [_layoutViews addObject:control];
    return control;
}

- (UISegmentedControl*)newSettingWithTitle:(NSString*)title segments:(NSArray*)segments selected:(NSInteger)selected {
    [self newSettingsLabel:title];
    return [self newSelectorWithTitles:segments selected:selected];
}

- (void)loadView {
    _layoutViews = [[NSMutableArray alloc] init];
    
    self.scrollView = [[UIScrollView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.scrollView.backgroundColor = [UIColor colorWithWhite:0.15f alpha:1.0f];
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scrollView.alwaysBounceVertical = YES;
    self.view = self.scrollView;
    
    [self newSettingsLabel:@"Resolution"];
    self.resolutionSelector = [self newSelectorWithTitles:@[@"360p", @"720p", @"1080p", @"4K", @"Safe Area", @"Full", @"Custom"] selected:1];
    self.resolutionSelector.apportionsSegmentWidthsByContent = YES;
    
    self.resolutionDisplayView = [[UIView alloc] init];
    self.resolutionDisplayView.backgroundColor = [UIColor colorWithWhite:0.3f alpha:1.0f];
    [self.scrollView addSubview:self.resolutionDisplayView];
    [_layoutViews addObject:self.resolutionDisplayView];
    
    self.framerateSelector = [self newSettingWithTitle:@"Frame Rate" segments:@[@"30 FPS", @"60 FPS", @"120 FPS"] selected:1];
    
    self.bitrateLabel = [self newSettingsLabel:@"Bitrate: 10 Mbps"];
    self.bitrateSlider = [[UISlider alloc] init];
    self.bitrateSlider.minimumTrackTintColor = [UIColor whiteColor];
    [self.scrollView addSubview:self.bitrateSlider];
    [_layoutViews addObject:self.bitrateSlider];
    
    self.touchModeSelector = [self newSettingWithTitle:@"Touch Mode" segments:@[@"Touchpad", @"Touchscreen"] selected:0];
    self.onscreenControlSelector = [self newSettingWithTitle:@"On-Screen Controls" segments:@[@"Off", @"Auto", @"Simple", @"Full"] selected:1];
    self.optimizeSettingsSelector = [self newSettingWithTitle:@"Optimize Game Settings" segments:@[@"No", @"Yes"] selected:1];
    self.multiControllerSelector = [self newSettingWithTitle:@"Multi-Controller Mode" segments:@[@"Single", @"Auto"] selected:1];
    self.swapABXYButtonsSelector = [self newSettingWithTitle:@"Swap A/B and X/Y Buttons" segments:@[@"No", @"Yes"] selected:0];
    self.audioOnPCSelector = [self newSettingWithTitle:@"Play Audio on PC" segments:@[@"No", @"Yes"] selected:0];
    self.codecSelector = [self newSettingWithTitle:@"Preferred Codec" segments:@[@"H.264", @"HEVC", @"AV1", @"Auto"] selected:3];
    self.hdrSelector = [self newSettingWithTitle:@"HDR (Beta)" segments:@[@"No", @"Yes"] selected:0];
    self.framePacingSelector = [self newSettingWithTitle:@"Frame Pacing Preference" segments:@[@"Lowest Latency", @"Smoothest Video"] selected:0];
    self.btMouseSelector = [self newSettingWithTitle:@"Citrix X1 Mouse Support" segments:@[@"No", @"Yes"] selected:0];
    self.statsOverlaySelector = [self newSettingWithTitle:@"Statistics Overlay" segments:@[@"No", @"Yes"] selected:0];
}

// Lay out the stacked settings rows and update the scroll view's content size
-(void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    
    // Only the left part of this view is visible when the settings pane is revealed
    CGFloat visibleWidth = self.view.bounds.size.width;
    if (self.revealViewController != nil && self.revealViewController.rearViewRevealWidth > 0) {
        visibleWidth = MIN(visibleWidth, self.revealViewController.rearViewRevealWidth);
    }
    CGFloat width = visibleWidth - 2 * kSettingsMargin;
    CGFloat y = 20;
    
    for (UIView* view in _layoutViews) {
        CGFloat height;
        if ([view isKindOfClass:[UILabel class]]) {
            if (view != self.bitrateLabel) {
                y += kSettingsGroupSpacing;
            }
            height = kSettingsLabelHeight;
        }
        else if (view == self.resolutionDisplayView) {
            height = 35;
        }
        else {
            height = kSettingsControlHeight;
        }
        
        view.frame = CGRectMake(kSettingsMargin, y, width, height);
        y += height + kSettingsSpacing;
    }
    
    [self updateResolutionDisplayViewText];
    
    // Add a bit of padding so the view doesn't end right at the bottom of the display
    self.scrollView.contentSize = CGSizeMake(visibleWidth, y + 20);
}

BOOL isCustomResolution(CGSize res) {
    if (res.width == 0 && res.height == 0) {
        return NO;
    }
    
    for (int i = 0; i < RESOLUTION_TABLE_CUSTOM_INDEX; i++) {
        if (res.width == resolutionTable[i].width && res.height == resolutionTable[i].height) {
            return NO;
        }
    }
    
    return YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* currentSettings = [dataMan getSettings];
    
    // Ensure we pick a bitrate that falls exactly onto a slider notch
    _bitrate = bitrateTable[[self getSliderValueForBitrate:[currentSettings.bitrate intValue]]];

    // Get the size of the screen. There are no safe area insets on iOS 8 devices,
    // so "Safe Area" and "Full" are the same. The app is landscape-only, so
    // make sure we report the landscape dimensions.
    UIScreen *screen = [UIScreen mainScreen];
    CGFloat screenScale = screen.scale;
    CGFloat fullScreenWidth = MAX(screen.bounds.size.width, screen.bounds.size.height) * screenScale;
    CGFloat fullScreenHeight = MIN(screen.bounds.size.width, screen.bounds.size.height) * screenScale;
    CGFloat safeAreaWidth = fullScreenWidth;
    
    self.resolutionDisplayView.layer.cornerRadius = 10;
    self.resolutionDisplayView.clipsToBounds = YES;
    UITapGestureRecognizer *resolutionDisplayViewTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(resolutionDisplayViewTapped:)];
    [self.resolutionDisplayView addGestureRecognizer:resolutionDisplayViewTap];
    
    resolutionTable[0] = CGSizeMake(640, 360);
    resolutionTable[1] = CGSizeMake(1280, 720);
    resolutionTable[2] = CGSizeMake(1920, 1080);
    resolutionTable[3] = CGSizeMake(3840, 2160);
    resolutionTable[4] = CGSizeMake(safeAreaWidth, fullScreenHeight);
    resolutionTable[5] = CGSizeMake(fullScreenWidth, fullScreenHeight);
    resolutionTable[6] = CGSizeMake([currentSettings.width integerValue], [currentSettings.height integerValue]); // custom initial value
    
    // Don't populate the custom entry unless we have a custom resolution
    if (!isCustomResolution(resolutionTable[6])) {
        resolutionTable[6] = CGSizeMake(0, 0);
    }
    
    NSInteger framerate;
    switch ([currentSettings.framerate integerValue]) {
        case 30:
            framerate = 0;
            break;
        default:
        case 60:
            framerate = 1;
            break;
        case 120:
            framerate = 2;
            break;
    }

    NSInteger resolution = 1;
    for (int i = 0; i < RESOLUTION_TABLE_SIZE; i++) {
        if ((int) resolutionTable[i].height == [currentSettings.height intValue]
            && (int) resolutionTable[i].width == [currentSettings.width intValue]) {
            resolution = i;
            break;
        }
    }

    // iOS 8 devices all have 60 Hz displays, so there's no 120 FPS option
    [self.framerateSelector removeSegmentAtIndex:2 animated:NO];

    // iOS 8 devices can only decode H.264 in hardware (HEVC needs iOS 11 and an
    // A9 SoC, AV1 needs an A17), and none of them have HDR displays.
    [self.codecSelector removeAllSegments];
    [self.codecSelector insertSegmentWithTitle:@"H.264" atIndex:0 animated:NO];
    [self.codecSelector setSelectedSegmentIndex:0];
    [self.codecSelector setEnabled:NO];
    
    // 4K H.264 decoding is beyond the hardware decoders of these devices
    [self.resolutionSelector setEnabled:NO forSegmentAtIndex:3];
    
    [self.hdrSelector removeAllSegments];
    [self.hdrSelector insertSegmentWithTitle:@"Unsupported on this device" atIndex:0 animated:NO];
    [self.hdrSelector setEnabled:NO];
    
    // Citrix X1 mouse support is implemented in Swift, which isn't available
    // in the iOS 8 build.
    [self.btMouseSelector removeAllSegments];
    [self.btMouseSelector insertSegmentWithTitle:@"Unsupported on this device" atIndex:0 animated:NO];
    [self.btMouseSelector setEnabled:NO];
    
    [self.touchModeSelector setSelectedSegmentIndex:currentSettings.absoluteTouchMode ? 1 : 0];
    [self.touchModeSelector addTarget:self action:@selector(touchModeChanged) forControlEvents:UIControlEventValueChanged];
    [self.statsOverlaySelector setSelectedSegmentIndex:currentSettings.statsOverlay ? 1 : 0];
    [self.optimizeSettingsSelector setSelectedSegmentIndex:currentSettings.optimizeGames ? 1 : 0];
    [self.framePacingSelector setSelectedSegmentIndex:currentSettings.useFramePacing ? 1 : 0];
    [self.multiControllerSelector setSelectedSegmentIndex:currentSettings.multiController ? 1 : 0];
    [self.swapABXYButtonsSelector setSelectedSegmentIndex:currentSettings.swapABXYButtons ? 1 : 0];
    [self.audioOnPCSelector setSelectedSegmentIndex:currentSettings.playAudioOnPC ? 1 : 0];
    NSInteger onscreenControls = [currentSettings.onscreenControls integerValue];
    _lastSelectedResolutionIndex = resolution;
    [self.resolutionSelector setSelectedSegmentIndex:resolution];
    [self.resolutionSelector addTarget:self action:@selector(newResolutionChosen) forControlEvents:UIControlEventValueChanged];
    [self.framerateSelector setSelectedSegmentIndex:framerate];
    [self.framerateSelector addTarget:self action:@selector(updateBitrate) forControlEvents:UIControlEventValueChanged];
    [self.onscreenControlSelector setSelectedSegmentIndex:onscreenControls];
    [self.onscreenControlSelector setEnabled:!currentSettings.absoluteTouchMode];
    [self.bitrateSlider setMinimumValue:0];
    [self.bitrateSlider setMaximumValue:(sizeof(bitrateTable) / sizeof(*bitrateTable)) - 1];
    [self.bitrateSlider setValue:[self getSliderValueForBitrate:_bitrate] animated:YES];
    [self.bitrateSlider addTarget:self action:@selector(bitrateSliderMoved) forControlEvents:UIControlEventValueChanged];
    [self updateBitrateText];
    [self updateResolutionDisplayViewText];
}

- (void) touchModeChanged {
    // Disable on-screen controls in absolute touch mode
    [self.onscreenControlSelector setEnabled:[self.touchModeSelector selectedSegmentIndex] == 0];
}

- (void) updateBitrate {
    NSInteger fps = [self getChosenFrameRate];
    NSInteger width = [self getChosenStreamWidth];
    NSInteger height = [self getChosenStreamHeight];
    NSInteger defaultBitrate;
    
    // This logic is shamelessly stolen from Moonlight Qt:
    // https://github.com/moonlight-stream/moonlight-qt/blob/master/app/settings/streamingpreferences.cpp
    
    // Don't scale bitrate linearly beyond 60 FPS. It's definitely not a linear
    // bitrate increase for frame rate once we get to values that high.
    float frameRateFactor = (fps <= 60 ? fps : (sqrtf(fps / 60.f) * 60.f)) / 30.f;

    // TODO: Collect some empirical data to see if these defaults make sense.
    // We're just using the values that the Shield used, as we have for years.
    struct {
        NSInteger pixels;
        int factor;
    } resTable[] = {
        { 640 * 360, 1 },
        { 854 * 480, 2 },
        { 1280 * 720, 5 },
        { 1920 * 1080, 10 },
        { 2560 * 1440, 20 },
        { 3840 * 2160, 40 },
        { -1, -1 }
    };

    // Calculate the resolution factor by linear interpolation of the resolution table
    float resolutionFactor;
    NSInteger pixels = width * height;
    for (int i = 0;; i++) {
        if (pixels == resTable[i].pixels) {
            // We can bail immediately for exact matches
            resolutionFactor = resTable[i].factor;
            break;
        }
        else if (pixels < resTable[i].pixels) {
            if (i == 0) {
                // Never go below the lowest resolution entry
                resolutionFactor = resTable[i].factor;
            }
            else {
                // Interpolate between the entry greater than the chosen resolution (i) and the entry less than the chosen resolution (i-1)
                resolutionFactor = ((float)(pixels - resTable[i-1].pixels) / (resTable[i].pixels - resTable[i-1].pixels)) * (resTable[i].factor - resTable[i-1].factor) + resTable[i-1].factor;
            }
            break;
        }
        else if (resTable[i].pixels == -1) {
            // Never go above the highest resolution entry
            resolutionFactor = resTable[i-1].factor;
            break;
        }
    }

    defaultBitrate = round(resolutionFactor * frameRateFactor) * 1000;
    _bitrate = MIN(defaultBitrate, 100000);
    [self.bitrateSlider setValue:[self getSliderValueForBitrate:_bitrate] animated:YES];
    
    [self updateBitrateText];
}

- (void) newResolutionChosen {
    BOOL lastSegmentSelected = [self.resolutionSelector selectedSegmentIndex] + 1 == [self.resolutionSelector numberOfSegments];
    if (lastSegmentSelected) {
        [self promptCustomResolutionDialog];
    }
    else {
        [self updateBitrate];
        [self updateResolutionDisplayViewText];
        _lastSelectedResolutionIndex = [self.resolutionSelector selectedSegmentIndex];
    }
}

- (void) promptCustomResolutionDialog {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Enter Custom Resolution" message:nil preferredStyle:UIAlertControllerStyleAlert];

    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Video Width";
        textField.clearButtonMode = UITextFieldViewModeAlways;
        textField.borderStyle = UITextBorderStyleRoundedRect;
        textField.keyboardType = UIKeyboardTypeNumberPad;
        
        if (resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].width == 0) {
            textField.text = @"";
        }
        else {
            textField.text = [NSString stringWithFormat:@"%d", (int) resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].width];
        }
    }];

    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Video Height";
        textField.clearButtonMode = UITextFieldViewModeAlways;
        textField.borderStyle = UITextBorderStyleRoundedRect;
        textField.keyboardType = UIKeyboardTypeNumberPad;
        
        if (resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].height == 0) {
            textField.text = @"";
        }
        else {
            textField.text = [NSString stringWithFormat:@"%d", (int) resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].height];
        }
    }];

    [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSArray * textfields = alertController.textFields;
        UITextField *widthField = textfields[0];
        UITextField *heightField = textfields[1];
        
        long width = [widthField.text integerValue];
        long height = [heightField.text integerValue];
        if (width <= 0 || height <= 0) {
            // Restore the previous selection
            [self.resolutionSelector setSelectedSegmentIndex:self->_lastSelectedResolutionIndex];
            return;
        }
        
        // H.264 maximum
        int maxResolutionDimension = 4096;
        
        // Cap to maximum valid dimensions
        width = MIN(width, maxResolutionDimension);
        height = MIN(height, maxResolutionDimension);
        
        // Cap to minimum valid dimensions
        width = MAX(width, 256);
        height = MAX(height, 256);

        resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX] = CGSizeMake(width, height);
        [self updateBitrate];
        [self updateResolutionDisplayViewText];
        self->_lastSelectedResolutionIndex = [self.resolutionSelector selectedSegmentIndex];
        
        UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Custom Resolution Selected" message: @"Custom resolutions are not officially supported by GeForce Experience, so it will not set your host display resolution. You will need to set it manually while in game.\n\nResolutions that are not supported by your client or host PC may cause streaming errors." preferredStyle:UIAlertControllerStyleAlert];
        [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alertController animated:YES completion:nil];
    }]];

    [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        // Restore the previous selection
        [self.resolutionSelector setSelectedSegmentIndex:self->_lastSelectedResolutionIndex];
    }]];

    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)resolutionDisplayViewTapped:(UITapGestureRecognizer *)sender {
    NSURL *url = [NSURL URLWithString:@"https://moonlight-stream.org/custom-resolution"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url];
    }
}

- (void) updateResolutionDisplayViewText {
    NSInteger width = [self getChosenStreamWidth];
    NSInteger height = [self getChosenStreamHeight];
    CGFloat viewFrameWidth = self.resolutionDisplayView.frame.size.width;
    CGFloat viewFrameHeight = self.resolutionDisplayView.frame.size.height;
    CGFloat padding = 10;
    CGFloat fontSize = [UIFont smallSystemFontSize];
    
    for (UIView *subview in self.resolutionDisplayView.subviews) {
        [subview removeFromSuperview];
    }
    UILabel *label1 = [[UILabel alloc] init];
    label1.text = @"Set PC/Game resolution: ";
    label1.font = [UIFont systemFontOfSize:fontSize];
    label1.textColor = [UIColor whiteColor];
    [label1 sizeToFit];
    label1.frame = CGRectMake(padding, (viewFrameHeight - label1.frame.size.height) / 2, label1.frame.size.width, label1.frame.size.height);

    UILabel *label2 = [[UILabel alloc] init];
    label2.text = [NSString stringWithFormat:@"%ld x %ld", (long)width, (long)height];
    label2.textColor = [UIColor whiteColor];
    [label2 sizeToFit];
    label2.frame = CGRectMake(viewFrameWidth - label2.frame.size.width - padding, (viewFrameHeight - label2.frame.size.height) / 2, label2.frame.size.width, label2.frame.size.height);

    [self.resolutionDisplayView addSubview:label1];
    [self.resolutionDisplayView addSubview:label2];
}

- (void) bitrateSliderMoved {
    assert(self.bitrateSlider.value < (sizeof(bitrateTable) / sizeof(*bitrateTable)));
    _bitrate = bitrateTable[(int)self.bitrateSlider.value];
    [self updateBitrateText];
}

- (void) updateBitrateText {
    // Display bitrate in Mbps
    [self.bitrateLabel setText:[NSString stringWithFormat:bitrateFormat, _bitrate / 1000.]];
}

- (NSInteger) getChosenFrameRate {
    switch ([self.framerateSelector selectedSegmentIndex]) {
        case 0:
            return 30;
        case 1:
            return 60;
        case 2:
            return 120;
        default:
            abort();
    }
}

- (uint32_t) getChosenCodecPreference {
    // Only H.264 is available on iOS 8 devices
    return CODEC_PREF_H264;
}

- (NSInteger) getChosenStreamHeight {
    // because the 4k resolution can be removed
    BOOL lastSegmentSelected = [self.resolutionSelector selectedSegmentIndex] + 1 == [self.resolutionSelector numberOfSegments];
    if (lastSegmentSelected) {
        return resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].height;
    }

    return resolutionTable[[self.resolutionSelector selectedSegmentIndex]].height;
}

- (NSInteger) getChosenStreamWidth {
    // because the 4k resolution can be removed
    BOOL lastSegmentSelected = [self.resolutionSelector selectedSegmentIndex] + 1 == [self.resolutionSelector numberOfSegments];
    if (lastSegmentSelected) {
        return resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].width;
    }

    return resolutionTable[[self.resolutionSelector selectedSegmentIndex]].width;
}

- (void) saveSettings {
    DataManager* dataMan = [[DataManager alloc] init];
    NSInteger framerate = [self getChosenFrameRate];
    NSInteger height = [self getChosenStreamHeight];
    NSInteger width = [self getChosenStreamWidth];
    NSInteger onscreenControls = [self.onscreenControlSelector selectedSegmentIndex];
    BOOL optimizeGames = [self.optimizeSettingsSelector selectedSegmentIndex] == 1;
    BOOL multiController = [self.multiControllerSelector selectedSegmentIndex] == 1;
    BOOL swapABXYButtons = [self.swapABXYButtonsSelector selectedSegmentIndex] == 1;
    BOOL audioOnPC = [self.audioOnPCSelector selectedSegmentIndex] == 1;
    uint32_t preferredCodec = [self getChosenCodecPreference];
    BOOL btMouseSupport = NO;
    BOOL useFramePacing = [self.framePacingSelector selectedSegmentIndex] == 1;
    BOOL absoluteTouchMode = [self.touchModeSelector selectedSegmentIndex] == 1;
    BOOL statsOverlay = [self.statsOverlaySelector selectedSegmentIndex] == 1;
    BOOL enableHdr = NO;
    [dataMan saveSettingsWithBitrate:_bitrate
                           framerate:framerate
                              height:height
                               width:width
                         audioConfig:2 // Stereo
                    onscreenControls:onscreenControls
                       optimizeGames:optimizeGames
                     multiController:multiController
                     swapABXYButtons:swapABXYButtons
                           audioOnPC:audioOnPC
                      preferredCodec:preferredCodec
                      useFramePacing:useFramePacing
                           enableHdr:enableHdr
                      btMouseSupport:btMouseSupport
                   absoluteTouchMode:absoluteTouchMode
                        statsOverlay:statsOverlay];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


@end

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <CaptainHook/CaptainHook.h>

extern void _CFXPreferencesRegisterDefaultValues(CFDictionaryRef defaultValues);

@interface _UITapticEngine : NSObject
- (void)actuateFeedback:(NSInteger)count;
@end

@interface UIDevice (Private)
- (_UITapticEngine *)_tapticEngine;
@end

@interface UIInteractionProgress : NSObject
@property (assign, nonatomic, readonly) CGFloat percentComplete;
@property (assign, nonatomic, readonly) CGFloat velocity;
@end

@interface SBIcon : NSObject
- (void)launch; // iOS 6
- (void)launchFromLocation:(NSInteger)location; //iOS 7 & 8
- (void)launchFromLocation:(NSInteger)location context:(id)context; //iOS 8.3
- (BOOL)isFolderIcon;
- (BOOL)isNewsstandIcon;
- (NSString *)applicationBundleID;
@end

@interface SBFolder : NSObject
- (SBIcon *)iconAtIndexPath:(NSIndexPath *)indexPath;
@end

@interface SBFolderIcon : SBIcon
- (SBFolder *)folder;
@end

@interface SBIconView : UIView
@property(assign) SBIcon *icon;
@property(assign, getter = isHighlighted) BOOL highlighted;
@property(retain, nonatomic) UIInteractionProgress *shortcutMenuPresentProgress;
@end

@interface SBFolderIconView : SBIconView
@property(readonly, assign) SBFolderIcon *folderIcon;
@end

@interface SBIconController : NSObject
+ (instancetype)sharedInstance;
- (void)iconTapped:(SBIconView *)iconView;
- (BOOL)isEditing;
- (BOOL)hasOpenFolder;
- (BOOL)isEditing;
- (void)_handleShortcutMenuPeek:(UILongPressGestureRecognizer *)recognizer;
@end

static NSString * const kIdentifier = @"me.qusic.taptapfolder";
static NSString * const kReversedBehaviorKey = @"ReversedBehavior";
static NSString * const kSwapMobilecalKey = @"SwapMobilecal";
static NSString * const kKeepFolderPreviewKey = @"KeepFolderPreview";
static NSString * const kUse3DTouchKey = @"Use3DTouch";
static NSString * const kDoubleTapTimeoutKey = @"DoubleTapTimeout";
static NSString * const kShortHoldTimeoutKey = @"ShortHoldTimeout";

static SBIconView *tappedIcon;
static NSDate *lastTouchedTime;
static NSDate *lastTappedTime;
static BOOL doubleTapRecognized;

CHDeclareClass(SBIconController)
CHDeclareClass(SBIconView)
CHDeclareClass(SBIconGridImage)

static void registerPreferenceDefaultValues(void) {
    _CFXPreferencesRegisterDefaultValues((__bridge CFDictionaryRef)@{
        kReversedBehaviorKey: @YES,
        kSwapMobilecalKey: @NO,
        kKeepFolderPreviewKey: @YES,
        kUse3DTouchKey: @YES,
        kDoubleTapTimeoutKey: @0.2,
        kShortHoldTimeoutKey: @0.3
    });
}

static BOOL getPreferenceBoolValue(NSString *key) {
    return CFPreferencesGetAppBooleanValue((__bridge CFStringRef)key, (__bridge CFStringRef)kIdentifier, NULL);
}

static float getPreferenceFloatValue(NSString *key) {
    float result = 0;
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kIdentifier);
    if (value && CFGetTypeID(value) == CFNumberGetTypeID() && CFNumberIsFloatType(value)) {
        CFNumberGetValue(value, kCFNumberFloatType, &result);
        CFRelease(value);
    }
    return result;
}

static CGRect iconFrameForGridIndex(NSUInteger index) {
    CGFloat iconSize = UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone ? 45 : 54;
    CGFloat iconMargin = UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone ? 3 : 6;
    if (index == 0) {
        return CGRectMake(0, 0, iconSize, iconSize);
    } else {
        return CGRectMake(iconSize / 2, iconSize + iconMargin, 0, 0);
    }
}

static BOOL isFolderIconView(SBIconView *view) {
    return view.icon.isFolderIcon && !([view.icon respondsToSelector:@selector(isNewsstandIcon)] && view.icon.isNewsstandIcon);
}

static BOOL is3DTouchEnabled(SBIconView *view) {
    return getPreferenceBoolValue(kUse3DTouchKey) && [view respondsToSelector:@selector(traitCollection)] && [view.traitCollection respondsToSelector:@selector(forceTouchCapability)] && view.traitCollection.forceTouchCapability == UIForceTouchCapabilityAvailable;
}

static SBIcon *getFirstIcon(SBIconView *iconView);
BOOL swapIcons(SBIconView *iconView);
static void launchFirstApp(SBIconView *iconView);
static void launchSecondApp(SBIconView *iconView);
static void openFolder(SBIconView *iconView);
static void singleTapAction(SBIconView *iconView);
static void doubleTapAction(SBIconView *iconView);
static void shortHoldAction(SBIconView *iconView);

CHOptimizedMethod(1, self, void, SBIconController, iconTapped, SBIconView *, iconView) {
    if (!self.isEditing && !self.hasOpenFolder && isFolderIconView(iconView)) {
        if (is3DTouchEnabled(iconView)) {
            singleTapAction(iconView);
        } else {
            NSDate *nowTime = [NSDate date];
            if (lastTouchedTime && [nowTime timeIntervalSinceDate:lastTouchedTime] >= getPreferenceFloatValue(kShortHoldTimeoutKey)) {
                shortHoldAction(iconView);
                return;
            } else if (iconView == tappedIcon) {
                if ([nowTime timeIntervalSinceDate:lastTappedTime] < getPreferenceFloatValue(kDoubleTapTimeoutKey)) {
                    doubleTapRecognized = YES;
                    doubleTapAction(iconView);
                    return;
                }
            } else {
                if ([iconView respondsToSelector:@selector(setHighlighted:)]) {
                    iconView.highlighted = NO;
                }
            }
            tappedIcon = iconView;
            lastTappedTime = nowTime;
            doubleTapRecognized = NO;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(getPreferenceFloatValue(kDoubleTapTimeoutKey) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^(void) {
                if (!doubleTapRecognized && iconView == tappedIcon) {
                    singleTapAction(iconView);
                }
            });
        }
    } else {
        CHSuper(1, SBIconController, iconTapped, iconView);
    }
}

CHOptimizedMethod(1, self, void, SBIconController, _handleShortcutMenuPeek, UILongPressGestureRecognizer *, recognizer) {
    CHSuper(1, SBIconController, _handleShortcutMenuPeek, recognizer);
    if ([recognizer.view isKindOfClass:CHClass(SBIconView)]) {
        SBIconView *iconView = (SBIconView *)recognizer.view;
        if (isFolderIconView(iconView) && is3DTouchEnabled(iconView)) {
            if (iconView.shortcutMenuPresentProgress.percentComplete >= 1) {
                [[UIDevice currentDevice]._tapticEngine actuateFeedback:1];
                doubleTapAction(iconView);
            }
        }
    }
}

static SBIcon *getFirstIcon(SBIconView *iconView) {
	return [((SBFolderIconView *)iconView).folderIcon.folder iconAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
}

BOOL swapIcons(SBIconView *iconView) {
	if (getPreferenceBoolValue(kSwapMobilecalKey)) {
		SBIcon *firstIcon = getFirstIcon(iconView);
		NSString *bundleId = [firstIcon applicationBundleID];
		if (firstIcon && [bundleId isEqualToString:@"com.apple.mobilecal"]) {
			return YES;
		}
	}
	return NO;
}

static void launchFirstApp(SBIconView *iconView) {
    SBIcon *firstIcon = getFirstIcon(iconView);
    if([firstIcon respondsToSelector:@selector(launchFromLocation:context:)]) {
        [firstIcon launchFromLocation:0 context:nil];
    } else if ([firstIcon respondsToSelector:@selector(launchFromLocation:)]) {
        [firstIcon launchFromLocation:0];
    } else if ([firstIcon respondsToSelector:@selector(launch)]) {
        [firstIcon launch];
    }
    if ([iconView respondsToSelector:@selector(setHighlighted:)]) {
        iconView.highlighted = NO;
    }
}

static void launchSecondApp(SBIconView *iconView) {
	SBIcon *secondIcon = [((SBFolderIconView *)iconView).folderIcon.folder iconAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:0]];
	if (secondIcon == nil) return;
	if([secondIcon respondsToSelector:@selector(launchFromLocation:context:)]) {
		[secondIcon launchFromLocation:0 context:nil];
	} else {
		[secondIcon launchFromLocation:0];
	}
	iconView.highlighted = NO;
}

static void openFolder(SBIconView *iconView) {
    id self = CHSharedInstance(SBIconController);
    CHSuper(1, SBIconController, iconTapped, iconView);
}

static void singleTapAction(SBIconView *iconView) {
    if (getPreferenceBoolValue(kReversedBehaviorKey)) {
        openFolder(iconView);
    } else {
        if (swapIcons(iconView)) {
            launchSecondApp(iconView);
        } else {
            launchFirstApp(iconView);
        }
    }
}

static void doubleTapAction(SBIconView *iconView) {
    if (getPreferenceBoolValue(kReversedBehaviorKey)) {
        if (swapIcons(iconView)) {
            launchSecondApp(iconView);
        } else {
            launchFirstApp(iconView);
        }
    } else {
        openFolder(iconView);
    }
}

static void shortHoldAction(SBIconView *iconView) {
	if (swapIcons(iconView)) {
		launchFirstApp(iconView);
	} else {
		launchSecondApp(iconView);
	}
}

CHOptimizedMethod(1, self, void, SBIconController, iconHandleLongPress, SBIconView *, iconView)
{
    lastTouchedTime = nil;
    CHSuper(1, SBIconController, iconHandleLongPress, iconView);
}

CHOptimizedMethod(1, self, void, SBIconController, iconTouchBegan, SBIconView *, iconView)
{
    lastTouchedTime = [NSDate date];
    CHSuper(1, SBIconController, iconTouchBegan, iconView);
}

CHOptimizedClassMethod(2, self, CGRect, SBIconGridImage, rectAtIndex, NSUInteger, index, maxCount, NSUInteger, count) {
    return getPreferenceBoolValue(kKeepFolderPreviewKey)
        ? CHSuper(2, SBIconGridImage, rectAtIndex, index, maxCount, count)
        : iconFrameForGridIndex(index);
}

CHOptimizedClassMethod(3, self, CGRect, SBIconGridImage, rectAtIndex, NSUInteger, index, forImage, id, image, maxCount, NSUInteger, count) {
    return getPreferenceBoolValue(kKeepFolderPreviewKey)
        ? CHSuper(3, SBIconGridImage, rectAtIndex, index, forImage, image, maxCount, count)
        : iconFrameForGridIndex(index);
}

CHConstructor {
    @autoreleasepool {
        registerPreferenceDefaultValues();
        CHLoadLateClass(SBIconController);
        CHLoadLateClass(SBIconView);
        CHLoadLateClass(SBIconGridImage);
        CHHook(1, SBIconController, iconTapped);
        CHHook(1, SBIconController, _handleShortcutMenuPeek);
        CHHook(1, SBIconController, iconHandleLongPress);
        CHHook(1, SBIconController, iconTouchBegan);
        CHHook(2, SBIconGridImage, rectAtIndex, maxCount);
        CHHook(3, SBIconGridImage, rectAtIndex, forImage, maxCount);
    }
}

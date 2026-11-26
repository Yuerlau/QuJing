#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import "Capture.h"
#import "Overlay.h"
#import "Selection.h"
#import "DockShotEditor-Swift.h"

typedef NS_ENUM(NSInteger, Phase) { Idle, Starting, WaitingForPermission, Selecting, PreparingPreview, Editing, Saving, ShowingResult, Alerting };
static NSString *const DidRequestScreenAccess = @"DidRequestScreenAccess";

@interface DockShot : NSObject <NSApplicationDelegate, SelectionEvents>
@end

@implementation DockShot {
    Phase _phase;
    Selection _gesture;
    NSArray<NSDictionary *> *_windows;
    NSDictionary *_hover;
    NSPoint _pointer;
    CGFloat _primaryTop;
    NSMutableArray<SelectionPanel *> *_panels;
    NSTimer *_refresh;
    NSPanel *_toast;
    DSEditor *_editor;
    NSUInteger _receiptNumber;
    NSScreen *_feedbackScreen;
    NSWindow *_permissionWindow;
    NSTextField *_permissionStatus;
    NSButton *_permissionAction;
    BOOL _relaunching;
    id _cancelInput;
    id _outsideClick;
    NSRect _pendingRect;
    NSUInteger _captureSequence;
}
- (BOOL)canCancelCapture {
    return _phase == Selecting || _phase == PreparingPreview || _phase == Editing;
}
- (BOOL)isOutsideSelection:(NSPoint)point {
    if (_phase == Editing) return ![_editor containsPreviewPoint:point];
    if (_phase == PreparingPreview) return !NSPointInRect(point,_pendingRect);
    if (_phase == Selecting && _gesture.dragging)
        return !NSPointInRect(point,SelectionRect(_gesture.anchor,_pointer));
    return _phase == Selecting;
}
- (NSPoint)screenPointForMouseEvent:(NSEvent *)event {
    if (event.window) return [event.window convertPointToScreen:event.locationInWindow];
    if (event.CGEvent) {
        CGPoint p = CGEventGetLocation(event.CGEvent);
        return NSMakePoint(p.x,_primaryTop - p.y);
    }
    return NSEvent.mouseLocation;
}
- (void)startCancelInput {
    if (_cancelInput) return;
    __weak DockShot *owner = self;
    _cancelInput = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskRightMouseDown
        handler:^NSEvent *(NSEvent *event) {
        DockShot *app = owner;
        if (![app canCancelCapture]) return event;
        if (event.type == NSEventTypeKeyDown) {
            if (event.keyCode != 53) return event;
            if ([app->_editor dismissSharePicker]) return nil;
        } else {
            if (![app isOutsideSelection:[app screenPointForMouseEvent:event]]) return event;
        }
        [app cancel]; return nil;
    }];
    // Mouse-only fallback for clicks routed to another app or to system chrome.
    _outsideClick = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskRightMouseDown handler:^(NSEvent *event) {
        DockShot *app = owner;
        if ([app canCancelCapture] && [app isOutsideSelection:[app screenPointForMouseEvent:event]]) [app cancel];
    }];
}
- (void)stopCancelInput {
    if (_cancelInput) { [NSEvent removeMonitor:_cancelInput]; _cancelInput = nil; }
    if (_outsideClick) { [NSEvent removeMonitor:_outsideClick]; _outsideClick = nil; }
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [self begin];
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)flag {
    [self begin];
    return NO;
}
- (void)applicationDidChangeScreenParameters:(NSNotification *)note {
    if ([self canCancelCapture]) [self cancel];
}
- (void)applicationDidResignActive:(NSNotification *)note {
    if (_phase == Selecting) {
        _phase = Idle;
        [self stopCancelInput];
        [self removeOverlays];
    }
}
- (void)hideReceipt {
    ++_receiptNumber;
    [_toast orderOut:nil];
    _toast = nil;
}
- (void)report:(NSString *)title detail:(NSString *)detail {
    _phase = Alerting;
    [NSApp unhideWithoutActivation];
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = detail;
    [alert addButtonWithTitle:@"好"];
    [alert runModal];
    _phase = Idle;
    [NSApp hide:nil];
}
- (void)showPermissionWindow {
    _phase = WaitingForPermission;
    [NSApp unhideWithoutActivation];
    [NSApp activateIgnoringOtherApps:YES];
    if (!_permissionWindow) {
        _permissionWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,486,222)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        _permissionWindow.title = @"取景";
        _permissionWindow.releasedWhenClosed = NO;
        _permissionWindow.restorable = NO;
        NSView *card = _permissionWindow.contentView;
        NSTextField *title = [NSTextField labelWithString:@"允许取景截取屏幕"];
        title.font = [NSFont systemFontOfSize:21 weight:NSFontWeightSemibold];
        title.frame = NSMakeRect(24,168,438,30);
        [card addSubview:title];
        _permissionStatus = [NSTextField wrappingLabelWithString:@""];
        _permissionStatus.frame = NSMakeRect(24,101,438,60);
        [card addSubview:_permissionStatus];
        NSURL *bundle = NSBundle.mainBundle.bundleURL;
        NSTextField *location = [NSTextField labelWithString:[@"当前应用　" stringByAppendingString:
            bundle.path.stringByAbbreviatingWithTildeInPath]];
        location.font = [NSFont systemFontOfSize:12]; location.textColor = NSColor.secondaryLabelColor;
        location.frame = NSMakeRect(24,74,438,20);
        location.lineBreakMode = NSLineBreakByTruncatingMiddle; location.toolTip = bundle.path;
        [card addSubview:location];
        _permissionAction = [NSButton buttonWithTitle:@"请求录屏权限" target:self action:@selector(permissionAction:)];
        _permissionAction.frame = NSMakeRect(20,19,128,34); [card addSubview:_permissionAction];
        NSButton *check = [NSButton buttonWithTitle:@"重新检查" target:self action:@selector(checkPermission:)];
        check.frame = NSMakeRect(155,19,102,34); [card addSubview:check];
        NSButton *restart = [NSButton buttonWithTitle:@"重新打开取景" target:self action:@selector(relaunch:)];
        restart.frame = NSMakeRect(334,19,132,34); [card addSubview:restart];
        [_permissionWindow center];
    }
    BOOL asked = [NSUserDefaults.standardUserDefaults boolForKey:DidRequestScreenAccess];
    _permissionAction.title = asked ? @"打开系统设置" : @"请求录屏权限";
    _permissionStatus.stringValue = asked
        ? @"在“隐私与安全性 → 录屏与系统录音”中为下方位置的「取景」打开权限。若已开启，点“重新打开取景”让设置生效。"
        : @"截取窗口或选区需要录屏权限。点“请求录屏权限”，按系统提示允许。如果已经授权，可直接点“重新检查”。";
    [_permissionWindow makeKeyAndOrderFront:nil];
}
- (void)permissionAction:(id)sender {
    if (CGPreflightScreenCaptureAccess()) { [self checkPermission:nil]; return; }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults boolForKey:DidRequestScreenAccess]) {
        [defaults setBool:YES forKey:DidRequestScreenAccess];
        _permissionAction.title = @"打开系统设置";
        _permissionStatus.stringValue = @"开启「取景」的录屏权限后，点“重新检查”。如果设置已开启而检查仍未通过，点“重新打开取景”。";
        if (CGRequestScreenCaptureAccess()) [self checkPermission:nil];
        return;
    }
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
        @"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
}
- (void)checkPermission:(id)sender {
    if (!CGPreflightScreenCaptureAccess()) {
        _permissionStatus.stringValue = @"当前进程还未获得录屏权限。若系统设置已为这份「取景」开启权限，点“重新打开取景”。";
        return;
    }
    [_permissionWindow orderOut:nil]; _phase = Idle;
    [self begin];
}
- (void)relaunch:(id)sender {
    if (_relaunching) return;
    _relaunching = YES;
    NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
    config.createsNewApplicationInstance = YES;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:NSBundle.mainBundle.bundleURL configuration:config
        completionHandler:^(NSRunningApplication *app, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_relaunching = NO;
            if (app && app.processIdentifier != NSProcessInfo.processInfo.processIdentifier) [NSApp terminate:nil];
            else self->_permissionStatus.stringValue = [NSString stringWithFormat:@"%@ 请按 ⌘Q 退出，再从 Dock 打开这份「取景」。", error.localizedDescription ?: @"未能启动新的进程。"];
        });
    }];
}
- (void)begin {
    if (_phase == Editing) { [_editor bringForward]; return; }
    if (_phase == WaitingForPermission) {
        if (!CGPreflightScreenCaptureAccess()) { [self showPermissionWindow]; return; }
        [_permissionWindow orderOut:nil]; _phase = Idle;
    }
    if (_phase != Idle && _phase != ShowingResult) return;
    _phase = Starting;
    [self hideReceipt];
    if (!CGPreflightScreenCaptureAccess()) {
        [self showPermissionWindow];
        return;
    }
    NSArray<NSScreen *> *screens = NSScreen.screens;
    if (!screens.count) { [NSApp terminate:nil]; return; }
    _primaryTop = NSMaxY(screens.firstObject.frame);
    _gesture = (Selection){0};
    _panels = [NSMutableArray array];
    _hover = nil;
    [NSApp unhideWithoutActivation];
    [NSApp activateIgnoringOtherApps:YES];
    _pointer = NSEvent.mouseLocation;
    SelectionPanel *key = nil;
    for (NSScreen *screen in screens) {
        SelectionPanel *panel = [[SelectionPanel alloc] initWithContentRect:screen.frame
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        panel.releasedWhenClosed = NO;
        panel.animationBehavior = NSWindowAnimationBehaviorNone;
        panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
            NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorStationary |
            NSWindowCollectionBehaviorIgnoresCycle;
        panel.level = NSScreenSaverWindowLevel;
        panel.opaque = NO;
        panel.backgroundColor = NSColor.clearColor;
        panel.hasShadow = NO;
        panel.hidesOnDeactivate = NO;
        panel.acceptsMouseMovedEvents = YES;
        panel.excludedFromWindowsMenu = YES;
        SelectionView *view = [[SelectionView alloc] initWithFrame:NSMakeRect(0,0,NSWidth(screen.frame),NSHeight(screen.frame))];
        view.events = self;
        panel.contentView = view;
        [panel setFrame:screen.frame display:NO];
        [panel makeFirstResponder:view];
        [_panels addObject:panel];
        [panel orderFrontRegardless];
        if (NSPointInRect(_pointer,screen.frame)) key = panel;
    }
    [(key ?: _panels.firstObject) makeKeyWindow];
    _phase = Selecting;
    [self startCancelInput];
    [self refreshWindows];
    [self moveTo:_pointer];
    _refresh = [NSTimer timerWithTimeInterval:.20 repeats:YES block:^(__unused NSTimer *t) {
        if (!self->_gesture.pressed && self->_phase == Selecting) {
            [self refreshWindows];
            [self moveTo:NSEvent.mouseLocation];
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:_refresh forMode:NSRunLoopCommonModes];
}
- (void)refreshWindows {
    _windows = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
}
- (NSDictionary *)windowAt:(NSPoint)p {
    CGPoint point = CGPointMake(p.x,_primaryTop-p.y);
    for (NSDictionary *item in _windows) {
        if ([item[(__bridge NSString *)kCGWindowOwnerPID] intValue] == NSProcessInfo.processInfo.processIdentifier) continue;
        if ([item[(__bridge NSString *)kCGWindowAlpha] doubleValue] <= .01) continue;
        CGRect frame;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)item[(__bridge NSString *)kCGWindowBounds], &frame)
            || !CGRectContainsPoint(frame,point)) continue;
        NSInteger layer = [item[(__bridge NSString *)kCGWindowLayer] integerValue];
        if (layer < 0) continue;
        // Real floating panels are eligible. System chrome blocks windows beneath it.
        if (layer > NSModalPanelWindowLevel) {
            NSString *owner = item[(__bridge NSString *)kCGWindowOwnerName];
            if ([owner isEqual:@"Dock"] || [owner isEqual:@"Control Center"] || [owner isEqual:@"SystemUIServer"]) return nil;
            continue;
        }
        return item;
    }
    return nil;
}
- (void)redraw {
    NSRect selection = NSZeroRect;
    NSString *name = nil;
    NSMutableArray<NSValue *> *covered = [NSMutableArray array];
    if (_gesture.dragging) selection = SelectionRect(_gesture.anchor,_pointer);
    else if (_hover) {
        CGRect frame;
        if (CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)_hover[(__bridge NSString *)kCGWindowBounds],&frame))
            selection = FlipRect(frame,_primaryTop);
        for (NSDictionary *front in _windows) {
            if (front == _hover) break;
            if ([front[(__bridge NSString *)kCGWindowOwnerPID] intValue] == NSProcessInfo.processInfo.processIdentifier ||
                [front[(__bridge NSString *)kCGWindowLayer] integerValue] > NSModalPanelWindowLevel ||
                [front[(__bridge NSString *)kCGWindowAlpha] doubleValue] < .01) continue;
            CGRect bounds;
            if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)front[(__bridge NSString *)kCGWindowBounds], &bounds)) continue;
            NSRect overlap = NSIntersectionRect(selection,FlipRect(bounds,_primaryTop));
            if (!NSIsEmptyRect(overlap)) [covered addObject:[NSValue valueWithRect:overlap]];
        }
        name = _hover[(__bridge NSString *)kCGWindowName];
        if (!name.length) name = _hover[(__bridge NSString *)kCGWindowOwnerName];
        if (name.length > 36) name = [[name substringWithRange:[name rangeOfComposedCharacterSequencesForRange:NSMakeRange(0,34)]] stringByAppendingString:@"…"];
    }
    for (NSPanel *panel in _panels) {
        SelectionView *view = (SelectionView *)panel.contentView;
        view.selectedScreenRect = selection;
        view.windowName = name;
        view.coveredRects = covered;
        view.dragging = _gesture.dragging;
        view.needsDisplay = YES;
    }
}
- (void)moveTo:(NSPoint)p {
    if (_phase != Selecting || _gesture.pressed) return;
    BOOL pointerChanged = !NSEqualPoints(p,_pointer);
    _pointer = p;
    NSDictionary *window = [self windowAt:p];
    if (!pointerChanged && _hover == window) return;
    _hover = window;
    [self redraw];
}
- (void)pressAt:(NSPoint)p {
    if (_phase != Selecting) return;
    [self refreshWindows];
    _pointer = p;
    _hover = [self windowAt:p];
    BeginPress(&_gesture,p,[_hover[(__bridge NSString *)kCGWindowNumber] unsignedIntValue]);
    [self redraw];
}
- (void)dragTo:(NSPoint)p {
    if (_phase != Selecting || !_gesture.pressed) return;
    _pointer = p;
    TrackPress(&_gesture,p);
    [self redraw];
}
- (void)releaseAt:(NSPoint)p clicks:(NSInteger)clicks {
    if (_phase != Selecting || !_gesture.pressed) return;
    _pointer = p;
    TrackPress(&_gesture,p);
    [self refreshWindows];
    _hover = [self windowAt:p];
    CGWindowID window = [_hover[(__bridge NSString *)kCGWindowNumber] unsignedIntValue];
    BOOL wasDrag = _gesture.dragging;
    NSRect area = SelectionRect(_gesture.anchor,p);
    BOOL confirmed = ConfirmWindow(&_gesture,window,clicks);
    _gesture.dragging = NO;
    if (wasDrag && NSWidth(area) >= 3 && NSHeight(area) >= 3) {
        [self takeWindow:0 area:FlipRect(NSIntegralRect(area),_primaryTop)];
    } else if (confirmed) {
        [self takeWindow:window area:CGRectZero];
    } else [self redraw];
}
- (void)removeOverlays {
    [_refresh invalidate];
    _refresh = nil;
    for (NSWindow *panel in _panels) [panel orderOut:nil];
    _panels = nil;
    _windows = nil;
    _hover = nil;
}
- (void)cancel {
    if (![self canCancelCapture]) return;
    ++_captureSequence;
    [self stopCancelInput];
    if (_phase == Editing) {
        [_editor finish]; _editor = nil;
    }
    _phase = Idle;
    [self removeOverlays];
    [NSApp hide:nil];
}
- (void)takeWindow:(CGWindowID)window area:(CGRect)area {
    _phase = window ? Saving : PreparingPreview;
    NSUInteger sequence = ++_captureSequence;
    _pendingRect = window ? NSZeroRect : FlipRect(area,_primaryTop);
    if (window) [self stopCancelInput];
    _feedbackScreen = NSScreen.mainScreen;
    for (NSScreen *screen in NSScreen.screens)
        if (NSPointInRect(_pointer,screen.frame)) _feedbackScreen = screen;
    [self removeOverlays];
    if (window) [NSApp hide:nil];
    [NSApp updateWindows];
    [CATransaction flush];
    NSRect anchor = FlipRect(area,_primaryTop);
    ImageResult completion = ^(CGImageRef image, NSError *captureError) {
        if (image) CGImageRetain(image);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (sequence != self->_captureSequence) {
                if (image) CGImageRelease(image);
                return;
            }
            if (captureError || !image) {
                [self stopCancelInput];
                if ([captureError.domain isEqualToString:SCStreamErrorDomain] && captureError.code == SCStreamErrorUserDeclined)
                    [self showPermissionWindow];
                else [self report:@"未能截取图像" detail:captureError.localizedDescription ?: @"请重新选择窗口或区域。"];
            } else if (window) [self saveImage:image];
            else {
                self->_phase = Editing;
                self->_editor = [DSEditor new];
                __weak DockShot *owner = self;
                [self->_editor showImage:image frame:anchor onSave:^(CGImageRef edited) {
                    [owner saveImage:edited];
                } onDismiss:^{
                    DockShot *app = owner;
                    if (app) [app cancel];
                }];
            }
            if (image) CGImageRelease(image);
        });
    };
    if (window) CaptureWindow(window,completion);
    else {
        // Wait for the window server to remove the overlay before taking the region.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
            if (sequence == self->_captureSequence) CaptureArea(area,completion);
        });
    }
}
- (void)saveImage:(CGImageRef)image {
    _phase = Saving;
    CGImageRetain(image);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSError *error = nil;
        NSURL *desktop = [NSFileManager.defaultManager URLForDirectory:NSDesktopDirectory
            inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:&error];
        NSURL *file = desktop ? WritePNG(image,desktop,&error) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (file) {
                [self stopCancelInput];
                [self->_editor finish]; self->_editor = nil;
                [self showReceipt:file image:image];
            } else {
                NSString *detail = error.localizedDescription ?: @"请检查桌面的写入权限和剩余空间。";
                if (self->_editor) { self->_phase = Editing; [self->_editor saveFailed:detail]; }
                else [self report:@"未能保存截图" detail:detail];
            }
            CGImageRelease(image);
        });
    });
}
- (void)showReceipt:(NSURL *)file image:(CGImageRef)image {
    _phase = ShowingResult;
    NSScreen *screen = _feedbackScreen ?: NSScreen.mainScreen;
    NSRect visible = screen.visibleFrame;
    NSRect frame = NSMakeRect(NSMaxX(visible)-299,NSMinY(visible)+18,280,72);
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    panel.opaque = NO; panel.backgroundColor = NSColor.clearColor; panel.hasShadow = YES;
    panel.hidesOnDeactivate = NO; panel.ignoresMouseEvents = YES; panel.animationBehavior = NSWindowAnimationBehaviorNone;
    panel.level = NSPopUpMenuWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    NSVisualEffectView *card = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0,0,280,72)];
    card.material = NSVisualEffectMaterialHUDWindow;
    card.state = NSVisualEffectStateActive;
    card.wantsLayer = YES; card.layer.cornerRadius = 16; card.layer.masksToBounds = YES;
    card.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    NSImageView *preview = [[NSImageView alloc] initWithFrame:NSMakeRect(12,11,72,50)];
    preview.image = [[NSImage alloc] initWithCGImage:image size:NSZeroSize];
    preview.imageScaling = NSImageScaleProportionallyUpOrDown;
    [card addSubview:preview];
    NSTextField *title = [NSTextField labelWithString:@"截图已保存到桌面"];
    title.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    title.frame = NSMakeRect(95,38,175,20);
    [card addSubview:title];
    NSTextField *name = [NSTextField labelWithString:file.lastPathComponent];
    name.font = [NSFont systemFontOfSize:11]; name.textColor = NSColor.secondaryLabelColor;
    name.lineBreakMode = NSLineBreakByTruncatingMiddle; name.frame = NSMakeRect(95,17,175,16);
    [card addSubview:name];
    panel.contentView = card;
    _toast = panel;
    [NSApp unhideWithoutActivation];
    [panel orderFrontRegardless];
    NSUInteger number = ++_receiptNumber;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2100*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        if (self->_phase == ShowingResult && self->_receiptNumber == number) {
            [self hideReceipt];
            self->_phase = Idle;
            [NSApp hide:nil];
        }
    });
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSMenu *mainMenu = [NSMenu new];
        NSMenuItem *appItem = [NSMenuItem new];
        [mainMenu addItem:appItem];
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@"取景"];
        [menu addItemWithTitle:@"退出取景" action:@selector(terminate:) keyEquivalent:@"q"];
        appItem.submenu = menu;
        app.mainMenu = mainMenu;
        __attribute__((objc_precise_lifetime)) DockShot *delegate = [DockShot new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}

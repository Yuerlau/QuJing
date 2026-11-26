#import "Capture.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSError *CaptureError(NSString *message) {
    return [NSError errorWithDomain:@"DockShot" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}

void CaptureWindow(CGWindowID windowID, ImageResult result) {
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES
        completionHandler:^(SCShareableContent *content, NSError *error) {
        if (error) { result(NULL,error); return; }
        for (SCWindow *window in content.windows) {
            if (window.windowID != windowID) continue;
            SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
            SCStreamConfiguration *config = [SCStreamConfiguration new];
            CGFloat scale = filter.pointPixelScale;
            config.width = MAX(1, lround(CGRectGetWidth(filter.contentRect) * scale));
            config.height = MAX(1, lround(CGRectGetHeight(filter.contentRect) * scale));
            config.showsCursor = NO;
            config.ignoreShadowsSingleWindow = YES;
            config.ignoreGlobalClipSingleWindow = YES;
            [SCScreenshotManager captureImageWithFilter:filter configuration:config completionHandler:result];
            return;
        }
        result(NULL,CaptureError(@"这个窗口已关闭或无法截取。请再选一次。"));
    }];
}

void CaptureArea(CGRect displayRect, ImageResult result) {
    [SCScreenshotManager captureImageInRect:displayRect completionHandler:result];
}

NSURL *WritePNG(CGImageRef image, NSURL *directory, NSError **error) {
    NSMutableData *png = [NSMutableData data];
    CGImageDestinationRef writer = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png,
        (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    if (!writer) { *error = CaptureError(@"无法创建 PNG 图像。"); return nil; }
    CGImageDestinationAddImage(writer, image, NULL);
    BOOL encoded = CGImageDestinationFinalize(writer);
    CFRelease(writer);
    if (!encoded) { *error = CaptureError(@"PNG 编码未完成。"); return nil; }
    NSDateFormatter *format = [NSDateFormatter new];
    format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    format.dateFormat = @"yyyy-MM-dd HH.mm.ss";
    NSString *base = [@"截图 " stringByAppendingString:[format stringFromDate:NSDate.date]];
    for (NSUInteger i = 1; ; i++) {
        NSString *name = i == 1 ? base : [base stringByAppendingFormat:@" (%lu)",(unsigned long)i];
        NSURL *url = [[directory URLByAppendingPathComponent:name] URLByAppendingPathExtension:@"png"];
        NSError *writeError = nil;
        if ([png writeToURL:url options:NSDataWritingWithoutOverwriting error:&writeError]) return url;
        if (![writeError.domain isEqual:NSCocoaErrorDomain] || writeError.code != NSFileWriteFileExistsError) {
            *error = writeError;
            return nil;
        }
    }
}

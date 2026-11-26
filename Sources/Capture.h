#import <Cocoa/Cocoa.h>

typedef void (^ImageResult)(CGImageRef image, NSError *error);
void CaptureWindow(CGWindowID window, ImageResult result);
void CaptureArea(CGRect displayRect, ImageResult result);
NSURL *WritePNG(CGImageRef image, NSURL *directory, NSError **error);

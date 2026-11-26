#import <Cocoa/Cocoa.h>
@protocol SelectionEvents <NSObject>
- (void)moveTo:(NSPoint)point;
- (void)pressAt:(NSPoint)point;
- (void)dragTo:(NSPoint)point;
- (void)releaseAt:(NSPoint)point clicks:(NSInteger)clicks;
- (void)cancel;
@end
@interface SelectionView : NSView
@property (nonatomic,weak) id<SelectionEvents> events;
@property (nonatomic) NSRect selectedScreenRect;
@property (nonatomic) BOOL dragging;
@property (nonatomic,copy) NSString *windowName;
@property (nonatomic,copy) NSArray<NSValue *> *coveredRects;
@end
@interface SelectionPanel : NSPanel
@end

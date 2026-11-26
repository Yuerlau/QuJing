#import <Cocoa/Cocoa.h>

typedef struct {
    NSPoint anchor;
    CGWindowID downWindow;
    CGWindowID lastClickedWindow;
    BOOL pressed;
    BOOL dragging;
} Selection;

static inline void BeginPress(Selection *s, NSPoint point, CGWindowID window) {
    s->anchor = point;
    s->downWindow = window;
    s->pressed = YES;
    s->dragging = NO;
}

static inline void TrackPress(Selection *s, NSPoint point) {
    if (s->pressed && hypot(point.x-s->anchor.x, point.y-s->anchor.y) >= 5) {
        s->dragging = YES;
        s->lastClickedWindow = kCGNullWindowID;
    }
}

static inline NSRect SelectionRect(NSPoint a, NSPoint b) {
    return NSMakeRect(MIN(a.x,b.x), MIN(a.y,b.y), fabs(a.x-b.x), fabs(a.y-b.y));
}

// Only accept a system-recognized repeat click when both clicks hit the same window.
static inline BOOL ConfirmWindow(Selection *s, CGWindowID upWindow, NSInteger clickCount) {
    CGWindowID hit = s->downWindow == upWindow ? upWindow : kCGNullWindowID;
    BOOL confirmed = !s->dragging && hit && hit == s->lastClickedWindow && clickCount >= 2;
    s->lastClickedWindow = s->dragging ? kCGNullWindowID : hit;
    s->pressed = NO;
    return confirmed;
}

static inline CGRect FlipRect(CGRect rect, CGFloat primaryTop) {
    return CGRectMake(rect.origin.x, primaryTop-CGRectGetMaxY(rect), rect.size.width, rect.size.height);
}

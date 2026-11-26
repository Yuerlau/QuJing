#import "Overlay.h"

@implementation SelectionPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@implementation SelectionView {
    NSTrackingArea *_tracking;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved |
        NSTrackingCursorUpdate | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.crosshairCursor]; }
- (void)cursorUpdate:(NSEvent *)event { [NSCursor.crosshairCursor set]; }
- (NSPoint)screenPoint:(NSEvent *)e { return [self.window convertPointToScreen:e.locationInWindow]; }
- (void)mouseMoved:(NSEvent *)e { [self.events moveTo:[self screenPoint:e]]; }
- (void)mouseDown:(NSEvent *)e { [self.events pressAt:[self screenPoint:e]]; }
- (void)mouseDragged:(NSEvent *)e { [self.events dragTo:[self screenPoint:e]]; }
- (void)mouseUp:(NSEvent *)e { [self.events releaseAt:[self screenPoint:e] clicks:e.clickCount]; }
- (void)keyDown:(NSEvent *)e {
    if (e.keyCode == 53) [self.events cancel];
    else [super keyDown:e];
}
- (void)cancelOperation:(id)sender { [self.events cancel]; }

- (void)drawRect:(NSRect)dirty {
    // Explicitly clear the transparent backing store before changing the selection.
    NSRectFillUsingOperation(dirty, NSCompositingOperationClear);
    NSRect rect = [self.window convertRectFromScreen:self.selectedScreenRect];
    [[NSColor colorWithWhite:0 alpha:.29] setFill];
    NSRectFillUsingOperation(dirty,NSCompositingOperationSourceOver);
    CGFloat radius = self.dragging ? 0 : 8;
    if (!NSIsEmptyRect(rect)) {
        [NSGraphicsContext saveGraphicsState];
        for (NSValue *value in self.coveredRects) {
            NSRect cover = NSIntersectionRect(self.bounds,[self.window convertRectFromScreen:value.rectValue]);
            if (NSIsEmptyRect(cover)) continue;
            NSBezierPath *visible = [NSBezierPath bezierPathWithRect:self.bounds];
            [visible appendBezierPathWithRect:cover];
            visible.windingRule = NSWindingRuleEvenOdd;
            [visible addClip];
        }
        [NSGraphicsContext saveGraphicsState];
        [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius] addClip];
        NSRectFillUsingOperation(rect,NSCompositingOperationClear);
        [NSGraphicsContext restoreGraphicsState];
        NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect,1,1)
            xRadius:radius yRadius:radius];
        border.lineWidth = 2;
        [[NSColor colorWithSRGBRed:.32 green:.68 blue:1 alpha:1] setStroke];
        [border stroke];
        if (!self.dragging) {
            [[NSColor colorWithSRGBRed:.30 green:.58 blue:1 alpha:.10] setFill];
            [border fill];
        }
        [NSGraphicsContext restoreGraphicsState];
    }
    NSString *label;
    if (self.dragging) label = [NSString stringWithFormat:@"%.0f × %.0f 点   ·   松开编辑   ·   Esc 取消",rect.size.width,rect.size.height];
    else if (self.windowName.length) label = [NSString stringWithFormat:@"%@   ·   双击截窗   ·   拖动框选   ·   Esc 取消",self.windowName];
    else label = @"双击窗口截取整窗   ·   拖动框选区域   ·   Esc 取消";
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *attrs = @{NSFontAttributeName:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName:NSColor.whiteColor, NSParagraphStyleAttributeName:style};
    CGFloat width = MIN(ceil([label sizeWithAttributes:attrs].width)+28, NSWidth(self.bounds)-32);
    CGFloat y = 28;
    NSPoint pointer = [self.window convertPointFromScreen:NSEvent.mouseLocation];
    if (pointer.y < 75 && fabs(pointer.x-NSMidX(self.bounds)) < width/2+16)
        y = NSHeight(self.bounds)-84;
    NSRect pill = NSMakeRect(floor((NSWidth(self.bounds)-width)/2),y,width,34);
    [[NSColor colorWithSRGBRed:.09 green:.13 blue:.16 alpha:.94] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:12 yRadius:12] fill];
    [label drawInRect:NSInsetRect(pill,14,8) withAttributes:attrs];
}
@end

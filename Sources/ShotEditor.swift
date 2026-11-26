import AppKit
import CoreImage
import SwiftUI

private let accent = NSColor.systemGreen

@MainActor
private final class EditorPanel: NSPanel {
    var dismiss: (() -> Void)?
    var undoMask: (() -> Void)?
    var saveImage: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss?() } else { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "s": saveImage?(); return true
            case "z": undoMask?(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class MosaicCanvas: NSView {
    let original: CGImage
    private let picture: NSImage
    private var pixelated: CGImage?
    private var maskPicture: NSImage?
    private var masks: [CGRect] = []     // Image pixel coordinates, origin at lower left.
    private var dragStart: CGPoint?
    private var draft: CGRect?
    var didEdit: (() -> Void)?
    var mosaic = false {
        didSet {
            dragStart = nil; draft = nil
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    init(image: CGImage, frame: CGRect) {
        original = image
        picture = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        super.init(frame: frame)
        setAccessibilityLabel("截图预览")
    }
    required init?(coder: NSCoder) { nil }
    private var pixels: CGRect { CGRect(x: 0, y: 0, width: original.width, height: original.height) }
    private func toView(_ r: CGRect) -> CGRect {
        r.applying(.init(scaleX: bounds.width/pixels.width, y: bounds.height/pixels.height))
    }
    private func pixelPoint(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: min(max(0, p.x/bounds.width), 1)*pixels.width,
                       y: min(max(0, p.y/bounds.height), 1)*pixels.height)
    }
    private func maskRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(b.x-a.x), height: abs(b.y-a.y))
            .integral.intersection(pixels)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: mosaic ? .crosshair : .arrow) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard mosaic else { return }
        window?.makeFirstResponder(self)
        dragStart = pixelPoint(event)
    }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDragged(with event: NSEvent) {
        guard let a = dragStart else { return }
        draft = maskRect(from: a, to: pixelPoint(event))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let a = dragStart else { return }
        let rect = maskRect(from: a, to: pixelPoint(event))
        if rect.width > 1 && rect.height > 1 { masks.append(rect); didEdit?() }
        dragStart = nil; draft = nil; needsDisplay = true
    }
    func undoLast() {
        guard !masks.isEmpty else { return }
        masks.removeLast(); needsDisplay = true; didEdit?()
    }
    func prepareMosaic() -> Bool {
        if pixelated != nil { return true }
        let src = CIImage(cgImage: original)
        let block = max(12, round(13 * pixels.width / max(1,bounds.width)))
        let filtered = src.clampedToExtent().applyingFilter("CIPixellate", parameters: [
            kCIInputScaleKey: block, kCIInputCenterKey: CIVector(x: block/2, y: block/2)
        ]).cropped(to: src.extent)
        guard let cg = CIContext().createCGImage(filtered, from: src.extent) else { return false }
        pixelated = cg; maskPicture = NSImage(cgImage: cg, size: pixels.size)
        return true
    }
    override func draw(_ dirtyRect: NSRect) {
        picture.draw(in: bounds)
        if let maskPicture {
            for region in masks + (draft.map { [$0] } ?? []) where !region.isEmpty {
                maskPicture.draw(in: toView(region), from: region, operation: .copy, fraction: 1)
            }
        }
        let line = NSBezierPath(rect: bounds.insetBy(dx: 0.65,dy: 0.65))
        line.lineWidth = 1.3; accent.setStroke(); line.stroke()
    }
    func flattened() -> CGImage? {
        guard !masks.isEmpty else { return original }
        guard let pixelated, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil,width: original.width,height: original.height,bitsPerComponent: 8,
                                  bytesPerRow: 0,space: space,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(original,in: pixels)
        ctx.clip(to: masks)
        ctx.setBlendMode(.copy)
        ctx.draw(pixelated,in: pixels)
        return ctx.makeImage()
    }
}

@objc(DSEditor) @MainActor
public final class ShotEditor: NSObject, NSWindowDelegate, @MainActor NSSharingServicePickerDelegate {
    private var preview: EditorPanel?
    private var toolbar: EditorPanel?
    private var backdrops: [EditorPanel] = []
    private var result: NSWindow?
    private var readTask: Task<Void,Never>?
    private var reading: ImageText?
    private var canvas: MosaicCanvas?
    private var mosaicButton: NSButton?
    private var sharePicker: NSSharingServicePicker?
    private var save: ((CGImage) -> Void)?
    private var onDismiss: (() -> Void)?
    private var saving = false

    @objc(showImage:frame:onSave:onDismiss:)
    public func show(image: CGImage, frame: NSRect, onSave: @escaping (CGImage) -> Void, onDismiss: @escaping () -> Void) {
        self.save = onSave; self.onDismiss = onDismiss
        let screen = NSScreen.screens.max {
            let a = $0.frame.intersection(frame), b = $1.frame.intersection(frame)
            return (a.isNull ? 0 : a.width*a.height) < (b.isNull ? 0 : b.width*b.height)
        }
        let safe = (screen?.visibleFrame ?? frame).insetBy(dx: 5,dy: 5)
        let tools = [("提取文字","text.viewfinder",#selector(extract)), ("翻译","character.bubble",#selector(translate)),
                     ("保存图片","square.and.arrow.down",#selector(writeImage)), ("马赛克","square.grid.3x3.fill",#selector(toggleMosaic)),
                     ("分享","square.and.arrow.up",#selector(shareImage(_:)))]
        let buttonWidth: CGFloat = 44, inset: CGFloat = 6
        let barSize = NSSize(width: 2 * inset + CGFloat(tools.count) * buttonWidth, height: 44), gap: CGFloat = 7
        let factor = min(1,safe.width/frame.width,(safe.height-barSize.height-gap)/frame.height)
        let width = max(1,frame.width*factor), height = max(1,frame.height*factor)
        let left = max(safe.minX,min(frame.minX,safe.maxX-width))
        let bottom = max(safe.minY,min(frame.minY,safe.maxY-height))
        var box = NSRect(x:left,y:bottom,width:width,height:height)
        var barY = box.minY-gap-barSize.height
        if barY < safe.minY {
            if box.maxY+gap+barSize.height <= safe.maxY { barY = box.maxY+gap }
            else { box.origin.y = safe.minY+barSize.height+gap; barY = safe.minY }
        }
        let barX = min(max(safe.minX,box.maxX-barSize.width),safe.maxX-barSize.width)
        let p = panel(box,title:"截图预览"), t = panel(NSRect(origin:NSPoint(x:barX,y:barY),size:barSize),title:"截图工具")
        let c = MosaicCanvas(image:image,frame:NSRect(origin:.zero,size:box.size))
        c.didEdit = { [weak self] in self?.reading = nil; self?.closeResult() }
        c.toolTip = "按 Esc，或在选区外点右键取消"
        p.contentView = c; preview = p; toolbar = t; canvas = c
        let glass = NSVisualEffectView(frame:NSRect(origin:.zero,size:barSize))
        glass.material = .popover; glass.blendingMode = .behindWindow; glass.state = .active
        glass.wantsLayer = true; glass.layer?.cornerRadius = 9; glass.layer?.masksToBounds = true
        for (i, item) in tools.enumerated() {
            let button = NSButton(title:item.0,target:self,action:item.2)
            button.frame = NSRect(x:inset + CGFloat(i) * buttonWidth,y:3,width:buttonWidth,height:38)
            button.bezelStyle = .inline; button.isBordered = false
            button.image = NSImage(systemSymbolName:item.1,accessibilityDescription:item.0)?
                .withSymbolConfiguration(.init(pointSize:18,weight:.medium))
            button.imagePosition = button.image == nil ? .noImage : .imageOnly
            button.toolTip = item.0; button.setAccessibilityLabel(item.0)
            if item.2 == #selector(toggleMosaic) { mosaicButton = button }
            if item.2 == #selector(shareImage(_:)) { button.sendAction(on: .leftMouseDown) }
            glass.addSubview(button)
        }
        t.contentView = glass
        NSApp.unhideWithoutActivation(); NSApp.activate(ignoringOtherApps:true)
        // The workspace behind the selection belongs to this editing session.
        // Receive an outside secondary click before the desktop opens its menu.
        backdrops = NSScreen.screens.map { screen in
            let background = panel(screen.frame,title:"截图编辑背景")
            background.level = .init(rawValue: NSWindow.Level.floating.rawValue - 1)
            background.backgroundColor = NSColor.black.withAlphaComponent(0.065)
            background.hasShadow = false
            background.hidesOnDeactivate = true
            background.isExcludedFromWindowsMenu = true
            background.orderFrontRegardless()
            return background
        }
        p.makeKeyAndOrderFront(nil); p.makeFirstResponder(c); t.orderFrontRegardless()
    }

    private func panel(_ frame: NSRect,title: String) -> EditorPanel {
        let p = EditorPanel(contentRect:frame,styleMask:.borderless,backing:.buffered,defer:false)
        p.isReleasedWhenClosed = false; p.isOpaque = false; p.backgroundColor = .clear
        p.title = title; p.level = .floating; p.hasShadow = true; p.hidesOnDeactivate = false
        p.collectionBehavior = [.fullScreenAuxiliary,.moveToActiveSpace]
        p.setFrame(frame,display:false)
        p.dismiss = { [weak self] in self?.cancelEditing() }
        p.undoMask = { [weak self] in self?.canvas?.undoLast() }
        p.saveImage = { [weak self] in self?.writeImage() }
        return p
    }
    @objc public func containsPreviewPoint(_ point: NSPoint) -> Bool {
        guard let preview else { return false }
        return NSPointInRect(point, preview.frame)
    }
    @objc public func bringForward() {
        NSApp.activate(ignoringOtherApps:true)
        for background in backdrops { background.orderFrontRegardless() }
        preview?.orderFrontRegardless(); toolbar?.makeKeyAndOrderFront(nil)
    }
    private func closeResult() {
        readTask?.cancel(); readTask = nil
        result?.contentView = nil; result?.orderOut(nil); result = nil
    }
    @objc public func finish() {
        dismissSharePicker()
        closeResult()
        for background in backdrops { background.orderOut(nil) }
        backdrops.removeAll()
        preview?.orderOut(nil); toolbar?.orderOut(nil); preview = nil; toolbar = nil
        mosaicButton = nil; canvas = nil; reading = nil; save = nil; onDismiss = nil
    }
    private func cancelEditing() {
        guard !saving else { return }
        onDismiss?()
    }
    @objc public func saveFailed(_ reason:String) { saving = false; message(reason) }
    private func message(_ text:String) {
        let a = NSAlert(); a.messageText = text; a.addButton(withTitle:"好")
        if let window = toolbar { a.beginSheetModal(for: window) }
    }
    @objc private func writeImage() {
        guard !saving, let c = canvas else { return }
        guard let cg = c.flattened() else { message("无法生成截图，请重试。"); return }
        saving = true; save?(cg)
    }
    @objc private func shareImage(_ sender: NSButton) {
        guard !saving, let canvas else { return }
        if dismissSharePicker() { return }
        guard let snapshot = canvas.flattened() else { message("无法生成分享图片，请重试。"); return }
        let size = NSSize(width:snapshot.width, height:snapshot.height)
        let picker = NSSharingServicePicker(items:[NSImage(cgImage:snapshot, size:size)])
        sharePicker = picker
        picker.delegate = self
        picker.show(relativeTo:sender.bounds, of:sender, preferredEdge:.minY)
    }
    @discardableResult @objc public func dismissSharePicker() -> Bool {
        guard let picker = sharePicker else { return false }
        sharePicker = nil
        picker.close()
        return true
    }
    public func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if sharePicker === sharingServicePicker { sharePicker = nil }
    }
    @objc private func toggleMosaic() {
        guard let c = canvas, !saving else { return }
        if !c.mosaic && !c.prepareMosaic() { message("无法生成马赛克，请重试。"); return }
        c.mosaic.toggle()
        mosaicButton?.contentTintColor = c.mosaic ? accent : nil
        mosaicButton?.toolTip = c.mosaic ? "在截图中拖动涂抹，⌘Z 撤销" : "马赛克"
        c.toolTip = c.mosaic ? "拖动添加马赛克，⌘Z 撤销，Esc 取消截图" : "按 Esc，或在选区外点右键取消"
        preview?.makeKeyAndOrderFront(nil); toolbar?.orderFrontRegardless()
    }
    @objc private func extract() { showText(false) }
    @objc private func translate() { showText(true) }
    private func showText(_ translate: Bool) {
        guard !saving, let c = canvas else { return }
        guard let image = c.flattened() else { message("无法读取截图，请重试。"); return }
        let previous = result?.contentView as? NSHostingView<TextResultView>
        let visibleText = previous?.rootView.model.output
        let reuseExtraction = translate && previous?.rootView.translating == false
        closeResult()
        let win = NSWindow(contentRect:NSRect(x:0,y:0,width:392,height:228),
                           styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        win.title = translate ? "翻译为简体中文" : "提取文字"
        win.level = .floating; win.isReleasedWhenClosed = false; win.delegate = self
        win.contentMinSize = NSSize(width:275,height:140)
        let model = TextResultModel()
        let content = NSHostingView(rootView:TextResultView(model:model, translating:translate))
        content.sizingOptions = []
        win.contentView = content
        if let bar = toolbar, let visible = bar.screen?.visibleFrame {
            let x = max(visible.minX,min(bar.frame.maxX-win.frame.width,visible.maxX-win.frame.width))
            let below = bar.frame.minY-win.frame.height-7
            let above = (preview?.frame.maxY ?? bar.frame.maxY)+7
            win.setFrameOrigin(NSPoint(x:x,y:below >= visible.minY ? below : min(visible.maxY-win.frame.height,above)))
        } else { win.center() }
        result = win; win.makeKeyAndOrderFront(nil)
        let current = reading ?? ImageText(image)
        reading = current
        readTask = Task {
            if reuseExtraction, let visibleText, !visibleText.isEmpty {
                await model.translateText(visibleText)
            } else {
                await model.recognize(current, translate:translate)
            }
        }
    }
    public func windowWillClose(_ notification: Notification) {
        if let w = notification.object as? NSWindow, w === result { readTask?.cancel(); readTask = nil; w.contentView = nil; result = nil }
    }
}

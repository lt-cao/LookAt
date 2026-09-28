import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImageCanvas: NSViewRepresentable {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> ZoomableImageView {
        let view = ZoomableImageView()
        view.onZoomChanged = { [weak model] percent, sourceURL in
            guard model?.currentURL == sourceURL else { return }
            model?.canvasDidChangeZoom(percent)
        }
        view.onNeedsFullResolution = { [weak model] sourceURL in
            guard model?.currentURL == sourceURL else { return }
            model?.requestFullResolutionIfNeeded()
        }
        view.onOpenFile = { [weak model] url in
            model?.open(url)
        }
        view.onShowInfo = { [weak model] in
            model?.showInfo()
        }
        view.onShowSettings = {
            SettingsWindowController.shared.show()
        }
        return view
    }

    func updateNSView(_ view: ZoomableImageView, context: Context) {
        if context.coordinator.lastRenderRevision != model.renderRevision {
            context.coordinator.lastRenderRevision = model.renderRevision
            if let frame = model.renderedFrame {
                let resetsViewport = view.sourceURL != frame.sourceURL
                view.setImage(
                    frame.cgImage,
                    logicalPixelSize: frame.logicalPixelSize,
                    sourceURL: frame.sourceURL,
                    isFullResolution: frame.isFullResolution,
                    animation: frame.animation,
                    resetsViewport: resetsViewport
                )
            } else {
                view.clearImage()
            }
        }
        view.currentURL = model.currentURL
        view.isLoadingNewImage = model.isLoadingPreview
        view.zoomSensitivity = CGFloat(settings.zoomSensitivity)
        view.invertsScrollZoom = settings.invertsScrollZoom
        if !model.isLoadingPreview { view.setRotation(model.rotation) }

        if context.coordinator.lastCommandID != model.canvasCommand.id {
            context.coordinator.lastCommandID = model.canvasCommand.id
            switch model.canvasCommand.action {
            case .fit:
                view.fitToWindow()
            case .actualSize:
                view.setActualSize()
            case .zoomIn:
                view.zoom(by: 1.2)
            case .zoomOut:
                view.zoom(by: 1 / 1.2)
            }
        }
    }

    static func dismantleNSView(_ view: ZoomableImageView, coordinator: Coordinator) {
        view.clearImage()
    }

    final class Coordinator {
        weak var model: AppModel?
        var lastCommandID = -1
        var lastRenderRevision = -1

        init(model: AppModel) {
            self.model = model
        }
    }
}

@MainActor
final class ZoomableImageView: NSView {
    var onZoomChanged: ((Int, URL) -> Void)?
    var onNeedsFullResolution: ((URL) -> Void)?
    var onOpenFile: ((URL) -> Void)?
    var onShowInfo: (() -> Void)?
    var onShowSettings: (() -> Void)?
    fileprivate private(set) var renderedImage: CGImage?
    fileprivate private(set) var sourceURL: URL?
    fileprivate var currentURL: URL?
    fileprivate var zoomSensitivity: CGFloat = 1
    fileprivate var invertsScrollZoom = false
    fileprivate var isLoadingNewImage = false

    private var scale: CGFloat = 1
    private var fitScale: CGFloat = 1
    private var panOffset = CGPoint.zero
    private var rotation = 0
    private var isFitted = true
    private var usesActualPixelScale = false
    private var lastDragPoint: CGPoint?
    private var imagePixelSize = CGSize.zero
    private var isFullResolution = false
    private let imageLayer = CALayer()
    private var lastReportedZoom = -1
    private var zoomNotificationScheduled = false
    private var pendingZoomPercent = 100
    private var pendingZoomSource: URL?
    private let toolbarHeight: CGFloat = 52

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layerContentsRedrawPolicy = .never

        imageLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        imageLayer.drawsAsynchronously = true
        imageLayer.allowsEdgeAntialiasing = true
        layer?.addSublayer(imageLayer)

        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    func setImage(
        _ newImage: CGImage,
        logicalPixelSize: CGSize,
        sourceURL: URL,
        isFullResolution: Bool,
        animation: AppModel.AnimatedPlayback?,
        resetsViewport: Bool
    ) {
        renderedImage = newImage
        self.sourceURL = sourceURL
        self.isFullResolution = isFullResolution
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = newImage
        imagePixelSize = logicalPixelSize
        imageLayer.bounds = CGRect(origin: .zero, size: imagePixelSize)
        imageLayer.isHidden = false
        configurePlayback(animation)
        CATransaction.commit()

        if resetsViewport {
            endDrag()
            usesActualPixelScale = false
            panOffset = .zero
            isFitted = true
            updateFitScale()
        } else if isFitted {
            updateFitScale()
        } else {
            updateFitReference()
            clampPanOffset()
        }
        applyLayerGeometry()
        resetCursorRects()
    }

    func clearImage() {
        endDrag()
        renderedImage = nil
        sourceURL = nil
        isFullResolution = false
        imagePixelSize = .zero
        pendingZoomSource = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.removeAnimation(forKey: "gifPlayback")
        imageLayer.contents = nil
        imageLayer.isHidden = true
        CATransaction.commit()
        resetCursorRects()
    }

    func setRotation(_ degrees: Int) {
        guard rotation != degrees else { return }
        rotation = degrees
        if isFitted {
            updateFitScale()
        } else {
            updateFitReference()
        }
        panOffset = .zero
        applyLayerGeometry()
    }

    func fitToWindow() {
        isFitted = true
        usesActualPixelScale = false
        panOffset = .zero
        updateFitScale()
        applyLayerGeometry()
    }

    func setActualSize() {
        guard renderedImage != nil else { return }
        isFitted = false
        usesActualPixelScale = true
        panOffset = .zero
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        setScale(1 / backingScale, anchoredAt: contentCenter, enforcesMinimumZoom: false)
        if let sourceURL {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sourceURL == sourceURL, !self.isLoadingNewImage else { return }
                self.onNeedsFullResolution?(sourceURL)
            }
        }
    }

    func zoom(by multiplier: CGFloat, anchor: CGPoint? = nil) {
        guard renderedImage != nil else { return }
        guard multiplier.isFinite, multiplier > 0 else { return }
        isFitted = false
        usesActualPixelScale = false
        let point = anchor ?? contentCenter
        setScale(scale * multiplier, anchoredAt: point)
    }

    override func layout() {
        super.layout()
        if isFitted {
            updateFitScale()
        } else {
            updateFitReference()
        }
        clampPanOffset()
        applyLayerGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { endDrag() }
        updateBackingScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingScale()
    }

    private func updateBackingScale() {
        imageLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if usesActualPixelScale {
            setScale(1 / imageLayer.contentsScale, anchoredAt: contentCenter, enforcesMinimumZoom: false)
        } else {
            applyLayerGeometry()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: renderedImage == nil ? .arrow : .openHand)
    }

    override func scrollWheel(with event: NSEvent) {
        guard renderedImage != nil, !isLoadingNewImage else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }
        let direction: CGFloat = invertsScrollZoom ? -1 : 1
        let baseSensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.012 : 0.075
        let sensitivity = baseSensitivity * zoomSensitivity * direction
        let multiplier = exp(delta * sensitivity)
        zoom(by: multiplier, anchor: convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        guard !isLoadingNewImage else { return }
        let multiplier = max(0.2, 1 + event.magnification)
        zoom(by: multiplier, anchor: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        guard renderedImage != nil, !isLoadingNewImage else { return }
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            if usesActualPixelScale {
                fitToWindow()
            } else {
                setActualSize()
            }
            return
        }
        beginDrag(event)
    }

    override func mouseDragged(with event: NSEvent) {
        continueDrag(event)
    }

    override func mouseUp(with event: NSEvent) {
        endDrag()
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, renderedImage != nil, !isLoadingNewImage else { return }
        beginDrag(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        continueDrag(event)
    }

    override func otherMouseUp(with event: NSEvent) {
        endDrag()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard currentURL != nil, !isLoadingNewImage else { return nil }

        let menu = NSMenu(title: "Ảnh")

        let copyItem = NSMenuItem(title: "Sao chép", action: #selector(copyImage), keyEquivalent: "")
        copyItem.target = self
        copyItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        menu.addItem(copyItem)

        let openWithItem = NSMenuItem(title: "Mở bằng", action: nil, keyEquivalent: "")
        openWithItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        openWithItem.submenu = makeOpenWithMenu()
        menu.addItem(openWithItem)

        let revealItem = NSMenuItem(title: "Mở thư mục", action: #selector(revealInFinder), keyEquivalent: "")
        revealItem.target = self
        revealItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(revealItem)

        let infoItem = NSMenuItem(title: "Thông tin", action: #selector(showInfo), keyEquivalent: "")
        infoItem.target = self
        infoItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(infoItem)

        let settingsItem = NSMenuItem(title: "Cài Đặt", action: #selector(showSettings), keyEquivalent: "")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        return menu
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURL(from: sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = fileURL(from: sender) else { return false }
        onOpenFile?(url)
        return true
    }

    private func beginDrag(_ event: NSEvent) {
        endDrag()
        lastDragPoint = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.push()
    }

    private func continueDrag(_ event: NSEvent) {
        guard let lastDragPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        panOffset.x += point.x - lastDragPoint.x
        panOffset.y += point.y - lastDragPoint.y
        self.lastDragPoint = point
        isFitted = false
        clampPanOffset()
        applyLayerGeometry()
    }

    private func endDrag() {
        guard lastDragPoint != nil else { return }
        lastDragPoint = nil
        NSCursor.pop()
    }

    private func setScale(
        _ proposedScale: CGFloat,
        anchoredAt anchor: CGPoint,
        enforcesMinimumZoom: Bool = true
    ) {
        let minimumScale = max(fitScale * 0.7, 0.0001)
        let maximumScale = max(fitScale * 64, 64)
        let lowerBound = enforcesMinimumZoom ? minimumScale : 0.0001
        guard proposedScale.isFinite else { return }
        let newScale = min(max(proposedScale, lowerBound), maximumScale)
        let oldScale = max(scale, 0.0001)
        let center = CGPoint(x: contentCenter.x + panOffset.x, y: contentCenter.y + panOffset.y)
        let ratio = newScale / oldScale
        panOffset.x += (anchor.x - center.x) * (1 - ratio)
        panOffset.y += (anchor.y - center.y) * (1 - ratio)
        scale = newScale
        clampPanOffset()
        notifyZoomChanged()
        applyLayerGeometry()
    }

    private func updateFitScale() {
        guard let calculatedScale = calculatedFitScale() else { return }
        fitScale = calculatedScale
        scale = fitScale
        notifyZoomChanged()
    }

    private func updateFitReference() {
        guard let calculatedScale = calculatedFitScale() else { return }
        fitScale = calculatedScale
        notifyZoomChanged()
    }

    private func calculatedFitScale() -> CGFloat? {
        guard renderedImage != nil, imagePixelSize.width > 0, imagePixelSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let isQuarterTurn = rotation == 90 || rotation == 270
        let width = isQuarterTurn ? imagePixelSize.height : imagePixelSize.width
        let height = isQuarterTurn ? imagePixelSize.width : imagePixelSize.height
        let availableWidth = max(bounds.width, 80)
        let availableHeight = max(bounds.height - toolbarHeight, 80)
        return min(availableWidth / width, availableHeight / height)
    }

    private func notifyZoomChanged() {
        let normalizedScale = scale / max(fitScale, 0.0001)
        let percent = Int((normalizedScale * 100).rounded())
        pendingZoomPercent = percent
        pendingZoomSource = sourceURL
        guard !zoomNotificationScheduled else { return }
        zoomNotificationScheduled = true
        // Geometry still follows every input event. Only the SwiftUI label is
        // coalesced, avoiding state publication inside updateNSView/layout.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in
            guard let self else { return }
            self.zoomNotificationScheduled = false
            guard let url = self.pendingZoomSource, url == self.sourceURL,
                  !self.isLoadingNewImage, self.pendingZoomPercent != self.lastReportedZoom else { return }
            self.lastReportedZoom = self.pendingZoomPercent
            self.onZoomChanged?(self.pendingZoomPercent, url)
        }
    }

    private func applyLayerGeometry() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.position = pixelAlignedLayerPosition
        var transform = CGAffineTransform(rotationAngle: CGFloat(rotation) * .pi / 180)
        transform = transform.scaledBy(x: scale, y: scale)
        imageLayer.setAffineTransform(transform)
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let physicalPixelScale = scale * backingScale
        imageLayer.magnificationFilter = isFullResolution && physicalPixelScale >= 0.999
            ? .nearest
            : .linear
        CATransaction.commit()
    }

    private func configurePlayback(_ playback: AppModel.AnimatedPlayback?) {
        imageLayer.removeAnimation(forKey: "gifPlayback")
        guard let playback,
              playback.frames.count > 1,
              playback.frames.count == playback.frameDurations.count else { return }

        let totalDuration = playback.frameDurations.reduce(0, +)
        guard totalDuration > 0 else { return }

        var elapsed: TimeInterval = 0
        let keyTimes = playback.frameDurations.map { duration -> NSNumber in
            defer { elapsed += duration }
            return NSNumber(value: elapsed / totalDuration)
        }

        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = playback.frames
        animation.keyTimes = keyTimes
        animation.duration = totalDuration
        animation.calculationMode = .discrete
        animation.repeatCount = playback.loopCount == 0
            ? .infinity
            : Float(Double(playback.loopCount) + 1)
        if playback.loopCount != 0 {
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }
        imageLayer.add(animation, forKey: "gifPlayback")
    }

    private var pixelAlignedLayerPosition: CGPoint {
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let isQuarterTurn = rotation == 90 || rotation == 270
        let displayedWidth = (isQuarterTurn ? imagePixelSize.height : imagePixelSize.width) * scale
        let displayedHeight = (isQuarterTurn ? imagePixelSize.width : imagePixelSize.height) * scale
        let desiredCenter = CGPoint(
            x: contentCenter.x + panOffset.x,
            y: contentCenter.y + panOffset.y
        )
        let originX = desiredCenter.x - displayedWidth / 2
        let originY = desiredCenter.y - displayedHeight / 2
        let alignedOriginX = (originX * backingScale).rounded() / backingScale
        let alignedOriginY = (originY * backingScale).rounded() / backingScale
        return CGPoint(
            x: alignedOriginX + displayedWidth / 2,
            y: alignedOriginY + displayedHeight / 2
        )
    }

    private var contentCenter: CGPoint {
        CGPoint(
            x: bounds.midX,
            y: max((bounds.height - toolbarHeight) / 2, 40)
        )
    }

    private func clampPanOffset() {
        guard renderedImage != nil, imagePixelSize.width > 0, imagePixelSize.height > 0,
              bounds.width > 0, bounds.height > toolbarHeight else { return }

        let isQuarterTurn = rotation == 90 || rotation == 270
        let imageWidth = (isQuarterTurn ? imagePixelSize.height : imagePixelSize.width) * scale
        let imageHeight = (isQuarterTurn ? imagePixelSize.width : imagePixelSize.height) * scale
        let viewport = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: bounds.height - toolbarHeight
        )

        // Half on each axis only guarantees a quarter of the area at a corner.
        let visibleFraction = sqrt(CGFloat(0.5))
        let requiredVisibleWidth = min(imageWidth, viewport.width) * visibleFraction
        let requiredVisibleHeight = min(imageHeight, viewport.height) * visibleFraction
        let minimumCenterX = viewport.minX - imageWidth / 2 + requiredVisibleWidth
        let maximumCenterX = viewport.maxX + imageWidth / 2 - requiredVisibleWidth
        let minimumCenterY = viewport.minY - imageHeight / 2 + requiredVisibleHeight
        let maximumCenterY = viewport.maxY + imageHeight / 2 - requiredVisibleHeight

        let proposedCenterX = contentCenter.x + panOffset.x
        let proposedCenterY = contentCenter.y + panOffset.y
        let clampedCenterX = min(max(proposedCenterX, minimumCenterX), maximumCenterX)
        let clampedCenterY = min(max(proposedCenterY, minimumCenterY), maximumCenterY)
        panOffset.x = clampedCenterX - contentCenter.x
        panOffset.y = clampedCenterY - contentCenter.y
    }

    private func fileURL(from draggingInfo: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]
        return draggingInfo.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        )?.first as? URL
    }

    private func makeOpenWithMenu() -> NSMenu {
        let submenu = NSMenu(title: "Mở bằng")
        guard let currentURL else { return submenu }

        let applicationURLs = NSWorkspace.shared.urlsForApplications(toOpen: currentURL)
            .sorted {
                $0.deletingPathExtension().lastPathComponent.localizedStandardCompare(
                    $1.deletingPathExtension().lastPathComponent
                ) == .orderedAscending
            }

        if applicationURLs.isEmpty {
            let emptyItem = NSMenuItem(title: "Không tìm thấy ứng dụng", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
            return submenu
        }

        var seenBundleIdentifiers = Set<String>()
        for applicationURL in applicationURLs {
            let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier ?? applicationURL.path
            guard seenBundleIdentifiers.insert(bundleIdentifier).inserted else { continue }

            let title = applicationURL.deletingPathExtension().lastPathComponent
            let item = NSMenuItem(title: title, action: #selector(openWithApplication(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = applicationURL
            let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            submenu.addItem(item)
        }
        return submenu
    }

    @objc private func openWithApplication(_ sender: NSMenuItem) {
        guard let currentURL,
              let applicationURL = sender.representedObject as? URL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [currentURL],
            withApplicationAt: applicationURL,
            configuration: configuration
        )
    }

    @objc private func copyImage() {
        guard let currentURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([currentURL as NSURL])
    }

    @objc private func revealInFinder() {
        guard let currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([currentURL])
    }

    @objc private func showInfo() {
        onShowInfo?()
    }

    @objc private func showSettings() {
        onShowSettings?()
    }
}

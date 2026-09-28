import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum CanvasAction: Equatable {
        case fit
        case actualSize
        case zoomIn
        case zoomOut
    }

    struct CanvasCommand: Equatable {
        let id: Int
        let action: CanvasAction
    }

    struct RenderedFrame: @unchecked Sendable {
        let cgImage: CGImage
        let logicalPixelSize: CGSize
        let sourceURL: URL
        let isFullResolution: Bool
        let sourceFrameCount: Int
        let animation: AnimatedPlayback?
        var supportsAnimation = false
        var animationIsResolved = false

        var stillPreview: RenderedFrame {
            RenderedFrame(
                cgImage: cgImage, logicalPixelSize: logicalPixelSize,
                sourceURL: sourceURL, isFullResolution: isFullResolution,
                sourceFrameCount: sourceFrameCount, animation: nil,
                supportsAnimation: supportsAnimation
            )
        }
    }

    struct AnimatedPlayback: @unchecked Sendable {
        let frames: [CGImage]
        let frameDurations: [TimeInterval]
        let loopCount: Int
        let isFullResolution: Bool
    }

    @Published private(set) var image: NSImage?
    @Published private(set) var currentURL: URL?
    @Published private(set) var siblingURLs: [URL] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var rotation = 0
    @Published private(set) var zoomPercent = 100
    @Published private(set) var pixelSize: CGSize?
    @Published private(set) var fileSizeText = ""
    @Published private(set) var imageMetadataLines: [String] = []
    @Published private(set) var renderedFrame: RenderedFrame?
    @Published private(set) var renderRevision = 0
    @Published private(set) var isLoadingPreview = false
    @Published private(set) var isLoadingFullResolution = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var canvasCommand = CanvasCommand(id: 0, action: .fit)

    private var nextCommandID = 1
    private var activeLoadID = UUID()
    private var previewTask: Task<Void, Never>?
    private var fullResolutionTask: Task<Void, Never>?
    private var animationTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var directoryTask: Task<Void, Never>?
    private var prefetchTasks: [URL: Task<Void, Never>] = [:]
    private var previewCache: [URL: RenderedFrame] = [:]
    private var siblingDirectory: URL?
    private var pendingActualSize = false
    private var wantsFullResolution = false
    private var fileDateLines: [String] = []

    // Bound ImageIO work to one foreground decode and one speculative decode.
    // A cancelled synchronous ImageIO call can finish, but cannot spawn an
    // unbounded set of large bitmaps when the user holds down the arrow key.
    private actor FrameDecoder {
        func decode(at url: URL, maximumPixelSize: Int?, fullResolution: Bool, animation: Bool) -> RenderedFrame? {
            guard !Task.isCancelled else { return nil }
            return autoreleasepool {
                AppModel.decodeFrame(at: url, maximumPixelSize: maximumPixelSize,
                                     isFullResolution: fullResolution, loadsAnimation: animation)
            }
        }
    }

    private static let foregroundDecoder = FrameDecoder()
    private static let prefetchDecoder = FrameDecoder()

    private init() {}

    var displayName: String {
        currentURL?.lastPathComponent ?? "LookAt"
    }

    var imageDetails: String {
        var parts: [String] = []
        if let pixelSize {
            parts.append("\(Int(pixelSize.width)) × \(Int(pixelSize.height))")
        }
        if !fileSizeText.isEmpty {
            parts.append(fileSizeText)
        }
        return parts.joined(separator: "  •  ")
    }

    var positionText: String? {
        guard let currentIndex, siblingURLs.count > 1 else { return nil }
        return "\(currentIndex + 1) / \(siblingURLs.count)"
    }

    var canShowPrevious: Bool {
        guard let currentIndex else { return false }
        return currentIndex > 0
    }

    var canShowNext: Bool {
        guard let currentIndex else { return false }
        return currentIndex + 1 < siblingURLs.count
    }

    func openCommandLineImageIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments.dropFirst()
        guard let path = arguments.first, !path.hasPrefix("-") else { return }
        open(URL(fileURLWithPath: path))
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Mở ảnh"
        panel.prompt = "Mở"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    func open(_ url: URL, reusesPreview: Bool = false) {
        guard url.isFileURL else {
            errorMessage = "Hãy chọn một tệp ảnh trên máy."
            return
        }
        let standardizedURL = url.standardizedFileURL
        if !reusesPreview {
            // Finder/drop/open-panel requests may point to a file just overwritten
            // by an editor. Only arrow navigation reuses a neighboring preview.
            previewCache.removeValue(forKey: standardizedURL)
            prefetchTasks[standardizedURL]?.cancel()
            prefetchTasks[standardizedURL] = nil
        }
        activeLoadID = UUID()
        let loadID = activeLoadID
        previewTask?.cancel()
        fullResolutionTask?.cancel()
        animationTask?.cancel()
        metadataTask?.cancel()
        previewTask = nil
        fullResolutionTask = nil
        animationTask = nil
        isLoadingFullResolution = false
        pendingActualSize = false
        wantsFullResolution = false

        currentURL = standardizedURL
        rotation = 0
        zoomPercent = 100
        pixelSize = nil
        fileSizeText = ""
        imageMetadataLines = []
        fileDateLines = []
        errorMessage = nil
        isLoadingPreview = true

        refreshSiblingImages(around: standardizedURL, forceRefresh: !reusesPreview)
        loadMetadata(for: standardizedURL, loadID: loadID)

        if let cachedFrame = previewCache[standardizedURL] {
            applyPreview(cachedFrame, for: standardizedURL, loadID: loadID)
            return
        }

        isLoadingPreview = true
        let maximumPixelSize = previewMaximumPixelSize
        if let inFlightPrefetch = prefetchTasks[standardizedURL] {
            previewTask = Task { [weak self] in
                await inFlightPrefetch.value
                guard !Task.isCancelled, let self, self.activeLoadID == loadID else { return }
                self.previewTask = nil
                if let cachedFrame = self.previewCache[standardizedURL] {
                    self.applyPreview(cachedFrame, for: standardizedURL, loadID: loadID)
                } else {
                    self.startPreviewDecode(
                        for: standardizedURL,
                        loadID: loadID,
                        maximumPixelSize: maximumPixelSize
                    )
                }
            }
        } else {
            startPreviewDecode(
                for: standardizedURL,
                loadID: loadID,
                maximumPixelSize: maximumPixelSize
            )
        }

    }

    private func startPreviewDecode(for url: URL, loadID: UUID, maximumPixelSize: Int) {
        let decodeTask = Task.detached(priority: .userInitiated) {
            await Self.foregroundDecoder.decode(at: url, maximumPixelSize: maximumPixelSize,
                                                fullResolution: false, animation: false)
        }

        previewTask = Task { [weak self] in
            let frame = await withTaskCancellationHandler {
                await decodeTask.value
            } onCancel: {
                decodeTask.cancel()
            }

            guard !Task.isCancelled, let self, self.activeLoadID == loadID else { return }
            self.previewTask = nil
            guard let frame else {
                if self.activeLoadID == loadID {
                    self.isLoadingPreview = false
                    self.pendingActualSize = false
                    self.wantsFullResolution = false
                    self.renderedFrame = nil
                    self.image = nil
                    self.renderRevision += 1
                    self.errorMessage = "Không thể đọc ảnh “\(url.lastPathComponent)”."
                }
                return
            }
            self.applyPreview(frame, for: url, loadID: loadID)
        }
    }

    func showPrevious() {
        guard let currentIndex, currentIndex > 0 else { return }
        open(siblingURLs[currentIndex - 1], reusesPreview: true)
    }

    func showNext() {
        guard let currentIndex, currentIndex + 1 < siblingURLs.count else { return }
        open(siblingURLs[currentIndex + 1], reusesPreview: true)
    }

    func rotateLeft() {
        guard image != nil, !isLoadingPreview else { return }
        rotation = (rotation + 270) % 360
        issue(.fit)
    }

    func rotateRight() {
        guard image != nil, !isLoadingPreview else { return }
        rotation = (rotation + 90) % 360
        issue(.fit)
    }

    func zoomIn() {
        guard image != nil, !isLoadingPreview else { return }
        issue(.zoomIn)
    }

    func zoomOut() {
        guard image != nil, !isLoadingPreview else { return }
        issue(.zoomOut)
    }

    func fitToWindow() {
        if isLoadingPreview {
            pendingActualSize = false
            wantsFullResolution = false
            return
        }
        guard image != nil else { return }
        issue(.fit)
    }

    func actualSize() {
        guard currentURL != nil else { return }
        if isLoadingPreview {
            pendingActualSize = true
            wantsFullResolution = true
            return
        }
        requestFullResolutionIfNeeded()
        issue(.actualSize)
    }

    func canvasDidChangeZoom(_ percent: Int) {
        guard !isLoadingPreview else { return }
        let clamped = min(max(percent, 2), 6400)
        if zoomPercent != clamped {
            zoomPercent = clamped
        }
        if percent > 110 {
            requestFullResolutionIfNeeded()
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func showInfo() {
        guard let currentURL else { return }
        let dimensions = pixelSize.map { "\(Int($0.width)) × \(Int($0.height)) px" } ?? "—"

        var lines = [
            "Kích thước: \(dimensions)",
            "Dung lượng: \(fileSizeText.isEmpty ? "—" : fileSizeText)"
        ]
        lines.append(contentsOf: imageMetadataLines)
        lines.append(contentsOf: fileDateLines)
        lines.append(contentsOf: [
            "Vị trí: \(currentURL.deletingLastPathComponent().path)"
        ])

        let alert = NSAlert()
        alert.messageText = currentURL.lastPathComponent
        alert.informativeText = lines.joined(separator: "\n")
        alert.icon = image
        alert.addButton(withTitle: "Đóng")
        alert.runModal()
    }

    private func issue(_ action: CanvasAction) {
        canvasCommand = CanvasCommand(id: nextCommandID, action: action)
        nextCommandID += 1
    }

    private var previewMaximumPixelSize: Int {
        let window = NSApp.keyWindow
        let screen = window?.screen ?? NSScreen.main
        let backingScale = window?.backingScaleFactor ?? screen?.backingScaleFactor ?? 2
        let contentSize = window?.contentView?.bounds.size ?? CGSize(width: 1080, height: 720)
        let longestSideInPoints = max(contentSize.width, contentSize.height)
        return Int(min(max(longestSideInPoints * backingScale * 1.2, 1600), 3072))
    }

    private func applyPreview(_ frame: RenderedFrame, for url: URL, loadID: UUID) {
        guard activeLoadID == loadID, currentURL == url else { return }
        let replacesExistingFrame = !isLoadingPreview && renderedFrame?.sourceURL == url
        isLoadingPreview = false
        renderedFrame = frame
        renderRevision += 1
        image = NSImage(cgImage: frame.cgImage, size: frame.logicalPixelSize)
        pixelSize = frame.logicalPixelSize
        previewCache[url] = frame.stillPreview
        if !replacesExistingFrame {
            issue(.fit)
        }
        if pendingActualSize {
            pendingActualSize = false
            issue(.actualSize)
        }
        if wantsFullResolution {
            requestFullResolutionIfNeeded()
        } else {
            loadAnimationIfNeeded(frame, loadID: loadID)
        }
        prefetchAdjacentPreviews()
    }

    func requestFullResolutionIfNeeded() {
        wantsFullResolution = true
        guard !isLoadingPreview, let currentURL,
              let renderedFrame,
              renderedFrame.sourceURL == currentURL,
              (!renderedFrame.isFullResolution ||
               (renderedFrame.supportsAnimation && !renderedFrame.animationIsResolved)),
              fullResolutionTask == nil else { return }

        let loadID = activeLoadID
        animationTask?.cancel()
        animationTask = nil
        isLoadingFullResolution = true
        let decodeTask = Task.detached(priority: .userInitiated) {
            await Self.foregroundDecoder.decode(at: currentURL, maximumPixelSize: nil,
                                                fullResolution: true, animation: true)
        }
        fullResolutionTask = Task { [weak self] in
            let frame = await withTaskCancellationHandler {
                await decodeTask.value
            } onCancel: {
                decodeTask.cancel()
            }

            guard !Task.isCancelled, let self, self.activeLoadID == loadID else { return }
            self.fullResolutionTask = nil
            self.isLoadingFullResolution = false
            guard self.currentURL == currentURL else { return }
            guard let frame, frame.isFullResolution else {
                self.errorMessage = "Không thể tải đủ pixel gốc. Ảnh hiện tại vẫn là bản xem trước."
                return
            }

            self.renderedFrame = frame
            self.renderRevision += 1
            self.image = NSImage(cgImage: frame.cgImage, size: frame.logicalPixelSize)
            // Keep the small preview for a quick return, never cache the full bitmap.
        }
    }

    private func loadAnimationIfNeeded(_ frame: RenderedFrame, loadID: UUID) {
        guard frame.supportsAnimation, !frame.animationIsResolved, animationTask == nil else { return }
        let url = frame.sourceURL
        let maximumPixelSize = previewMaximumPixelSize
        let decodeTask = Task.detached(priority: .userInitiated) {
            await Self.foregroundDecoder.decode(at: url, maximumPixelSize: maximumPixelSize,
                                                fullResolution: false, animation: true)
        }
        animationTask = Task { [weak self] in
            let animated = await withTaskCancellationHandler {
                await decodeTask.value
            } onCancel: {
                decodeTask.cancel()
            }
            guard !Task.isCancelled, let self, self.activeLoadID == loadID else { return }
            self.animationTask = nil
            guard !self.wantsFullResolution, let animated, animated.animation != nil else { return }
            self.renderedFrame = animated
            self.renderRevision += 1
            self.image = NSImage(cgImage: animated.cgImage, size: animated.logicalPixelSize)
        }
    }

    private func prefetchAdjacentPreviews() {
        guard let currentIndex else { return }
        let adjacentIndexes = [currentIndex - 1, currentIndex + 1]
            .filter { siblingURLs.indices.contains($0) }
        let adjacentURLs = Set(adjacentIndexes.map { siblingURLs[$0] })
        let keepURLs = adjacentURLs.union(currentURL.map { [$0] } ?? [])
        previewCache = previewCache.filter { keepURLs.contains($0.key) }

        let obsoleteTaskURLs = prefetchTasks.keys.filter { !keepURLs.contains($0) }
        for url in obsoleteTaskURLs {
            prefetchTasks[url]?.cancel()
            prefetchTasks[url] = nil
        }

        let maximumPixelSize = previewMaximumPixelSize
        for url in adjacentURLs where previewCache[url] == nil && prefetchTasks[url] == nil {
            let decodeTask = Task.detached(priority: .utility) {
                await Self.prefetchDecoder.decode(at: url, maximumPixelSize: maximumPixelSize,
                                                 fullResolution: false, animation: false)
            }
            prefetchTasks[url] = Task(priority: .utility) { [weak self] in
                let frame = await withTaskCancellationHandler {
                    await decodeTask.value
                } onCancel: {
                    decodeTask.cancel()
                }

                guard !Task.isCancelled, let self else { return }
                self.prefetchTasks[url] = nil
                if let frame {
                    self.previewCache[url] = frame
                    self.trimPreviewCache()
                }
            }
        }
    }

    private func trimPreviewCache() {
        guard let currentIndex else {
            previewCache.removeAll()
            return
        }
        let keepIndexes = [currentIndex - 1, currentIndex, currentIndex + 1]
            .filter { siblingURLs.indices.contains($0) }
        let keepURLs = Set(keepIndexes.map { siblingURLs[$0] })
        previewCache = previewCache.filter { keepURLs.contains($0.key) }
    }

    nonisolated private static func decodeFrame(
        at url: URL,
        maximumPixelSize: Int?,
        isFullResolution: Bool,
        loadsAnimation: Bool
    ) -> RenderedFrame? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue.isFinite, height.doubleValue.isFinite,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue < Double(Int32.max), height.doubleValue < Double(Int32.max) else { return nil }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsDimensions = (5...8).contains(orientation)
        let rawSize = CGSize(width: width.doubleValue, height: height.doubleValue)
        let logicalSize = swapsDimensions
            ? CGSize(width: rawSize.height, height: rawSize.width)
            : rawSize
        let sourceFrameCount = CGImageSourceGetCount(source)
        let supportsAnimation = sourceFrameCount > 1 && CGImageSourceGetType(source) as String? == UTType.gif.identifier
        let requestedMaximum = maximumPixelSize ?? Int(max(rawSize.width, rawSize.height).rounded(.up))

        if supportsAnimation,
           loadsAnimation,
           let animatedFrame = decodeAnimatedGIF(
               source: source,
               url: url,
               logicalSize: logicalSize,
               rawSize: rawSize,
               sourceFrameCount: sourceFrameCount,
               requestedMaximum: requestedMaximum,
               requestsFullResolution: isFullResolution
           ) {
            return animatedFrame
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(requestedMaximum, 1),
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard !Task.isCancelled else { return nil }
        let decodedImage: CGImage?
        if orientation == 1 && requestedMaximum >= Int(max(rawSize.width, rawSize.height)) {
            // Decode the original representation, preserving bit depth and color profile.
            decodedImage = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCache: true,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        } else {
            decodedImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        guard !Task.isCancelled, let cgImage = decodedImage else { return nil }
        return RenderedFrame(
            cgImage: cgImage,
            logicalPixelSize: logicalSize,
            sourceURL: url,
            isFullResolution: cgImage.width == Int(logicalSize.width) && cgImage.height == Int(logicalSize.height),
            sourceFrameCount: sourceFrameCount,
            animation: nil,
            supportsAnimation: supportsAnimation,
            animationIsResolved: loadsAnimation
        )
    }

    nonisolated private static func decodeAnimatedGIF(
        source: CGImageSource,
        url: URL,
        logicalSize: CGSize,
        rawSize: CGSize,
        sourceFrameCount: Int,
        requestedMaximum: Int,
        requestsFullResolution: Bool
    ) -> RenderedFrame? {
        let rawLongestSide = max(rawSize.width, rawSize.height)
        let requestedScale = min(CGFloat(requestedMaximum) / max(rawLongestSide, 1), 1)
        let requestedPixelsPerFrame = rawSize.width * rawSize.height * requestedScale * requestedScale
        let animationBudgetBytes: CGFloat = requestsFullResolution
            ? 320 * 1_024 * 1_024
            : 160 * 1_024 * 1_024
        let estimatedBytes = requestedPixelsPerFrame * 4 * CGFloat(sourceFrameCount)

        // Khi full-resolution của toàn bộ animation vượt ngân sách, ưu tiên độ
        // chính xác: trả frame đầu pixel gốc và không phát bản đã giảm chất lượng.
        if requestsFullResolution, estimatedBytes > animationBudgetBytes {
            let fullOptions = thumbnailOptions(maximumPixelSize: Int(rawLongestSide.rounded(.up)))
            guard let firstFrame = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                fullOptions as CFDictionary
            ) else { return nil }
            return RenderedFrame(
                cgImage: firstFrame,
                logicalPixelSize: logicalSize,
                sourceURL: url,
                isFullResolution: true,
                sourceFrameCount: sourceFrameCount,
                animation: nil,
                supportsAnimation: true,
                animationIsResolved: true
            )
        }

        let budgetScale = min(
            sqrt(animationBudgetBytes / max(rawSize.width * rawSize.height * 4 * CGFloat(sourceFrameCount), 1)),
            1
        )
        let playbackScale = min(requestedScale, budgetScale)
        let playbackMaximum = max(Int((rawLongestSide * playbackScale).rounded(.down)), 1)
        let options = thumbnailOptions(maximumPixelSize: playbackMaximum)

        var frames: [CGImage] = []
        var durations: [TimeInterval] = []
        frames.reserveCapacity(sourceFrameCount)
        durations.reserveCapacity(sourceFrameCount)

        for index in 0..<sourceFrameCount {
            guard !Task.isCancelled,
                  let frame = CGImageSourceCreateThumbnailAtIndex(
                      source,
                      index,
                      options as CFDictionary
                  ) else { return nil }
            frames.append(frame)
            durations.append(gifFrameDuration(source: source, index: index))
        }

        guard let firstFrame = frames.first else { return nil }
        let playbackIsFullResolution = playbackMaximum >= Int(rawLongestSide.rounded(.up))
        return RenderedFrame(
            cgImage: firstFrame,
            logicalPixelSize: logicalSize,
            sourceURL: url,
            isFullResolution: playbackIsFullResolution,
            sourceFrameCount: sourceFrameCount,
            animation: AnimatedPlayback(
                frames: frames,
                frameDurations: durations,
                loopCount: gifLoopCount(source: source),
                isFullResolution: playbackIsFullResolution
            ),
            supportsAnimation: true,
            animationIsResolved: true
        )
    }

    nonisolated private static func thumbnailOptions(maximumPixelSize: Int) -> [CFString: Any] {
        [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maximumPixelSize, 1),
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
    }

    nonisolated private static func gifFrameDuration(
        source: CGImageSource,
        index: Int
    ) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 0.1
        }
        let unclamped = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
        let clamped = (gif[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
        let duration = unclamped ?? clamped ?? 0.1
        return duration.isFinite ? max(duration, 0.02) : 0.1
    }

    nonisolated private static func gifLoopCount(source: CGImageSource) -> Int {
        guard let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
              let loopCount = gif[kCGImagePropertyGIFLoopCount] as? NSNumber else {
            return 0
        }
        return max(loopCount.intValue, 0)
    }

    private struct ImageMetadata: Sendable {
        var pixelSize: CGSize?
        var lines: [String] = []
        var fileSizeText = ""
        var dateLines: [String] = []
    }

    private func loadMetadata(for url: URL, loadID: UUID) {
        let readTask = Task.detached(priority: .utility) {
            autoreleasepool { Self.readMetadata(for: url) }
        }
        metadataTask = Task { [weak self] in
            let metadata = await withTaskCancellationHandler {
                await readTask.value
            } onCancel: {
                readTask.cancel()
            }
            guard !Task.isCancelled, let self, self.activeLoadID == loadID else { return }
            self.metadataTask = nil
            if self.pixelSize == nil { self.pixelSize = metadata.pixelSize }
            self.imageMetadataLines = metadata.lines
            self.fileSizeText = metadata.fileSizeText
            self.fileDateLines = metadata.dateLines
        }
    }

    nonisolated private static func readMetadata(for url: URL) -> ImageMetadata {
        guard !Task.isCancelled else { return ImageMetadata() }
        var result = ImageMetadata()

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            var metadata: [String] = []

            if let sourceType = CGImageSourceGetType(source) {
                let identifier = sourceType as String
                let type = UTType(identifier)
                let typeName = type?.localizedDescription ?? url.pathExtension.uppercased()
                metadata.append("Định dạng: \(typeName)")
                metadata.append("UTI: \(identifier)")
            }

            let frameCount = CGImageSourceGetCount(source)
            if frameCount > 1 {
                metadata.append("Số khung hình: \(frameCount)")
            }

            if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                if let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                   let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                   width.doubleValue > 0, height.doubleValue > 0,
                   width.doubleValue < Double(Int32.max), height.doubleValue < Double(Int32.max) {
                    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
                    result.pixelSize = (5...8).contains(orientation)
                        ? CGSize(width: height.doubleValue, height: width.doubleValue)
                        : CGSize(width: width.doubleValue, height: height.doubleValue)
                }

                let colorModel = properties[kCGImagePropertyColorModel] as? String
                let profileName = properties[kCGImagePropertyProfileName] as? String
                let colorParts = [profileName, colorModel]
                    .compactMap { $0 }
                    .reduce(into: [String]()) { result, value in
                        if !result.contains(value) { result.append(value) }
                    }
                metadata.append("Hệ màu: \(colorParts.isEmpty ? "—" : colorParts.joined(separator: " • "))")

                let dpiWidth = properties[kCGImagePropertyDPIWidth] as? NSNumber
                let dpiHeight = properties[kCGImagePropertyDPIHeight] as? NSNumber
                if let dpiWidth, let dpiHeight {
                    metadata.append("DPI: \(formattedNumber(dpiWidth)) × \(formattedNumber(dpiHeight))")
                } else {
                    metadata.append("DPI: —")
                }

                if let depth = properties[kCGImagePropertyDepth] as? NSNumber {
                    metadata.append("Độ sâu màu: \(depth.intValue) bit/kênh")
                } else {
                    metadata.append("Độ sâu màu: —")
                }

                if let hasAlpha = properties[kCGImagePropertyHasAlpha] as? NSNumber {
                    metadata.append("Kênh alpha: \(hasAlpha.boolValue ? "Có" : "Không")")
                }

                if let orientation = properties[kCGImagePropertyOrientation] as? NSNumber {
                    metadata.append("Hướng ảnh: \(orientationDescription(orientation.intValue))")
                }

                if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                    let make = tiff[kCGImagePropertyTIFFMake] as? String
                    let model = tiff[kCGImagePropertyTIFFModel] as? String
                    let camera = [make, model].compactMap { $0 }.joined(separator: " ")
                    if !camera.isEmpty {
                        metadata.append("Máy ảnh: \(camera)")
                    }
                    if let software = tiff[kCGImagePropertyTIFFSoftware] as? String, !software.isEmpty {
                        metadata.append("Phần mềm: \(software)")
                    }
                }

                if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                    var exposureParts: [String] = []
                    if let exposure = exif[kCGImagePropertyExifExposureTime] as? NSNumber {
                        let seconds = exposure.doubleValue
                        exposureParts.append(seconds > 0 && seconds < 1
                            ? "1/\(formattedNumber(NSNumber(value: (1 / seconds).rounded()))) s"
                            : "\(formattedNumber(exposure)) s")
                    }
                    if let aperture = exif[kCGImagePropertyExifFNumber] as? NSNumber {
                        exposureParts.append("ƒ/\(formattedNumber(aperture))")
                    }
                    if let isoValues = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber],
                       let iso = isoValues.first {
                        exposureParts.append("ISO \(iso.intValue)")
                    }
                    if let focalLength = exif[kCGImagePropertyExifFocalLength] as? NSNumber {
                        exposureParts.append("\(formattedNumber(focalLength)) mm")
                    }
                    if !exposureParts.isEmpty {
                        metadata.append("Phơi sáng: \(exposureParts.joined(separator: " • "))")
                    }
                    if let lens = exif[kCGImagePropertyExifLensModel] as? String, !lens.isEmpty {
                        metadata.append("Ống kính: \(lens)")
                    }
                    if let captured = exif[kCGImagePropertyExifDateTimeOriginal] as? String, !captured.isEmpty {
                        metadata.append("Ngày chụp: \(captured)")
                    }
                }
            }
            result.lines = metadata
        }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        let byteCount = values?.fileSize ?? 0
        result.fileSizeText = byteCount > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
            : ""
        result.dateLines = [
            "Ngày tạo: \(values?.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "—")",
            "Sửa đổi: \(values?.contentModificationDate?.formatted(date: .abbreviated, time: .shortened) ?? "—")"
        ]
        return result
    }

    nonisolated private static func formattedNumber(_ number: NSNumber) -> String {
        let value = number.doubleValue
        guard value.isFinite else { return "—" }
        if abs(value.rounded() - value) < 0.001, value > Double(Int.min), value < Double(Int.max) {
            return String(Int(value.rounded()))
        }
        return String(format: "%.1f", value)
    }

    nonisolated private static func orientationDescription(_ orientation: Int) -> String {
        switch orientation {
        case 1: "Chuẩn"
        case 2: "Lật ngang"
        case 3: "Xoay 180°"
        case 4: "Lật dọc"
        case 5: "Lật ngang, xoay 90°"
        case 6: "Xoay 90° phải"
        case 7: "Lật ngang, xoay 90° trái"
        case 8: "Xoay 90° trái"
        default: "Không xác định (\(orientation))"
        }
    }

    private func refreshSiblingImages(around url: URL, forceRefresh: Bool) {
        let directory = url.deletingLastPathComponent()
        if !forceRefresh, siblingDirectory == directory,
           let cachedIndex = siblingURLs.firstIndex(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            currentIndex = cachedIndex
            prefetchAdjacentPreviews()
            return
        }

        directoryTask?.cancel()
        siblingDirectory = directory
        siblingURLs = [url]
        currentIndex = 0
        prefetchAdjacentPreviews()
        let scanTask = Task.detached(priority: .utility) {
            Self.scanSiblingImages(around: url)
        }
        directoryTask = Task { [weak self] in
            let urls = await withTaskCancellationHandler {
                await scanTask.value
            } onCancel: {
                scanTask.cancel()
            }
            guard !Task.isCancelled, let self, self.siblingDirectory == directory,
                  let current = self.currentURL else { return }
            self.directoryTask = nil
            var siblings = urls
            if !siblings.contains(current) { siblings.append(current) }
            self.siblingURLs = siblings
            self.currentIndex = siblings.firstIndex(of: current)
            self.prefetchAdjacentPreviews()
        }
    }

    nonisolated private static func scanSiblingImages(around url: URL) -> [URL] {
        guard !Task.isCancelled else { return [] }
        let directory = url.deletingLastPathComponent()
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        let imageExtensions: Set<String> = [
            "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff",
            "bmp", "webp", "avif", "jp2", "icns"
        ]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? [url]

        var siblings: [URL] = []
        for candidate in urls {
            guard !Task.isCancelled else { return [] }
            guard let values = try? candidate.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                continue
            }
            // Common image types do not need a Launch Services metadata lookup
            // for every sibling. This also works when that service is unavailable.
            let isImage = imageExtensions.contains(candidate.pathExtension.lowercased()) ||
                UTType(filenameExtension: candidate.pathExtension)?.conforms(to: .image) == true
            if isImage { siblings.append(candidate.standardizedFileURL) }
        }
        if !siblings.contains(url) { siblings.append(url) }
        return siblings.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

    }
}

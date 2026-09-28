import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LookAt

@Suite(.serialized)
@MainActor
struct StabilityTests {
    private static let fixtures = try! ImageFixtures()

    init() { _ = NSApplication.shared }

    @Test func fullResolutionPreservesOriginalPixelsAndPendingActualSize() async throws {
        _ = NSApplication.shared
        let url = Self.fixtures.largePNG
        let model = AppModel.shared
        let started = ContinuousClock.now
        model.open(url)
        #expect(model.isLoadingPreview)
        model.actualSize() // Request 1:1 before a preview exists.
        try await waitUntil { model.renderedFrame?.sourceURL == url && model.renderedFrame?.isFullResolution == true }
        let frame = try #require(model.renderedFrame)
        #expect(frame.cgImage.width == 11_584)
        #expect(frame.cgImage.height == 8_688)
        #expect(model.canvasCommand.action == .actualSize)
        #expect(!model.isLoadingFullResolution)
        try verifyOriginalPixels(frame.cgImage, at: url)
        print("11,584 × 8,688: original raster and pixel samples verified in \(started.duration(to: .now))")
    }

    @Test func previewUpgradesOnZoomAndDoesNotRegress() async throws {
        let model = AppModel.shared
        let url = Self.fixtures.largePNG
        model.open(url)
        try await waitUntil { !model.isLoadingPreview && model.renderedFrame?.sourceURL == url }
        #expect(try #require(model.renderedFrame).cgImage.width <= 3072)
        model.canvasDidChangeZoom(111)
        try await waitUntil { model.renderedFrame?.isFullResolution == true }
        let revision = model.renderRevision
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.renderedFrame?.cgImage.width == 11_584)
        #expect(model.renderRevision == revision)
    }

    @Test func rapidNavigationCancelsStaleResultsAndRecoversFromInvalidFiles() async throws {
        let model = AppModel.shared
        for index in 0..<40 {
            model.open(index.isMultiple(of: 2) ? Self.fixtures.largePNG : Self.fixtures.smallPNG)
            if index.isMultiple(of: 2) { model.actualSize() }
            await Task.yield()
        }
        let finalURL = Self.fixtures.smallPNG
        model.open(finalURL)
        try await waitUntil { !model.isLoadingPreview && model.renderedFrame?.sourceURL == finalURL }
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.currentURL == finalURL)
        #expect(model.renderedFrame?.cgImage.width == 320)
        #expect(model.pixelSize == CGSize(width: 320, height: 200))
        #expect(!model.isLoadingFullResolution)

        model.open(Self.fixtures.invalidPNG)
        try await waitUntil { model.errorMessage != nil }
        #expect(model.image == nil)
        #expect(model.renderedFrame == nil)
        #expect(!model.isLoadingPreview)
        model.open(finalURL)
        try await waitUntil { model.image != nil && !model.isLoadingPreview }
        #expect(model.errorMessage == nil)
        #expect(model.renderedFrame?.sourceURL == finalURL)
    }

    @Test func gifPlaysAfterPrefetchAndFullResolutionWins() async throws {
        let model = AppModel.shared
        let url = Self.fixtures.gif
        // Let adjacent prefetch finish, then open the prefetched first frame.
        model.open(Self.fixtures.smallPNG)
        try await waitUntil { !model.isLoadingPreview && model.siblingURLs.contains(url) }
        try await Task.sleep(for: .milliseconds(100))
        model.open(url, reusesPreview: true)
        model.actualSize()
        try await waitUntil { model.renderedFrame?.sourceURL == url && model.renderedFrame?.animation != nil }
        let frame = try #require(model.renderedFrame)
        let animation = try #require(frame.animation)
        #expect(animation.frames.count == 3)
        #expect(abs(animation.frameDurations.reduce(0, +) - 0.4) < 0.001)
        #expect(animation.loopCount == 0)
        #expect(frame.isFullResolution)
        #expect(frame.animationIsResolved)
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.renderedFrame?.isFullResolution == true)
    }

    @Test func orientationAndSixteenBitColorArePreserved() async throws {
        let model = AppModel.shared
        model.open(Self.fixtures.rotatedJPEG)
        model.actualSize()
        try await waitUntil { model.renderedFrame?.sourceURL == Self.fixtures.rotatedJPEG && model.renderedFrame?.isFullResolution == true }
        #expect(model.renderedFrame?.cgImage.width == 160)
        #expect(model.renderedFrame?.cgImage.height == 320)
        #expect(model.pixelSize == CGSize(width: 160, height: 320))

        model.open(Self.fixtures.sixteenBitPNG)
        model.actualSize()
        try await waitUntil { model.renderedFrame?.sourceURL == Self.fixtures.sixteenBitPNG && model.renderedFrame?.isFullResolution == true }
        let frame = try #require(model.renderedFrame)
        #expect(frame.cgImage.bitsPerComponent == 16)
        try verifyOriginalPixels(frame.cgImage, at: Self.fixtures.sixteenBitPNG)
    }

    @Test func largeGIFFullResolutionReplacesAnimationWithoutLaterDowngrade() async throws {
        let model = AppModel.shared
        let url = try Self.fixtures.makeLargeGIF()
        model.open(url)
        try await waitUntil { model.renderedFrame?.sourceURL == url && !model.isLoadingPreview }
        #expect(model.renderedFrame?.isFullResolution == false)
        model.actualSize()
        try await waitUntil { model.renderedFrame?.isFullResolution == true && !model.isLoadingFullResolution }
        // Eight uncompressed frames exceed the 320 MiB budget. 1:1 must show
        // the original first frame rather than an upscaled playback preview.
        #expect(model.renderedFrame?.cgImage.width == 4000)
        #expect(model.renderedFrame?.cgImage.height == 3000)
        #expect(model.renderedFrame?.animation == nil)
        #expect(model.renderedFrame?.animationIsResolved == true)
        let revision = model.renderRevision
        try await Task.sleep(for: .milliseconds(200))
        model.canvasDidChangeZoom(150)
        #expect(!model.isLoadingFullResolution)
        #expect(model.renderRevision == revision)
    }

    @Test func reopeningAnEditedFileDoesNotReuseOldPixels() async throws {
        let model = AppModel.shared
        let url = Self.fixtures.directory.appendingPathComponent("edited.png")
        try FileManager.default.copyItem(at: Self.fixtures.smallPNG, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        model.open(url)
        try await waitUntil { model.renderedFrame?.sourceURL == url && !model.isLoadingPreview }
        #expect(model.renderedFrame?.cgImage.width == 320)
        try Data(contentsOf: Self.fixtures.sixteenBitPNG).write(to: url, options: .atomic)
        model.open(url)
        model.actualSize()
        try await waitUntil { !model.isLoadingPreview && !model.isLoadingFullResolution && model.renderedFrame?.cgImage.width == 3400 }
        #expect(model.renderedFrame?.cgImage.bitsPerComponent == 16)
    }

    @Test func retinaDoubleClickPixelScalePanLimitsAndZoomUpdates() async throws {
        _ = NSApplication.shared
        let view = ZoomableImageView(frame: NSRect(x: 0, y: 0, width: 1080, height: 720))
        let source = try #require(CGImageSourceCreateWithURL(Self.fixtures.smallPNG as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var zoomReports: [Int] = []
        var fullRequests = 0
        view.onZoomChanged = { percent, _ in zoomReports.append(percent) }
        view.onNeedsFullResolution = { _ in fullRequests += 1 }
        view.setImage(image, logicalPixelSize: CGSize(width: 320, height: 200),
                      sourceURL: Self.fixtures.smallPNG, isFullResolution: true, animation: nil, resetsViewport: true)
        let layer = try #require(view.layer?.sublayers?.first)
        let fittedScale = layer.affineTransform().a
        let doubleClick = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 500, y: 300),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        view.mouseDown(with: doubleClick)
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        #expect(abs(layer.affineTransform().a * backing - 1) < 0.00001)
        #expect(layer.magnificationFilter == .nearest)
        view.mouseDown(with: doubleClick)
        #expect(abs(layer.affineTransform().a - fittedScale) < 0.00001)
        #expect(zoomReports.isEmpty) // No synchronous publication during view updates.
        try await Task.sleep(for: .milliseconds(50))
        #expect(fullRequests == 1)
        #expect(zoomReports.last == 100)

        view.zoom(by: 0.00001)
        #expect(abs(layer.affineTransform().a / fittedScale - 0.7) < 0.00001)
        view.fitToWindow()
        let mouseDown = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 500, y: 300),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: CGPoint(x: 9000, y: 9000),
            modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        view.mouseDown(with: mouseDown)
        view.mouseDragged(with: drag)
        view.mouseUp(with: drag)
        let viewport = CGRect(x: 0, y: 0, width: 1080, height: 668)
        let intersection = layer.frame.intersection(viewport)
        let capacity = min(layer.frame.width, viewport.width) * min(layer.frame.height, viewport.height)
        #expect(intersection.width * intersection.height >= capacity * 0.499)
        #expect(!view.mouseDownCanMoveWindow)

        let start = ContinuousClock.now
        for index in 0..<2000 { view.zoom(by: index.isMultiple(of: 2) ? 1.001 : 1 / 1.001) }
        print("2,000 canvas geometry updates: \(start.duration(to: .now)) (CPU only, not a display FPS measurement)")
        view.clearImage()
        #expect(layer.contents == nil)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                let model = AppModel.shared
                Issue.record("Timed out: current=\(model.displayName), loading=\(model.isLoadingPreview), fullLoading=\(model.isLoadingFullResolution), raster=\(model.renderedFrame?.cgImage.width ?? 0), animation=\(model.renderedFrame?.animation?.frames.count ?? 0), siblings=\(model.siblingURLs.map(\.lastPathComponent)), error=\(model.errorMessage ?? "none")")
                throw VerificationError.timeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func verifyOriginalPixels(_ actual: CGImage, at url: URL) throws {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let expected = try #require(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
        #expect(actual.width == expected.width && actual.height == expected.height)
        #expect(actual.bitsPerComponent == expected.bitsPerComponent)
        #expect(actual.colorSpace?.name == expected.colorSpace?.name)
        let actualData = try #require(actual.dataProvider?.data)
        let expectedData = try #require(expected.dataProvider?.data)
        let actualBytes = try #require(CFDataGetBytePtr(actualData))
        let expectedBytes = try #require(CFDataGetBytePtr(expectedData))
        #expect(actual.bitsPerPixel == expected.bitsPerPixel)
        let pixelBytes = actual.bitsPerPixel / 8
        for (x, y) in [(0, 0), (actual.width / 3, actual.height / 3), (actual.width / 2, actual.height / 2), (actual.width - 1, actual.height - 1)] {
            for byte in 0..<pixelBytes {
                #expect(actualBytes[y * actual.bytesPerRow + x * pixelBytes + byte] == expectedBytes[y * expected.bytesPerRow + x * pixelBytes + byte])
            }
        }
    }
}

private enum VerificationError: Error { case timeout, fixture }

private final class ImageFixtures {
    let directory: URL
    let largePNG: URL
    let smallPNG: URL
    let invalidPNG: URL
    let gif: URL
    let rotatedJPEG: URL
    let sixteenBitPNG: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LookAt-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        largePNG = directory.appendingPathComponent("01-large.png")
        smallPNG = directory.appendingPathComponent("02-small.png")
        gif = directory.appendingPathComponent("03-animation.gif")
        rotatedJPEG = directory.appendingPathComponent("04-oriented.jpg")
        sixteenBitPNG = directory.appendingPathComponent("05-sixteen-bit.png")
        invalidPNG = directory.appendingPathComponent("06-invalid.png")
        try autoreleasepool { try Self.makeImage(at: largePNG, width: 11_584, height: 8_688) }
        try Self.makeImage(at: smallPNG, width: 320, height: 200)
        try Self.makeImage(at: rotatedJPEG, width: 320, height: 160, type: .jpeg, orientation: 6)
        try Self.makeImage(at: sixteenBitPNG, width: 3400, height: 64, bits: 16)
        try Data("This is deliberately not an image".utf8).write(to: invalidPNG)
        guard let destination = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 3, nil) else { throw VerificationError.fixture }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (index, duration) in [0.08, 0.12, 0.2].enumerated() {
            let image = try Self.bitmap(width: 96, height: 64, bits: 8, color: CGFloat(index) / 3)
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: duration]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw VerificationError.fixture }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func makeLargeGIF() throws -> URL {
        let url = directory.appendingPathComponent("large-animation.gif")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 8, nil) else { throw VerificationError.fixture }
        for index in 0..<8 {
            try autoreleasepool {
                let frame = try Self.bitmap(width: 4000, height: 3000, bits: 8, color: CGFloat(index) / 8)
                CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 0.1]] as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw VerificationError.fixture }
        return url
    }

    private static func bitmap(width: Int, height: Int, bits: Int, color: CGFloat = 0.3) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: bits,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw VerificationError.fixture }
        context.setFillColor(red: color, green: 0.71, blue: 0.24, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.8, green: 0.13, blue: 0.98, alpha: 1)
        context.fill(CGRect(x: width / 2, y: height / 2, width: width / 2, height: height / 2))
        guard let image = context.makeImage() else { throw VerificationError.fixture }
        return image
    }

    private static func makeImage(at url: URL, width: Int, height: Int, bits: Int = 8, type: UTType = .png, orientation: Int = 1) throws {
        let image = try bitmap(width: width, height: height, bits: bits)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw VerificationError.fixture }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw VerificationError.fixture }
    }
}

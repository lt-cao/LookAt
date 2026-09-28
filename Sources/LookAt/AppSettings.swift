import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var zoomSensitivity: Double {
        didSet {
            UserDefaults.standard.set(zoomSensitivity, forKey: "zoomSensitivity")
        }
    }

    @Published var invertsScrollZoom: Bool {
        didSet {
            UserDefaults.standard.set(invertsScrollZoom, forKey: "invertsScrollZoom")
        }
    }

    @Published private(set) var isSettingDefaultViewer = false
    @Published private(set) var defaultViewerStatus: String?

    private init() {
        let defaults = UserDefaults.standard
        let savedSensitivity = defaults.object(forKey: "zoomSensitivity") as? Double
        let initialSensitivity = savedSensitivity.flatMap { $0.isFinite ? $0 : nil } ?? 1
        zoomSensitivity = min(max(initialSensitivity, 0.5), 2)
        invertsScrollZoom = defaults.bool(forKey: "invertsScrollZoom")
        refreshDefaultViewerStatus()
    }

    func setLookAtAsDefaultViewer() {
        guard !isSettingDefaultViewer else { return }
        isSettingDefaultViewer = true
        defaultViewerStatus = "Đang cập nhật ứng dụng mặc định…"

        let appURL = Bundle.main.bundleURL
        let supportedTypes: [UTType] = [
            .jpeg, .png, .heic, .heif, .gif, .tiff, .bmp, .webP, .icns
        ]

        Task { [weak self] in
            var failedCount = 0
            for contentType in supportedTypes {
                let succeeded: Bool = await withCheckedContinuation { continuation in
                    NSWorkspace.shared.setDefaultApplication(
                        at: appURL,
                        toOpen: contentType
                    ) { error in
                        continuation.resume(returning: error == nil)
                    }
                }
                if !succeeded {
                    failedCount += 1
                }
            }

            guard let self else { return }
            self.isSettingDefaultViewer = false
            self.defaultViewerStatus = failedCount == 0
                ? "LookAt đang là ứng dụng mặc định cho các định dạng ảnh phổ biến."
                : "Không thể đổi \(failedCount) định dạng. Bạn có thể dùng Get Info → Open with → Change All…"
        }
    }

    func refreshDefaultViewerStatus() {
        let defaultPNGApp = NSWorkspace.shared.urlForApplication(toOpen: .png)
        let lookAtBundleID = Bundle.main.bundleIdentifier
        let defaultBundleID = defaultPNGApp.flatMap { Bundle(url: $0)?.bundleIdentifier }
        defaultViewerStatus = lookAtBundleID != nil && defaultBundleID == lookAtBundleID
            ? "PNG hiện đang mở mặc định bằng LookAt."
            : "PNG hiện chưa được đặt mở mặc định bằng LookAt."
    }
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    private init() {}

    func show() {
        if window == nil {
            let content = NSHostingController(rootView: LookAtSettingsView(settings: .shared))
            let settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 450, height: 340),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            settingsWindow.title = "Cài Đặt LookAt"
            settingsWindow.tabbingMode = .disallowed
            settingsWindow.contentViewController = content
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.center()
            window = settingsWindow
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct LookAtSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LookAt")
                        .font(.title2.weight(.semibold))
                    Text("Phiên bản \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Form {
                LabeledContent("Độ nhạy zoom") {
                    Slider(value: $settings.zoomSensitivity, in: 0.5...2, step: 0.1)
                        .frame(width: 180)
                }
                Toggle("Đảo chiều lăn để zoom", isOn: $settings.invertsScrollZoom)

                LabeledContent("Ứng dụng mặc định") {
                    Button("Đặt LookAt làm mặc định") {
                        settings.setLookAtAsDefaultViewer()
                    }
                    .disabled(settings.isSettingDefaultViewer)
                }
            }
            .formStyle(.grouped)

            if let status = settings.defaultViewerStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Ảnh tự vừa theo chiều ngang hoặc chiều dọc của cửa sổ.")
                Spacer()
                Text("Tác giả: Cao Le")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 450, height: 340)
        .onAppear(perform: settings.refreshDefaultViewerStatus)
    }
}

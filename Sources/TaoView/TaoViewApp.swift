import AppKit
import SwiftUI

@main
struct LookAtApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("LookAt", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 620, minHeight: 420)
        }
        .defaultSize(width: 1080, height: 720)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Mở ảnh…") {
                    model.showOpenPanel()
                }
                .keyboardShortcut("o")
            }

            CommandMenu("Ảnh") {
                Button("Ảnh trước") {
                    model.showPrevious()
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!model.canShowPrevious)

                Button("Ảnh tiếp theo") {
                    model.showNext()
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!model.canShowNext)

                Divider()

                Button("Phóng to") {
                    model.zoomIn()
                }
                .keyboardShortcut("+")

                Button("Thu nhỏ") {
                    model.zoomOut()
                }
                .keyboardShortcut("-")

                Button("Vừa cửa sổ") {
                    model.fitToWindow()
                }
                .keyboardShortcut("0")

                Button("Kích thước thật") {
                    model.actualSize()
                }
                .keyboardShortcut("1")

                Divider()

                Button("Xoay trái") {
                    model.rotateLeft()
                }
                .keyboardShortcut("[")

                Button("Xoay phải") {
                    model.rotateRight()
                }
                .keyboardShortcut("]")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppModel.shared.openCommandLineImageIfNeeded()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let firstImage = urls.first else { return }
        AppModel.shared.open(firstImage)
        application.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

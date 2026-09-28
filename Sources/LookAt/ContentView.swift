import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @StateObject private var settings = AppSettings.shared
    @State private var canRevealEmptyState = false

    var body: some View {
        ZStack {
            background

            if model.image != nil {
                ImageCanvas(model: model, settings: settings)
                    .ignoresSafeArea()
            } else if model.isLoadingPreview {
                LoadingState(fileName: model.displayName)
            } else if canRevealEmptyState {
                EmptyState(model: model)
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
            }
            .ignoresSafeArea(edges: .top)
        }
        .overlay(alignment: .top) {
            WindowAccessor()
                .frame(width: 0, height: 0)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let firstURL = urls.first else { return false }
            model.open(firstURL)
            return true
        }
        .alert("Không mở được ảnh", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { isPresented in
                if !isPresented { model.dismissError() }
            }
        )) {
            Button("OK", action: model.dismissError)
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task {
            guard !canRevealEmptyState else { return }
            try? await Task.sleep(for: .milliseconds(300))
            canRevealEmptyState = true
        }
        .preferredColorScheme(.dark)
    }

    private var background: some View {
        Color(.displayP3, red: 34 / 255, green: 37 / 255, blue: 36 / 255)
            .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Spacer()
                .frame(width: 64)

            if model.image != nil {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 4) {
                        ControlButton(
                            systemName: "chevron.left",
                            help: "Ảnh trước (←)",
                            disabled: !model.canShowPrevious,
                            action: model.showPrevious
                        )
                        ControlButton(
                            systemName: "chevron.right",
                            help: "Ảnh tiếp theo (→)",
                            disabled: !model.canShowNext,
                            action: model.showNext
                        )
                    }
                    .padding(5)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
            }

            fileIdentity

            Spacer(minLength: 16)

            if model.image != nil {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 2) {
                        ControlButton(systemName: "rotate.left", help: "Xoay trái ([)", action: model.rotateLeft)
                        ControlButton(systemName: "rotate.right", help: "Xoay phải (])", action: model.rotateRight)

                        Divider()
                            .frame(height: 20)
                            .padding(.horizontal, 4)

                        ControlButton(systemName: "minus", help: "Thu nhỏ (⌘−)", action: model.zoomOut)

                        Button(action: model.fitToWindow) {
                            Text("\(model.zoomPercent)%")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .frame(minWidth: 48)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Vừa cửa sổ (⌘0)")

                        ControlButton(systemName: "plus", help: "Phóng to (⌘+)", action: model.zoomIn)
                        ControlButton(systemName: "arrow.up.left.and.arrow.down.right", help: "1:1 pixel thật, dùng ảnh full-resolution (⌘1)", action: model.actualSize)

                        Divider()
                            .frame(height: 20)
                            .padding(.horizontal, 4)

                        ControlButton(systemName: "folder", help: "Mở ảnh (⌘O)", action: model.showOpenPanel)
                    }
                    .padding(5)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(WindowDragArea())
    }

    private var fileIdentity: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(model.displayName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.displayName)
            if !model.imageDetails.isEmpty {
                Text(model.isLoadingFullResolution ? "Đang tải pixel gốc…" : model.imageDetails)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
    }

}

private struct LoadingState: View {
    let fileName: String

    var body: some View {
        VStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
            Text("Đang mở \(fileName)")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 320)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Đang mở ảnh")
    }
}

private struct ControlButton: View {
    let systemName: String
    let help: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 29, height: 29)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}

private struct EmptyState: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GlassEffectContainer(spacing: 18) {
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.14))
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 38, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 82, height: 82)

                VStack(spacing: 6) {
                    Text("Mở một bức ảnh")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("Kéo ảnh vào đây hoặc chọn từ Finder")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Button("Chọn ảnh…", action: model.showOpenPanel)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 38)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
        }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> AccessorView {
        AccessorView()
    }

    func updateNSView(_ nsView: AccessorView, context: Context) {}

    final class AccessorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.tabbingMode = .disallowed
            window.tabbingIdentifier = ""
            window.isMovableByWindowBackground = false
            window.backgroundColor = NSColor(
                displayP3Red: 34 / 255,
                green: 37 / 255,
                blue: 36 / 255,
                alpha: 1
            )
            window.minSize = NSSize(width: 620, height: 420)
        }
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DraggableView {
        DraggableView()
    }

    func updateNSView(_ nsView: DraggableView, context: Context) {}

    final class DraggableView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
                return
            }
            window?.performDrag(with: event)
        }
    }
}

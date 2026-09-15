import AppKit
import Carbon
import SwiftUI

struct SettingsView<ShortcutContent: View>: View {
    @ObservedObject var store: SettingsStore
    @ViewBuilder let shortcutContent: () -> ShortcutContent

    var body: some View {
        TabView {
            Form {
                Toggle("登录时启动", isOn: $store.launchAtLogin)
                Toggle("截图完成时播放声音", isOn: $store.playCaptureSound)
                Toggle("截图完成时显示通知", isOn: $store.showCompletionNotification)
                if let error = store.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(20)
            .tabItem { Label("通用", systemImage: "gearshape") }

            Form {
                Picker("截图后的默认操作", selection: $store.completionAction) {
                    ForEach(CaptureCompletionAction.allCases, id: \.self) { action in
                        Text(displayName(for: action)).tag(action)
                    }
                }
                Toggle("全屏截图包含鼠标指针", isOn: $store.includeCursor)
                Toggle("窗口截图包含阴影", isOn: $store.includeWindowShadow)
                Toggle("显示像素放大镜", isOn: $store.showMagnifier)
            }
            .padding(20)
            .tabItem { Label("截图", systemImage: "camera.viewfinder") }

            Form {
                Picker("图片格式", selection: $store.imageFormat) {
                    ForEach(ScreenshotImageFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                if store.imageFormat == .jpeg {
                    HStack {
                        Text("JPEG 质量")
                        Slider(value: $store.jpegQuality, in: 0.1...1.0)
                        Text(store.jpegQuality, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            .padding(20)
            .tabItem { Label("保存", systemImage: "square.and.arrow.down") }

            Form {
                shortcutContent()
            }
            .padding(20)
            .tabItem { Label("快捷键", systemImage: "keyboard") }

            Form {
                HStack {
                    Text("默认透明度")
                    Slider(value: $store.pinOpacity, in: 0.2...1.0)
                    Text(store.pinOpacity, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .padding(20)
            .tabItem { Label("贴图", systemImage: "pin") }
        }
        .frame(width: 560, height: 360)
    }

    private func displayName(for action: CaptureCompletionAction) -> String {
        switch action {
        case .copy: "复制到剪贴板"
        case .save: "保存到文件"
        case .annotate: "打开标注"
        case .pin: "贴到桌面"
        }
    }
}

struct ShortcutSettingsContent: View {
    @ObservedObject var store: ShortcutStore
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("点击快捷键按钮，再直接按下想使用的组合键")
                .font(.caption)
                .foregroundStyle(.secondary)
            ShortcutRecorderRow(title: "开始截图", configuration: $store.interactiveCapture, onChange: onChange)
            ShortcutRecorderRow(title: "全屏截图", configuration: $store.displayCapture, onChange: onChange)
        }
    }
}

private struct ShortcutRecorderRow: View {
    let title: String
    @Binding var configuration: ShortcutConfiguration
    let onChange: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            ShortcutRecorder(configuration: $configuration, onChange: onChange)
                .frame(width: 150, height: 28)
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var configuration: ShortcutConfiguration
    let onChange: () -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.onRecord = { newConfiguration in
            configuration = newConfiguration
            onChange()
        }
        button.update(configuration: configuration)
        return button
    }

    func updateNSView(_ nsView: ShortcutRecorderButton, context: Context) {
        nsView.onRecord = { newConfiguration in
            configuration = newConfiguration
            onChange()
        }
        nsView.update(configuration: configuration)
    }
}

private final class ShortcutRecorderButton: NSButton {
    var onRecord: ((ShortcutConfiguration) -> Void)?
    private var currentConfiguration: ShortcutConfiguration?
    private var isRecording = false

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    func update(configuration: ShortcutConfiguration) {
        currentConfiguration = configuration
        if !isRecording { title = configuration.displayName }
    }

    @objc private func beginRecording() {
        isRecording = true
        title = "按下组合键…"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == UInt16(kVK_Escape) {
            cancelRecording()
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }

        guard modifiers != 0 else {
            NSSound.beep()
            return
        }

        let configuration = ShortcutConfiguration(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        currentConfiguration = configuration
        title = configuration.displayName
        isRecording = false
        onRecord?(configuration)
        window?.makeFirstResponder(nil)
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { cancelRecording() }
        return super.resignFirstResponder()
    }

    private func cancelRecording() {
        isRecording = false
        title = currentConfiguration?.displayName ?? "设置快捷键"
    }
}

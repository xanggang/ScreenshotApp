import SwiftUI

struct ScreenCapturePermissionView: View {
    @ObservedObject var permissionService: ScreenCapturePermissionService
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: permissionService.status == .authorized ? "checkmark.shield.fill" : "rectangle.inset.filled")
                .font(.system(size: 48))
                .foregroundStyle(permissionService.status == .authorized ? Color.green : Color.accentColor)

            VStack(spacing: 8) {
                Text("允许屏幕截图")
                    .font(.title2.bold())
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 380)
            }

            HStack {
                if permissionService.status == .authorized {
                    Button("继续", action: onContinue)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("打开系统设置") {
                        if permissionService.status == .notDetermined {
                            _ = permissionService.requestAccess()
                        }
                        if permissionService.status != .authorized {
                            permissionService.openSystemSettings()
                        }
                    }
                    .keyboardShortcut(.defaultAction)

                    Button("重新检查") {
                        _ = permissionService.refresh()
                    }
                }
            }
        }
        .padding(32)
        .frame(minWidth: 480, minHeight: 280)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            _ = permissionService.refresh()
        }
    }

    private var message: String {
        switch permissionService.status {
        case .authorized:
            return "屏幕录制权限已开启，可以开始截图。"
        case .notDetermined:
            return "macOS 需要屏幕录制权限才能读取屏幕内容。应用不会录制或上传你的屏幕。"
        case .denied:
            return "请在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中允许此应用，然后返回并重新检查。"
        }
    }
}

# 轻量级 macOS 截图工具开发路线

## 1. 文档目标

本文档用于指导多个 AI 进程并行开发一款轻量级 macOS 截图工具。所有开发任务应以本文档定义的产品范围、技术栈、模块边界和验收标准为准。

核心用户流程：

```text
按下快捷键 → 选择区域、窗口或屏幕 → 简单标注 → 复制、保存或贴图
```

产品目标：

- 启动快、占用低、交互跟手。
- 使用原生 macOS 能力，不引入 Web 运行时。
- 首版只覆盖高频截图工作流。
- 模块之间通过清晰的数据结构和协议协作，便于多个 AI 并行实现。

## 2. 首版产品范围

### 2.1 必须实现

1. 菜单栏常驻应用。
2. 全局快捷键。
3. 屏幕捕获权限检测与授权引导。
4. 区域截图。
5. 智能窗口识别与窗口截图。
6. 当前或指定单个显示器的全屏截图。
7. 选区尺寸显示和像素放大镜。
8. 矩形、箭头、文字、画笔、马赛克和裁剪标注。
9. 撤销和重做。
10. 复制截图到剪贴板。
11. 保存为 PNG 或 JPEG。
12. 基础贴图：置顶、移动、缩放、透明度、复制、保存、关闭。
13. 快捷键、保存目录、图片格式和默认动作设置。
14. Retina 显示器与多显示器环境适配。

### 2.2 明确不做

- 延时截图。
- 上一次区域截图。
- 多窗口截图。
- 一次截取所有显示器。
- 多显示器画面合成。
- 滚动长截图。
- OCR 和截图翻译。
- 录屏、录音和 GIF。
- 最近截图历史。
- 将本地图片拖入并创建贴图。
- 应用退出后恢复贴图。
- 拖拽截图到其他应用。
- 系统分享与云端分享。
- 截图背景美化和设备外壳。
- 图片数据库、云同步及账号系统。

## 3. 技术路线

### 3.1 基础技术栈

- 语言：Swift 6。
- IDE 与构建：Xcode。
- 最低支持系统：macOS 14 Sonoma。
- 应用核心界面：AppKit。
- 设置和引导界面：SwiftUI，通过 `NSHostingController` 与 AppKit 混合。
- 屏幕捕获：ScreenCaptureKit。
- 窗口信息补充：Core Graphics。
- 标注和图像合成：Core Graphics。
- 图片编码：ImageIO 与 Uniform Type Identifiers。
- 贴图窗口：`NSPanel`。
- 剪贴板：`NSPasteboard`。
- 文件选择与保存：`NSSavePanel`、`FileManager`。
- 配置存储：`UserDefaults`。
- 并发：Swift Concurrency。
- 日志：OSLog。
- 测试：Swift Testing 或 XCTest。
- 开机启动：ServiceManagement 的 `SMAppService`。

### 3.2 外部依赖

首版最多保留一个第三方依赖：

- `KeyboardShortcuts`：全局快捷键注册、录制和配置。

通过 Swift Package Manager 添加：

```text
https://github.com/sindresorhus/KeyboardShortcuts
```

如果团队决定完全零依赖，可以改用 Carbon Hot Key API，但必须自行完成快捷键录制、冲突检查和配置持久化。两种方案只能选择一种，禁止并行实现后同时保留。

### 3.3 不采用的技术

- Electron、Tauri、Flutter、React Native。
- CocoaPods 和 Carthage。
- OpenCV、Metal 或大型图像编辑框架。
- Core Data、SwiftData、SQLite。
- RxSwift 和大型依赖注入框架。
- XPC 后台服务。

## 4. 总体架构

采用轻量的 Coordinator + Service + Model 结构，不引入大型 Clean Architecture。

```text
AppCoordinator
├── StatusBarController
├── ShortcutService
├── PermissionService
├── CaptureCoordinator
│   ├── ScreenCaptureService
│   ├── WindowDiscoveryService
│   ├── CoordinateConverter
│   └── OverlayController
├── AnnotationEditorController
├── ExportService
├── PinWindowManager
└── SettingsStore
```

推荐目录：

```text
ScreenshotApp/
├── App/
├── Capture/
├── Overlay/
├── Annotation/
├── Pin/
├── Export/
├── Settings/
├── Permissions/
├── Shared/
└── Resources/
ScreenshotAppTests/
```

## 5. 公共数据模型与接口约定

负责工程骨架的 AI 应先建立这些类型，其他进程基于它们开发。未经协调不要重复定义同义类型。

### 5.1 截图模式

```swift
enum CaptureMode: Sendable {
    case interactive
    case display
}
```

`interactive` 同时支持自由框选和智能窗口选择。不要为区域和窗口注册两套完全独立的入口。

### 5.2 截图目标

```swift
enum CaptureTarget: Sendable {
    case region(displayID: CGDirectDisplayID, rectInDisplay: CGRect)
    case window(windowID: CGWindowID)
    case display(displayID: CGDirectDisplayID)
}
```

### 5.3 截图结果

```swift
struct CaptureResult: @unchecked Sendable {
    let image: CGImage
    let target: CaptureTarget
    let scale: CGFloat
    let capturedAt: Date
}
```

如果严格并发检查对 `CGImage` 产生告警，应将所有图像操作隔离到专用 actor 或主线程，而不是在各模块散落 `@unchecked Sendable`。

### 5.4 截图服务

```swift
protocol ScreenCapturing {
    func availableContent() async throws -> AvailableCaptureContent
    func capture(_ target: CaptureTarget) async throws -> CaptureResult
}
```

### 5.5 截图完成动作

```swift
enum CaptureCompletionAction: String, CaseIterable, Codable {
    case copy
    case save
    case annotate
    case pin
}
```

### 5.6 标注模型

```swift
protocol Annotation: AnyObject {
    var id: UUID { get }
    var bounds: CGRect { get set }
    func draw(in context: CGContext)
    func hitTest(_ point: CGPoint) -> Bool
}
```

标注应保存为对象列表。用户编辑期间不得反复破坏性写入原始截图；只在复制、保存或贴图前执行最终合成。

### 5.7 坐标规范

所有跨模块接口必须明确坐标空间：

- `globalPoints`：AppKit 全局屏幕坐标，单位为 point。
- `displayPoints`：单显示器本地坐标，单位为 point。
- `imagePixels`：图像坐标，原点在左上角，单位为 pixel。

禁止传递没有命名坐标空间的裸 `CGRect`。内部转换统一通过 `CoordinateConverter` 完成。

## 6. 并行工作包

每个 AI 进程领取一个工作包。一个进程应尽量只修改自己的目录；公共协议变更必须先同步。

### WP-00：工程骨架与公共接口

职责：

- 创建 macOS 应用工程和测试 Target。
- 设置 macOS 14 最低版本、Swift 6 和通用架构。
- 建立目录、公共模型、协议和错误类型。
- 配置应用为菜单栏形态。
- 建立 `AppCoordinator` 和依赖装配入口。
- 决定并接入全局快捷键方案。

交付物：应用可编译启动，菜单栏出现，公共接口可被其他模块引用。

依赖：无。其他工作包应等待公共接口首次提交后再大规模编码。

### WP-01：权限、菜单栏和设置

职责：

- 屏幕捕获权限检测。
- 首次启动权限引导。
- 打开正确的系统设置页面。
- 菜单栏菜单。
- SwiftUI 偏好设置窗口。
- `UserDefaults` 配置存储。
- 开机启动选项。
- 快捷键配置界面。

验收：权限状态显示准确；拒绝授权不会崩溃；修改设置后重启仍保留。

### WP-02：屏幕捕获与窗口发现

职责：

- 封装 ScreenCaptureKit。
- 获取 `SCDisplay`、`SCWindow` 和应用信息。
- 使用 `CGWindowListCopyWindowInfo` 补充窗口层级和边界。
- 过滤桌面、Dock、菜单栏、本应用窗口和无效小窗口。
- 捕获区域、单窗口和单显示器。
- 输出统一的 `CaptureResult`。

验收：区域、窗口和显示器图像尺寸正确；截图中不包含本应用遮罩；权限失败返回可识别错误。

### WP-03：坐标系统与截图遮罩

职责：

- 为每个显示器创建透明无边框遮罩窗口。
- 实现多显示器全局坐标和 Retina 像素转换。
- 鼠标框选、移动和八方向调整选区。
- 方向键逐像素微调。
- 显示选区尺寸。
- 根据缓存的窗口列表执行鼠标命中和窗口高亮。
- 实现取消、确认和操作工具栏。

验收：主副屏位于任意相对位置时不偏移；不同缩放比例的显示器之间切换正常；框选交互无明显跳动。

### WP-04：像素放大镜

职责：

- 在截图遮罩中提供光标附近像素预览。
- 显示十字准星和当前像素颜色值。
- 避免放大镜遮挡光标附近的关键区域。
- 控制刷新频率，避免鼠标移动时持续执行昂贵截图。

验收：Retina 和非 Retina 屏幕显示清晰；移动过程中无明显卡顿；边缘位置会自动调整浮层方向。

依赖：WP-02、WP-03 的基本接口。

### WP-05：标注编辑器

职责：

- 标注画布和工具栏。
- 矩形、箭头、文字、画笔和马赛克。
- 选中、移动、缩放和删除标注。
- 裁剪。
- 使用 `UndoManager` 实现撤销和重做。
- 将原图、裁剪和标注合成为最终 `CGImage`。

验收：标注在 Retina 输出中位置和粗细正确；撤销与重做覆盖全部编辑动作；编辑过程不破坏原始图像。

### WP-06：复制、编码和保存

职责：

- 将 `CGImage` 编码为 PNG 和 JPEG。
- JPEG 质量设置。
- 写入 `NSPasteboard`。
- 保存到默认目录。
- 使用 `NSSavePanel` 询问路径。
- 文件名规则和重名自动编号。
- 沙盒环境下保存默认目录的 security-scoped bookmark。
- 耗时编码放到非主线程。

验收：微信、邮件、备忘录等常用应用可粘贴；PNG 透明度正确；JPEG 质量设置生效；重名不覆盖已有文件。

### WP-07：贴图窗口

职责：

- `NSPanel` 贴图窗口。
- 多贴图实例管理。
- 始终置顶、移动和缩放。
- 调整透明度。
- 复制、保存和关闭。
- 不写入数据库，不在重启后恢复。

验收：多张贴图互不影响；切换应用后仍置顶；缩放保持图片比例；关闭后内存可释放。

### WP-08：质量保障与发布准备

职责：

- 单元测试和关键交互测试清单。
- Intel 与 Apple Silicon 构建检查。
- 多显示器、不同缩放比例和深色模式测试。
- 性能、内存和崩溃检查。
- 应用图标、版本信息和隐私说明。
- Debug、未签名 Release、Developer ID Release 三种构建说明。
- 准备 ZIP 或 DMG 分发流程。

验收：完整核心流程连续执行 50 次无崩溃；不存在明显内存持续增长；Release 构建可在干净用户环境运行。

## 7. 依赖关系与开发顺序

```text
WP-00 工程骨架
├── WP-01 权限与设置
├── WP-02 捕获与窗口发现
│   ├── WP-03 坐标与遮罩
│   │   └── WP-04 放大镜
│   └── WP-06 导出
├── WP-05 标注编辑器
└── WP-07 贴图窗口

WP-01～WP-07 完成
└── WP-08 集成测试与发布
```

推荐分阶段推进：

### 阶段 A：可运行骨架

- WP-00。
- 菜单栏启动。
- 公共接口冻结第一版。

### 阶段 B：最小截图闭环

- WP-01、WP-02、WP-03、WP-06 并行。
- 达成“快捷键 → 区域截图 → 复制或保存”。

### 阶段 C：完整首版能力

- WP-04、WP-05、WP-07 并行。
- 达成窗口截图、放大镜、标注和贴图。

### 阶段 D：稳定与分发

- WP-08。
- 修复集成问题、优化性能、准备打包。

## 8. 关键实现决策

### 8.1 截图数据统一使用 CGImage

- 捕获结果、标注渲染和编码接口使用 `CGImage`。
- `NSImage` 只用于 AppKit 界面显示。
- 禁止把 `NSImage.size` 直接当成像素尺寸。

### 8.2 窗口列表采用缓存

- 开始交互截图时获取一次窗口列表。
- 鼠标移动时只在缓存中命中测试。
- 不得在每次 `mouseMoved` 中调用完整窗口枚举。

### 8.3 遮罩隐藏后再捕获

- 用户确认选区后先隐藏所有遮罩、工具栏和放大镜。
- 等待窗口服务器完成一次显示刷新后再捕获。
- 必须测试截图结果中不会出现本应用 UI。

### 8.4 标注采用非破坏性编辑

- 原图保持不变。
- 标注和裁剪作为独立状态保存。
- 导出时一次性合成。

### 8.5 不使用额外辅助功能权限

- 全局快捷键优先通过 Hot Key API 实现。
- 不通过持续监听全局键盘事件实现普通快捷键。
- 首版原则上只请求屏幕捕获权限。

## 9. 性能目标

- 冷启动到菜单栏可用：目标小于 1 秒。
- 快捷键触发到遮罩可交互：目标小于 150 毫秒。
- 普通区域截图完成：目标小于 300 毫秒，不含用户操作时间。
- 鼠标框选和窗口高亮：尽量保持显示器刷新率，无肉眼可见卡顿。
- 空闲状态内存：目标小于 80 MB。
- 无截图任务时不持续捕获屏幕、不高频轮询窗口列表。

这些数值是首版工程目标，不是硬性发布承诺；应在真实机器上用 Instruments 测量。

## 10. 验收测试矩阵

### 10.1 显示器

- 单个 Retina 显示器。
- 内置屏幕加外接屏。
- 两块显示器缩放比例不同。
- 副屏位于主屏左、右、上、下。
- 显示器存在负全局坐标。

### 10.2 截图对象

- 普通应用窗口。
- 带圆角和阴影的窗口。
- 弹窗、菜单和浮动面板。
- 全屏应用。
- 桌面与多空间环境。

### 10.3 输出

- PNG 透明背景。
- JPEG 不同质量。
- 中文文件名和含空格路径。
- 无写入权限目录。
- 文件重名。
- 剪贴板粘贴到常见应用。

### 10.4 稳定性

- 截图过程中按 `Esc`。
- 截图过程中显示器断开。
- 权限被用户撤销。
- 保存面板取消。
- 快捷键重复触发。
- 连续创建和关闭多张贴图。

## 11. 多 AI 协作规则

1. 一个工作包对应一个主要负责人。
2. WP-00 负责人拥有公共模型和工程配置的最终协调权。
3. 修改公共协议前，先说明修改原因、受影响模块和迁移方式。
4. 不在自己工作包外进行大规模重构。
5. 不重复创建相同职责的 Service、Model 或工具类。
6. 每次提交只包含一个逻辑主题，并注明工作包编号。
7. 新增行为必须附测试，或在提交说明中给出可重复的人工验证步骤。
8. 禁止删除、覆盖或格式化其他进程正在修改的文件。
9. 遇到接口暂未完成时，优先基于协议创建最小 mock，不复制另一模块的实现。
10. 所有模块必须保持主工程可编译；未完成功能使用 feature flag 或 mock 隔离。

推荐提交信息：

```text
[WP-03] Implement multi-display coordinate conversion
[WP-06] Add PNG and JPEG export services
[WP-07] Add resizable pin window
```

每个工作包交付时应报告：

- 修改的文件。
- 已完成的功能。
- 尚未完成或已知限制。
- 测试方法和结果。
- 对其他模块提出的接口要求。

## 12. 分发策略

### 自己使用

- 不需要付费 Apple Developer Program。
- 可直接通过 Xcode 运行或导出本地构建。

### 少量熟人测试

- 可以发送未公证的 `.app` 或 ZIP。
- 对方可能需要在“系统设置 → 隐私与安全性”中手动允许打开。

### 正式站外分发

- 加入 Apple Developer Program。
- 使用 Developer ID 签名。
- 启用 Hardened Runtime。
- 提交 Apple 公证并将票据 staple 到产物。
- 最终通过 ZIP 或 DMG 分发。

开发阶段不必立即购买开发者会员；在需要顺畅分发给普通用户时再开通。

## 13. 首版完成定义

满足以下条件才视为 MVP 完成：

1. 用户首次启动能完成屏幕权限授权。
2. 用户可以设置并使用全局快捷键。
3. 可以在任意单个显示器上完成区域、窗口和全屏截图。
4. Retina 和多显示器坐标、尺寸正确。
5. 可以完成规定的六类标注并撤销、重做。
6. 可以复制到剪贴板或保存为 PNG/JPEG。
7. 可以创建和管理基础贴图窗口。
8. 所有设置在应用重启后保留。
9. 应用退出、取消截图、权限拒绝和保存失败时不会崩溃。
10. Release 构建通过核心测试矩阵。

首版完成后，新增需求必须进入后续版本规划，不应在 MVP 收尾阶段临时扩大范围。

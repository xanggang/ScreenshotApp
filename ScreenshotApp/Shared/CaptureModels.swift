import CoreGraphics
import Foundation

enum CaptureMode: Sendable {
    case interactive
    case display
}

enum CaptureTarget: Sendable, Equatable {
    case region(displayID: CGDirectDisplayID, rectInDisplay: CGRect)
    case window(windowID: CGWindowID)
    case display(displayID: CGDirectDisplayID)
}

struct CaptureResult: @unchecked Sendable {
    let image: CGImage
    let target: CaptureTarget
    let scale: CGFloat
    let capturedAt: Date
}

enum CaptureCompletionAction: String, CaseIterable, Codable, Sendable {
    case copy
    case save
    case annotate
    case pin
}

struct AvailableCaptureContent: Sendable {
    let displays: [CaptureDisplay]
    let windows: [CaptureWindow]

    init(displays: [CaptureDisplay], windows: [CaptureWindow]) {
        self.displays = displays
        self.windows = windows
    }
}

struct CaptureDisplay: Sendable, Equatable, Identifiable {
    let id: CGDirectDisplayID
    let frameInGlobalPoints: GlobalPointRect
    let scale: CGFloat
}

struct CaptureWindow: Sendable, Equatable, Identifiable {
    let id: CGWindowID
    let ownerName: String
    let title: String?
    let frameInGlobalPoints: GlobalPointRect
    let layer: Int
}

protocol Annotation: AnyObject {
    var id: UUID { get }
    var bounds: CGRect { get set }
    func draw(in context: CGContext)
    func hitTest(_ point: CGPoint) -> Bool
}

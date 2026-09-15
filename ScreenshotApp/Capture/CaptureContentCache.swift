import Foundation

/// Keeps one discovery snapshot for the duration of an interactive capture.
/// Mouse-move hit testing must use this cache rather than re-enumerating windows.
actor CaptureContentCache {
    private let discoveryService: any WindowDiscovering
    private var cachedContent: DiscoveredCaptureContent?

    init(discoveryService: any WindowDiscovering) {
        self.discoveryService = discoveryService
    }

    func content(forceRefresh: Bool = false) async throws -> DiscoveredCaptureContent {
        if !forceRefresh, let cachedContent { return cachedContent }
        let refreshed = try await discoveryService.discover()
        cachedContent = refreshed
        return refreshed
    }

    func invalidate() {
        cachedContent = nil
    }
}

import SwiftUI
import CoreMedia

// MARK: - Layout Constants

enum Layout {
    /// Outer page padding on all edges
    static let pagePadding: CGFloat = 24
    /// Padding inside cards
    static let cardPadding: CGFloat = 12
    /// Spacing between grid items
    static let gridSpacing: CGFloat = 20
    /// Padding for telemetry chips
    static let chipSpacing: CGFloat = 6
    /// Native Tesla dashcam video aspect ratio (1448×938)
    static let teslaAspect: CGFloat = 1448.0 / 938.0
    /// Pixel-aligned video cell spacing in multi-camera grids
    static let gridCellSpacing: CGFloat = 2
}

// MARK: - Animation System

extension Animation {
    /// Standard UI transition — navigation, section switches, card selection
    static let ui = Animation.spring(response: 0.38, dampingFraction: 0.82)
    /// Micro-interaction — hover states, button presses
    static let hover = Animation.spring(response: 0.28, dampingFraction: 0.68)
    /// Map frame animation — matches 15fps GPS update rate
    static let mapFrame = Animation.linear(duration: 1.0 / 15.0)
}

// MARK: - SEI Binary Search (shared utility)

/// Nearest SEI frame by binary search. O(log n).
/// Shared between VideoPlayerView and SpeedGraphView to avoid duplication.
func nearestSEIFrame(
    to t: Double,
    in timeline: [(seconds: Double, metadata: SeiMetadata)]
) -> (seconds: Double, metadata: SeiMetadata)? {
    guard !timeline.isEmpty else { return nil }
    var lo = 0, hi = timeline.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if timeline[mid].seconds < t { lo = mid + 1 } else { hi = mid }
    }
    if lo == 0 { return timeline[0] }
    if lo >= timeline.count { return timeline[timeline.count - 1] }
    let prev = timeline[lo - 1], next = timeline[lo]
    return abs(prev.seconds - t) <= abs(next.seconds - t) ? prev : next
}

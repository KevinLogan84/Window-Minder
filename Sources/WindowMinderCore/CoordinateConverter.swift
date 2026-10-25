import Foundation

/// Converts window frames between Accessibility and Cocoa coordinates.
///
/// Accessibility positions use the top-left of the primary display as the origin
/// and increase downward. The position of a window is its top-left corner.
/// Cocoa positions use the bottom-left of the primary display as the origin and
/// increase upward. A window frame's origin is its bottom-left corner.
///
/// `primaryHeight` is the height, in points, of the display whose bottom-left is
/// the Cocoa origin. The same height converts a window that sits on another display.
public enum CoordinateConverter {
    public static func cocoaFrame(fromAccessibility frame: WMRect, primaryHeight: Double) -> WMRect {
        WMRect(
            x: frame.x,
            y: primaryHeight - frame.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    public static func accessibilityFrame(fromCocoa frame: WMRect, primaryHeight: Double) -> WMRect {
        WMRect(
            x: frame.x,
            y: primaryHeight - frame.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }
}

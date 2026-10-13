import SwiftUI
import AppKit

/// The app icon's snowflake as a template image, so macOS tints it for light, dark,
/// Increase Contrast and Liquid Glass menu bars.
enum MenuBarIcon {
    static let image = snowflake(size: 18, lineWidth: 1.25, label: "TCLimate")

    /// Split unit, outline body and outlet line only. Marks the Set Temperature reading.
    static let splitOutlet = template { path in
        path.appendRoundedRect(NSRect(x: 1.5, y: 5.5, width: 17, height: 7), xRadius: 2.5, yRadius: 2.5)
        path.move(to: NSPoint(x: 5, y: 8)); path.line(to: NSPoint(x: 15, y: 8))
    }

    /// Strokes `build`'s path as an 20×18pt template image, so the menu bar tints it.
    private static func template(_ build: @escaping (NSBezierPath) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            let path = NSBezierPath()
            build(path)
            path.lineWidth = 1.25
            path.lineCapStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Air conditioner"
        return image
    }

    /// Draws the snowflake at its target point size so it stays crisp when used larger in the panel.
    /// Six rays, each with one small branch near its tip (matches the app icon).
    static func snowflake(size: CGFloat, lineWidth: CGFloat, label: String? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let center = CGPoint(x: rect.midX, y: rect.midY), length = rect.width * 0.46 - lineWidth / 2
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            for arm in 0..<6 {
                let angle = CGFloat.pi / 2 + CGFloat(arm) * .pi / 3
                path.move(to: center)
                path.line(to: CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length))
                let branch = CGPoint(x: center.x + cos(angle) * length * 0.685, y: center.y + sin(angle) * length * 0.685)
                for side in [-1.0, 1.0] {
                    let branchAngle = angle + CGFloat(side) * .pi / 4
                    path.move(to: branch)
                    path.line(to: CGPoint(x: branch.x + cos(branchAngle) * length * 0.26, y: branch.y + sin(branchAngle) * length * 0.26))
                }
            }
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = label
        return image
    }
}

/// The app's snowflake in a soft rounded tile, used as the logo on sign-in.
struct BrandMark: View {
    let size: CGFloat

    var body: some View {
        let glyph = size * 0.6
        Image(nsImage: MenuBarIcon.snowflake(size: glyph, lineWidth: max(1.25, glyph * 0.055)))
            .renderingMode(.template)
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            .accessibilityHidden(true)
    }
}


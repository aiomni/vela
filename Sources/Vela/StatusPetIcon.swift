import AppKit

// Reuse the original companion silhouette and its upper-right gaze for both icons.
@MainActor
func companionIconPath(geometry: PetGeometry, in rect: NSRect) -> NSBezierPath {
    let path = geometry.bodyPath()
    path.windingRule = .evenOdd
    for points in geometry.eyes[0] {
        let eye = NSBezierPath()
        for (index, point) in points.enumerated() {
            let position = NSPoint(x: point[0], y: point[1])
            if index == 0 { eye.move(to: position) } else { eye.line(to: position) }
        }
        eye.close()
        path.append(eye)
    }
    let bounds = path.bounds
    let scale = min(rect.width / bounds.width, rect.height / bounds.height)
    // Asset coordinates run downward; AppKit icon coordinates run upward.
    path.transform(using: AffineTransform(m11: scale, m12: 0, m21: 0, m22: -scale,
        tX: rect.midX - bounds.midX * scale, tY: rect.midY + bounds.midY * scale))
    return path
}

@MainActor
func makeStatusPetIcon(geometry: PetGeometry) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        NSColor.black.setFill()
        companionIconPath(geometry: geometry, in: NSRect(x: 1, y: 1, width: 16, height: 16)).fill()
        return true
    }
    image.isTemplate = true
    return image
}

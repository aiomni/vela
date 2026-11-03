import AppKit

enum StatusPetIconMood: Hashable {
    case asleep, awake, watching
}

@MainActor
func makeStatusPetIcon(geometry: PetGeometry, mood: StatusPetIconMood) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let body = geometry.bodyPath()
        let bounds = body.bounds
        let scale = min(16 / bounds.width, 16 / bounds.height)
        let transform = AffineTransform(m11: scale, m12: 0, m21: 0, m22: scale,
                                        tX: 9 - bounds.midX * scale, tY: 9 - bounds.midY * scale)
        body.transform(using: transform)

        // Cut eyes out of the silhouette so the system can tint this template
        // correctly in both light and dark menu bars.
        let silhouette = NSBezierPath()
        silhouette.windingRule = .evenOdd
        silhouette.append(body)
        for centerX in [6.4, 11.6] {
            let eye: NSBezierPath
            switch mood {
            case .asleep:
                eye = NSBezierPath(roundedRect: NSRect(x: centerX - 1.9, y: 7.85, width: 3.8, height: 2.3),
                                   xRadius: 1.15, yRadius: 1.15)
            case .awake:
                eye = NSBezierPath(roundedRect: NSRect(x: centerX - 1.55, y: 6.15, width: 3.1, height: 5.7),
                                   xRadius: 1.5, yRadius: 1.5)
            case .watching:
                eye = NSBezierPath(roundedRect: NSRect(x: centerX - 1.75, y: 5.9, width: 3.5, height: 6.2),
                                   xRadius: 1.7, yRadius: 1.7)
            }
            silhouette.append(eye)
        }
        NSColor.black.setFill()
        silhouette.fill()
        if mood == .watching {
            for centerX in [6.4, 11.6] {
                NSBezierPath(ovalIn: NSRect(x: centerX + 0.15, y: 8.1, width: 1.45, height: 2.1)).fill()
            }
        }
        return true
    }
    image.isTemplate = true
    return image
}

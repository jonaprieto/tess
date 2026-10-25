import AppKit

enum Icons {
    /// An app or file icon as one small bitmap (80 px, 40 pt), drawn once: the originals carry
    /// representations up to 1024 px that AppKit would downsample on every redraw.
    static func small(_ image: NSImage?) -> NSImage? {
        guard let image, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 80, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 80, height: 80))
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: NSSize(width: 40, height: 40))
        out.addRepresentation(rep)
        return out
    }
}

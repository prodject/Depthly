import AppKit

final class SplitDepthBarsView: NSView {
    var settings: EffectSettings = .default {
        didSet {
            needsDisplay = true
        }
    }

    var contentRectProvider: (() -> CGRect)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard settings.isEnabled else { return }

        NSColor.clear.setFill()
        dirtyRect.fill()

        let bounds = self.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let drawRect = contentRectProvider?() ?? bounds
        guard drawRect.width > 0, drawRect.height > 0 else { return }

        NSColor.black.setFill()

        let border = max(0.0, min(0.25, settings.borderThickness))
        let borderX = max(1, drawRect.width * border)
        let borderY = max(1, drawRect.height * border)

        NSBezierPath(rect: CGRect(x: drawRect.minX, y: drawRect.minY, width: borderX, height: drawRect.height)).fill()
        NSBezierPath(rect: CGRect(x: drawRect.maxX - borderX, y: drawRect.minY, width: borderX, height: drawRect.height)).fill()
        NSBezierPath(rect: CGRect(x: drawRect.minX, y: drawRect.minY, width: drawRect.width, height: borderY)).fill()
        NSBezierPath(rect: CGRect(x: drawRect.minX, y: drawRect.maxY - borderY, width: drawRect.width, height: borderY)).fill()

        if settings.verticalBarsEnabled {
            let thickness = max(0.0, min(0.45, settings.verticalBarThickness))
            let barWidth = max(1, drawRect.width * thickness)
            let divisions = 3
            for index in 1..<divisions {
                let center = drawRect.minX + drawRect.width * CGFloat(index) / CGFloat(divisions)
                let x = max(drawRect.minX, center - barWidth / 2)
                NSBezierPath(rect: CGRect(x: x, y: drawRect.minY, width: barWidth, height: drawRect.height)).fill()
            }
        }

        if settings.horizontalBarsEnabled {
            let thickness = max(0.0, min(0.45, settings.horizontalBarThickness))
            let barHeight = max(1, drawRect.height * thickness)
            NSBezierPath(rect: CGRect(x: drawRect.minX, y: drawRect.minY, width: drawRect.width, height: barHeight)).fill()
            NSBezierPath(rect: CGRect(x: drawRect.minX, y: drawRect.maxY - barHeight, width: drawRect.width, height: barHeight)).fill()
        }
    }
}

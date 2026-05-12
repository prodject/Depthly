import AppKit

final class SplitDepthBarsView: NSView {
    var settings: EffectSettings = .default {
        didSet {
            needsDisplay = true
        }
    }

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

        NSColor.black.setFill()

        let border = max(0.0, min(0.25, settings.borderThickness))
        let borderX = max(1, bounds.width * border)
        let borderY = max(1, bounds.height * border)

        NSBezierPath(rect: CGRect(x: 0, y: 0, width: borderX, height: bounds.height)).fill()
        NSBezierPath(rect: CGRect(x: bounds.width - borderX, y: 0, width: borderX, height: bounds.height)).fill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: bounds.width, height: borderY)).fill()
        NSBezierPath(rect: CGRect(x: 0, y: bounds.height - borderY, width: bounds.width, height: borderY)).fill()

        if settings.verticalBarsEnabled {
            let thickness = max(0.0, min(0.45, settings.verticalBarThickness))
            let barWidth = max(1, bounds.width * thickness)
            let divisions = 3
            for index in 1..<divisions {
                let center = bounds.width * CGFloat(index) / CGFloat(divisions)
                let x = max(0, center - barWidth / 2)
                NSBezierPath(rect: CGRect(x: x, y: 0, width: barWidth, height: bounds.height)).fill()
            }
        }

        if settings.horizontalBarsEnabled {
            let thickness = max(0.0, min(0.45, settings.horizontalBarThickness))
            let barHeight = max(1, bounds.height * thickness)
            NSBezierPath(rect: CGRect(x: 0, y: 0, width: bounds.width, height: barHeight)).fill()
            NSBezierPath(rect: CGRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)).fill()
        }
    }
}

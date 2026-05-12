import AppKit
import Metal
import MetalKit

final class SplitDepthBarsView: MTKView, MTKViewDelegate {
    private let renderer: SplitDepthBarsRenderer

    var settings: EffectSettings = .default {
        didSet {
            needsDisplay = true
        }
    }

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is required for Depthly.")
        }
        renderer = try! SplitDepthBarsRenderer(device: device)
        super.init(frame: .zero, device: device)

        clearColor = MTLClearColorMake(0, 0, 0, 0)
        colorPixelFormat = .bgra8Unorm
        wantsLayer = true
        framebufferOnly = true
        enableSetNeedsDisplay = true
        isPaused = true
        delegate = self
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        renderer.draw(in: view, settings: settings)
    }
}

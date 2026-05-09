import MetalKit
import SwiftUI

struct MetalVideoSurface: NSViewRepresentable {
    @ObservedObject var viewModel: PlayerViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.framebufferOnly = false
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator.renderer
        view.autoResizeDrawable = true
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.viewModel = viewModel
    }

    final class Coordinator {
        var viewModel: PlayerViewModel
        let device: MTLDevice
        let renderer: MetalSplitDepthRenderer

        init(viewModel: PlayerViewModel) {
            self.viewModel = viewModel
            guard let device = MTLCreateSystemDefaultDevice() else {
                fatalError("Metal is not available on this system")
            }
            self.device = device
            renderer = MetalSplitDepthRenderer(device: device, viewModel: viewModel)!
        }
    }
}

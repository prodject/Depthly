import Foundation
import Metal
import MetalKit
import simd

struct SplitDepthBarUniforms {
    var viewportSize: SIMD2<Float>
    var thickness: Float
    var orientation: UInt32
    var padding: SIMD2<Float> = .zero
}

final class SplitDepthBarsRenderer {
    private let pipelineState: MTLRenderPipelineState
    private let commandQueue: MTLCommandQueue

    private static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct SplitDepthBarUniforms {
        float2 viewportSize;
        float thickness;
        uint orientation;
        float2 padding;
    };

    struct VertexOut {
        float4 position [[position]];
    };

    vertex VertexOut splitDepthBarsVertex(uint vertexID [[vertex_id]]) {
        float2 positions[3] = {
            float2(-1.0, -1.0),
            float2(3.0, -1.0),
            float2(-1.0, 3.0)
        };

        VertexOut out;
        out.position = float4(positions[vertexID], 0.0, 1.0);
        return out;
    }

    fragment half4 splitDepthBarsFragment(VertexOut in [[stage_in]],
                                          constant SplitDepthBarUniforms& uniforms [[buffer(0)]]) {
        float2 pixel = (in.position.xy * 0.5 + 0.5) * uniforms.viewportSize;
        float2 uv = pixel / max(uniforms.viewportSize, float2(1.0));
        float thickness = clamp(uniforms.thickness, 0.0, 0.45);

        bool vertical = uniforms.orientation == 1;
        bool horizontal = uniforms.orientation == 2;
        if (!vertical && !horizontal) {
            vertical = uniforms.viewportSize.x >= uniforms.viewportSize.y;
            horizontal = !vertical;
        }

        bool draw = false;
        if (vertical) {
            draw = uv.x < thickness || uv.x > (1.0 - thickness);
        } else {
            draw = uv.y < thickness || uv.y > (1.0 - thickness);
        }

        return draw ? half4(0.0, 0.0, 0.0, 1.0) : half4(0.0, 0.0, 0.0, 0.0);
    }
    """

    init(device: MTLDevice) throws {
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.metalSource, options: nil)
        } catch {
            throw NSError(domain: "Depthly.Metal", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to create Metal library: \(error.localizedDescription)"])
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "SplitDepthBarsPipeline"
        descriptor.vertexFunction = library.makeFunction(name: "splitDepthBarsVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "splitDepthBarsFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)

        guard let commandQueue = device.makeCommandQueue() else {
            throw NSError(domain: "Depthly.Metal", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unable to create Metal command queue."])
        }
        self.commandQueue = commandQueue
    }

    func draw(in view: MTKView, settings: EffectSettings) {
        guard settings.isEnabled,
              let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor
        else {
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else {
            return
        }

        encoder.label = "SplitDepthBarsEncoder"
        encoder.setRenderPipelineState(pipelineState)

        var uniforms = SplitDepthBarUniforms(
            viewportSize: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            thickness: Float(max(0.0, min(0.45, settings.borderThickness))),
            orientation: orientationValue(for: settings, viewSize: view.bounds.size)
        )

        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SplitDepthBarUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func orientationValue(for settings: EffectSettings, viewSize: CGSize) -> UInt32 {
        switch settings.orientation {
        case .vertical:
            return 1
        case .horizontal:
            return 2
        case .auto:
            return viewSize.width >= viewSize.height ? 1 : 2
        }
    }
}

import Foundation
import Metal
import MetalKit
import simd

struct SplitDepthBarUniforms {
    var viewportSize: SIMD2<Float>
    var verticalThickness: Float
    var horizontalThickness: Float
    var verticalCount: UInt32
    var verticalEnabled: UInt32
    var horizontalEnabled: UInt32
    var padding: UInt32 = 0
}

final class SplitDepthBarsRenderer {
    private let pipelineState: MTLRenderPipelineState
    private let commandQueue: MTLCommandQueue

    private static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct SplitDepthBarUniforms {
        float2 viewportSize;
        float verticalThickness;
        float horizontalThickness;
        uint verticalCount;
        uint verticalEnabled;
        uint horizontalEnabled;
        uint padding;
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
        bool draw = false;

        if (uniforms.verticalEnabled != 0 && uniforms.verticalCount >= 2u) {
            float thickness = clamp(uniforms.verticalThickness, 0.0, 0.45);
            float halfThickness = thickness * 0.5;
            uint count = uniforms.verticalCount;
            for (uint i = 1u; i < count; ++i) {
                float center = float(i) / float(count);
                if (abs(uv.x - center) <= halfThickness) {
                    draw = true;
                }
            }
        }

        if (uniforms.horizontalEnabled != 0) {
            float thickness = clamp(uniforms.horizontalThickness, 0.0, 0.45);
            float halfThickness = thickness * 0.5;
            if (uv.y <= halfThickness || uv.y >= (1.0 - halfThickness)) {
                draw = true;
            }
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
            verticalThickness: Float(max(0.0, min(0.45, settings.verticalBarThickness))),
            horizontalThickness: Float(max(0.0, min(0.45, settings.horizontalBarThickness))),
            verticalCount: UInt32(settings.verticalBarDivisionCount.rawValue),
            verticalEnabled: settings.verticalBarsEnabled ? 1 : 0,
            horizontalEnabled: settings.horizontalBarsEnabled ? 1 : 0
        )

        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SplitDepthBarUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

}

import AppKit
import AVFoundation
import CoreVideo
import Metal
import MetalKit
import QuartzCore
import SwiftUI

struct MetalSplitDepthRenderState {
    var frameBuffer: CVPixelBuffer?
    var overlayImage: CGImage?
    var videoSize: CGSize = .zero
    var borderThickness: CGFloat = 64
    var isEffectEnabled: Bool = true
    var overlayRevision: Int = 0
}

final class MetalSplitDepthRenderer: NSObject, MTKViewDelegate {
    private struct Vertex {
        var position: SIMD2<Float>
        var texCoord: SIMD2<Float>
    }

    private weak var viewModel: PlayerViewModel?
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureLoader: MTKTextureLoader
    private let textureCache: CVMetalTextureCache
    private let pipelineState: MTLRenderPipelineState
    private let samplerState: MTLSamplerState
    private let vertexBuffer: MTLBuffer

    private var cachedOverlayTexture: MTLTexture?
    private var cachedOverlayRevision: Int = -1

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float2 position;
        float2 texCoord;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    vertex VertexOut vertex_main(uint vertexID [[vertex_id]],
                                 constant VertexIn *vertices [[buffer(0)]]) {
        VertexOut out;
        out.position = float4(vertices[vertexID].position, 0.0, 1.0);
        out.texCoord = vertices[vertexID].texCoord;
        return out;
    }

    fragment float4 fragment_main(VertexOut in [[stage_in]],
                                  texture2d<float> colorTexture [[texture(0)]]) {
        constexpr sampler textureSampler(filter::linear, address::clamp_to_edge);
        float2 uv = float2(in.texCoord.x, 1.0 - in.texCoord.y);
        return colorTexture.sample(textureSampler, uv);
    }
    """

    init?(device: MTLDevice, viewModel: PlayerViewModel) {
        guard let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vertexFunction = library.makeFunction(name: "vertex_main"),
              let fragmentFunction = library.makeFunction(name: "fragment_main") else {
            return nil
        }

        let vertexDescriptor = MTLRenderPipelineDescriptor()
        vertexDescriptor.vertexFunction = vertexFunction
        vertexDescriptor.fragmentFunction = fragmentFunction
        vertexDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        guard let pipelineState = try? device.makeRenderPipelineState(descriptor: vertexDescriptor) else {
            return nil
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge

        guard let samplerState = device.makeSamplerState(descriptor: samplerDescriptor) else {
            return nil
        }

        let quad: [Vertex] = [
            Vertex(position: [-1, -1], texCoord: [0, 1]),
            Vertex(position: [ 1, -1], texCoord: [1, 1]),
            Vertex(position: [-1,  1], texCoord: [0, 0]),
            Vertex(position: [ 1,  1], texCoord: [1, 0])
        ]

        guard let vertexBuffer = device.makeBuffer(bytes: quad, length: MemoryLayout<Vertex>.stride * quad.count, options: [.storageModeShared]) else {
            return nil
        }

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let textureCache = cache else { return nil }

        self.viewModel = viewModel
        self.device = device
        self.commandQueue = commandQueue
        self.textureLoader = MTKTextureLoader(device: device)
        self.textureCache = textureCache
        self.pipelineState = pipelineState
        self.samplerState = samplerState
        self.vertexBuffer = vertexBuffer
        super.init()
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor else { return }

        let state = MainActor.assumeIsolated {
            viewModel?.metalRenderState() ?? MetalSplitDepthRenderState()
        }
        let commandBuffer = commandQueue.makeCommandBuffer()
        let encoder = commandBuffer?.makeRenderCommandEncoder(descriptor: renderPassDescriptor)

        encoder?.setRenderPipelineState(pipelineState)
        encoder?.setFragmentSamplerState(samplerState, index: 0)
        encoder?.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        let drawableSize = CGSize(width: view.drawableSize.width, height: view.drawableSize.height)
        let canvasAspect = canvasAspectRatio(for: state)
        let canvasRect = fitRect(aspectRatio: canvasAspect, in: CGRect(origin: .zero, size: drawableSize))
        let borderScale = canvasRect.width / max(state.videoSize.width + state.borderThickness * 2, 1)
        let frameRect = canvasRect.insetBy(dx: state.borderThickness * borderScale, dy: state.borderThickness * borderScale)

        if let frameBuffer = state.frameBuffer {
            if let frameTexture = makeTexture(from: frameBuffer) {
                draw(texture: frameTexture, with: encoder, viewport: viewport(for: frameRect))
            }
        }

        if state.isEffectEnabled, let overlayImage = state.overlayImage {
            if cachedOverlayRevision != state.overlayRevision {
                cachedOverlayTexture = try? textureLoader.newTexture(cgImage: overlayImage, options: [
                    MTKTextureLoader.Option.SRGB: false
                ])
                cachedOverlayRevision = state.overlayRevision
            }

            if let overlayTexture = cachedOverlayTexture {
                draw(texture: overlayTexture, with: encoder, viewport: viewport(for: canvasRect))
            }
        }

        encoder?.endEncoding()
        if let commandBuffer {
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    }

    private func draw(texture: MTLTexture?, with encoder: MTLRenderCommandEncoder?, viewport: MTLViewport) {
        guard let texture, let encoder else { return }
        encoder.setViewport(viewport)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func viewport(for rect: CGRect) -> MTLViewport {
        MTLViewport(
            originX: Double(rect.minX),
            originY: Double(rect.minY),
            width: Double(rect.width),
            height: Double(rect.height),
            znear: 0,
            zfar: 1
        )
    }

    private func fitRect(aspectRatio: CGFloat, in bounds: CGRect) -> CGRect {
        guard aspectRatio > 0 else { return bounds }

        let boundsAspect = bounds.width / max(bounds.height, 1)
        if boundsAspect > aspectRatio {
            let width = bounds.height * aspectRatio
            let x = bounds.midX - width / 2
            return CGRect(x: x, y: bounds.minY, width: width, height: bounds.height)
        } else {
            let height = bounds.width / aspectRatio
            let y = bounds.midY - height / 2
            return CGRect(x: bounds.minX, y: y, width: bounds.width, height: height)
        }
    }

    private func canvasAspectRatio(for state: MetalSplitDepthRenderState) -> CGFloat {
        let width = max(state.videoSize.width + state.borderThickness * 2, 1)
        let height = max(state.videoSize.height + state.borderThickness * 2, 1)
        return width / height
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTextureOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTextureOut
        )

        guard status == kCVReturnSuccess,
              let cvTextureOut,
              let texture = CVMetalTextureGetTexture(cvTextureOut) else {
            return nil
        }

        return texture
    }
}

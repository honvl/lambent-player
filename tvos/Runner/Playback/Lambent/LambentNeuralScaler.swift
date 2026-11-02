import CoreML
import CoreVideo
import Foundation
import Metal
import os
import QuartzCore

/// Lambent's AI upscaler on the Apple TV: NVIDIA's 2x video super resolution "low" networks (NVIDIA Open Model License) on the Neural
/// Engine, as Lambent's Mac enhancer runs them (companion/live-enhancer-mac NeuralScaler.swift; docs/SHADER_UPSCALE.md in Lambent).
///
/// The models are not in this repository: `tvos/scripts/copy_vsr_models.sh <Lambent checkout>` puts `neural-low-1920x1088.mlmodelc`,
/// `neural-hb-1920x1088.mlmodelc`, the licence and NVIDIA's notice in `Runner/Shaders/vsr` (git-ignored). Without them the ladder
/// starts at the shader upscaler.
///
/// One picture: Metal `pack` turns the decoded Y'CbCr into the network's 16 half-size channels and keeps the same R'G'B' at the picture's
/// size; Core ML runs the network on the Neural Engine (its tanh residual, 48 half-size channels); Metal `finish` adds the residual,
/// pixel-shuffled, to a bicubic 2x and writes what the lift processor's `prep` pass writes, at twice the size: Y' (full range, Deepen
/// blacks' bend applied) and the 2 x 2 blocks' chroma. The processor's last pass then scales to the screen as for the shader prescalers.
/// A picture up to 1920 x 1088 (one fixed-size model per network; a smaller one is edge-padded).
final class LambentNeuralScaler {
    static let modelSize = (1920, 1088)
    static let networks = ["neural-low", "neural-hb"]

    /// `neural-hb` (NVIDIA's HIGHBITRATE_LOW) from this many bits a pixel, `neural-low` (trained on compressed video) below or when the
    /// bitrate is unknown: Lambent's own rule (`LAMBENT_ENHANCE_NEURAL_HB_BPP`, a starting value).
    static let highBitrateBitsPerPixel = 0.30

    static func network(bitrate: Int64, width: Int, height: Int, frameRate: Double) -> String {
        guard bitrate > 0, width > 0, height > 0, frameRate > 0 else { return "neural-low" }
        let bpp = Double(bitrate) / (Double(width * height) * frameRate)
        return bpp >= highBitrateBitsPerPixel ? "neural-hb" : "neural-low"
    }

    static var directory: URL? { LambentPrescaler.bundleDirectory?.appendingPathComponent("vsr", isDirectory: true) }

    /// The network's model: its int8 one (`<network>-w8a8-<size>`, int8 weights and activations) when `int8` and it is in the bundle,
    /// else the fp16 one.
    static func modelURL(_ network: String, int8: Bool = preferInt8) -> URL? {
        for name in int8 ? ["\(network)-w8a8", network] : [network] {
            if let url = directory?.appendingPathComponent("\(name)-\(modelSize.0)x\(modelSize.1).mlmodelc"),
                FileManager.default.fileExists(atPath: url.path)
            {
                return url
            }
        }
        return nil
    }

    /// Int8 models (where the bundle has them) instead of fp16. Off: on an A16 they saved about 1 ms of a 31 ms picture inside the
    /// player (the network alone 14.7 against 15.4 ms), for 0.1 VMAF on compressed SDR in Lambent's tests (docs/SHADER_UPSCALE.md).
    /// A bench sets it.
    nonisolated(unsafe) static var preferInt8 = false

    /// Both models are in the bundle.
    static var available: Bool { networks.allSatisfy { modelURL($0, int8: false) != nil } }

    /// Loaded scalers by network, kept for the app's life: loading a model on the Neural Engine takes a while the first time.
    private static let loaded = OSAllocatedUnfairLock(initialState: [String: LambentNeuralScaler]())
    private static let loading = OSAllocatedUnfairLock(initialState: Set<String>())
    private static let loadQueue = DispatchQueue(label: "lambent.neural-load", qos: .utility)
    nonisolated(unsafe) static var failures: [String: String] = [:]

    /// The scaler for `network` if it has loaded; otherwise nil, and it starts loading in the background.
    static func scaler(_ network: String, device: MTLDevice) -> LambentNeuralScaler? {
        let int8 = preferInt8
        let key = network + (int8 ? " int8" : "")
        if let s = loaded.withLock({ $0[key] }) { return s }
        let start = loading.withLock { $0.insert(key).inserted }
        if start {
            loadQueue.async {
                let t = CACurrentMediaTime()
                do {
                    let s = try LambentNeuralScaler(device: device, network: network, int8: int8)
                    loaded.withLock { $0[key] = s }
                    NSLog("[LambentHDR] AI upscaler %@ (%@) loaded in %.0f ms", network, s.int8 ? "int8" : "fp16", (CACurrentMediaTime() - t) * 1000)
                } catch {
                    failures[network] = "\(error)"
                    NSLog("[LambentHDR] AI upscaler %@ did not load: %@", network, "\(error)")
                }
            }
        }
        return nil
    }

    /// Blocks until `network` has loaded (a bench).
    static func loadNow(_ network: String, device: MTLDevice) -> LambentNeuralScaler? {
        _ = scaler(network, device: device)
        loadQueue.sync {}
        return loaded.withLock { $0[network + (preferInt8 ? " int8" : "")] }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    let network: String
    /// The int8 (W8A8) model.
    let int8: Bool
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let packPipeline: MTLComputePipelineState
    private let finishPipeline: MTLComputePipelineState
    private let model: MLModel

    /// One picture's buffers. Three, for the player's three stages (LambentHDRLift.swift): the GPU packs picture N + 2 while the
    /// Neural Engine runs N + 1 and the GPU finishes N. On an A16 the network takes 15 ms back to back but 24 ms with a 5 ms pack
    /// between runs (the Neural Engine idles and slows), and 29 ms when it also takes turns with the GPU's finish.
    ///
    /// The network's input and output are IOSurface pixel buffers (half-float, 960 wide, channels x 544 high, rows unpadded) wrapped as
    /// Core ML arrays: on an A16 the network took 13.1-13.5 ms on those against 15.4 ms on arrays over plain shared Metal buffers (Core
    /// ML copied those). Metal reaches the same memory as buffers made over the surfaces, in the same linear layout.
    final class Slot {
        let input: MTLBuffer, output: MTLBuffer
        private let surfaces: (CVPixelBuffer, CVPixelBuffer)
        let features: MLFeatureProvider
        let options = MLPredictionOptions()
        var base: MTLTexture?, luma: MTLTexture?, chroma: MTLTexture?
        /// This picture's Neural Engine and pack milliseconds, and the pack's wall time (commit to done, waiting behind other GPU work
        /// included).
        var engineMs = 0.0, packMs = 0.0, packWallMs = 0.0

        init(device: MTLDevice) throws {
            let (w2, h2) = (LambentNeuralScaler.modelSize.0 / 2, LambentNeuralScaler.modelSize.1 / 2)
            func surface(_ channels: Int) throws -> (CVPixelBuffer, MLMultiArray, MTLBuffer) {
                var made: CVPixelBuffer?
                let attrs: [String: Any] = [
                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](), kCVPixelBufferMetalCompatibilityKey as String: true,
                ]
                CVPixelBufferCreate(nil, w2, channels * h2, kCVPixelFormatType_OneComponent16Half, attrs as CFDictionary, &made)
                guard let buffer = made, let io = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue(),
                    CVPixelBufferGetBytesPerRow(buffer) == w2 * 2
                else { throw Failure("no \(channels)-channel surface") }
                // The surface's memory stays mapped for its life; the buffer keeps the pixel buffer (and so the surface) alive.
                let length = channels * h2 * w2 * 2
                guard let metal = device.makeBuffer(
                    bytesNoCopy: IOSurfaceGetBaseAddress(io), length: (length + 16383) / 16384 * 16384, options: .storageModeShared,
                    deallocator: { _, _ in _ = buffer })
                else { throw Failure("no Metal buffer over the \(channels)-channel surface") }
                let shape = [1, NSNumber(value: channels), NSNumber(value: h2), NSNumber(value: w2)]
                return (buffer, MLMultiArray(pixelBuffer: buffer, shape: shape), metal)
            }
            let (inBuffer, inArray, input) = try surface(16)
            let (outBuffer, outArray, output) = try surface(48)
            surfaces = (inBuffer, outBuffer)
            self.input = input
            self.output = output
            features = try MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: inArray)])
            options.outputBackings = ["residual": outArray]
        }
    }

    private let slots: [Slot]
    static let slotCount = 3
    private var next = 0

    private init(device: MTLDevice, network: String, int8: Bool) throws {
        guard let url = Self.modelURL(network, int8: int8) else { throw Failure("no model \(network) (tvos/scripts/copy_vsr_models.sh)") }
        self.int8 = url.lastPathComponent.contains("-w8a8-")
        guard let queue = device.makeCommandQueue() else { throw Failure("no command queue") }
        self.device = device
        self.queue = queue
        self.network = network
        let library = try device.makeLibrary(source: neuralSource, options: nil)
        packPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "pack")!)
        finishPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "finish")!)
        let config = MLModelConfiguration()
        // The Neural Engine: the GPU stays free for decoding, the lift and the last pass.
        config.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: url, configuration: config)
        slots = [try Slot(device: device), try Slot(device: device), try Slot(device: device)]
    }

    /// A bench: `n` network runs back to back on whatever is in the input (no GPU work between them); mean ms.
    func timeNetwork(_ n: Int) -> Double {
        let started = CACurrentMediaTime()
        for _ in 0..<n { _ = try? model.prediction(from: slots[0].features, options: slots[0].options) }
        return (CACurrentMediaTime() - started) * 1000 / Double(n)
    }

    /// Takes a picture of this size.
    static func fits(_ w: Int, _ h: Int) -> Bool { w <= modelSize.0 && h <= modelSize.1 }

    private func textures(_ slot: Slot, _ w: Int, _ h: Int) -> MTLTexture? {
        if let base = slot.base, base.width == w, base.height == h { return base }
        func make(_ format: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        slot.base = make(.rgba16Float, w, h)
        slot.luma = make(.r16Float, 2 * w, 2 * h)
        slot.chroma = make(.rg16Float, w, h)
        return slot.luma != nil && slot.chroma != nil ? slot.base : nil
    }

    /// Packs the picture (its Y' and CbCr planes as Metal textures, video range; `codeScale` turns a sample into a 10-bit code) into the
    /// next of the slots, waiting for it; then `infer` and `encodeFinish` with that slot, all before it comes round again (the caller
    /// keeps at most as many pictures in flight as there are slots).
    func pack(inY: MTLTexture, inC: MTLTexture, codeScale: Float) throws -> Slot {
        let slot = slots[next]
        next = (next + 1) % slots.count
        let (w, h) = (inY.width, inY.height)
        guard Self.fits(w, h), let base = textures(slot, w, h) else { throw Failure("\(w)x\(h) does not fit") }
        var params = NeuralParams(
            inW: UInt32(w), inH: UInt32(h), w2: UInt32(Self.modelSize.0 / 2), h2: UInt32(Self.modelSize.1 / 2), codeScale: codeScale,
            lift: 0, knee: 0.5)
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeComputeCommandEncoder() else { throw Failure("no command buffer") }
        encoder.setComputePipelineState(packPipeline)
        encoder.setTextures([inY, inC, base], range: 0..<3)
        encoder.setBuffer(slot.input, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<NeuralParams>.size, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: Self.modelSize.0 / 2, height: Self.modelSize.1 / 2, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        let committed = CACurrentMediaTime()
        buffer.commit()
        buffer.waitUntilCompleted()
        if let error = buffer.error { throw error }
        slot.packWallMs = (CACurrentMediaTime() - committed) * 1000
        slot.packMs = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
        return slot
    }

    /// The network on the slot's packed picture, on the Neural Engine, waited for.
    func infer(_ slot: Slot) throws {
        let started = CACurrentMediaTime()
        _ = try model.prediction(from: slot.features, options: slot.options)
        slot.engineMs = (CACurrentMediaTime() - started) * 1000
    }

    /// The slot's residual onto a bicubic 2x, in `buffer`: Y' at twice the picture's size and the 2 x 2 blocks' chroma (the picture's
    /// size), as the processor's `prep` writes them, Deepen blacks' bend (`lift`, 0: none) applied.
    func encodeFinish(_ slot: Slot, _ buffer: MTLCommandBuffer, lift: Float, knee: Float) -> (luma: MTLTexture, chroma: MTLTexture)? {
        guard let base = slot.base, let luma = slot.luma, let chroma = slot.chroma, let encoder = buffer.makeComputeCommandEncoder()
        else { return nil }
        var params = NeuralParams(
            inW: UInt32(base.width), inH: UInt32(base.height), w2: UInt32(Self.modelSize.0 / 2), h2: UInt32(Self.modelSize.1 / 2),
            codeScale: 0, lift: lift, knee: knee)
        encoder.setComputePipelineState(finishPipeline)
        encoder.setTextures([base, luma, chroma], range: 0..<3)
        encoder.setBuffer(slot.output, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<NeuralParams>.size, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: base.width, height: base.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        return (luma, chroma)
    }
}

private struct NeuralParams {
    var inW: UInt32, inH: UInt32, w2: UInt32, h2: UInt32
    var codeScale: Float
    var lift: Float, knee: Float
}

// The Mac enhancer's `pack` and `finish` (NeuralScaler.swift), BT.709 like the rest of the processor; `finish` writes Y' and chroma at
// once (one thread a picture pixel: the 2 x 2 output pixels it becomes) instead of R'G'B' for a separate resample.
private let neuralSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params { uint inW, inH, w2, h2; float codeScale; float lift; float knee; };

    constant float KR = 0.2126, KB = 0.0722;

    // Video-range Y'CbCr (normalised samples; codeScale to a 10-bit code) to R'G'B'.
    static float3 to_rgb(float y, float2 c, float codeScale) {
        float Y = (y * codeScale - 64.0) / 876.0;
        float2 C = (c * codeScale - 512.0) / 896.0;
        float r = Y + 2.0 * (1.0 - KR) * C.y;
        float b = Y + 2.0 * (1.0 - KB) * C.x;
        float g = (Y - KR * r - KB * b) / (1.0 - KR - KB);
        return clamp(float3(r, g, b), 0.0, 1.0);
    }

    // Each 2 x 2 block of the edge-padded picture as 16 channels at half size: (R'G'B' - 0.5) * 2 and a zero fourth channel, channel
    // (dy * 2 + dx) * 4 + c; the same values at the picture's size in `base`.
    kernel void pack(texture2d<float, access::read> Y [[texture(0)]], texture2d<float, access::sample> C [[texture(1)]],
                     texture2d<half, access::write> base [[texture(2)]], device half* x [[buffer(0)]], constant Params& p [[buffer(1)]],
                     uint2 g [[thread_position_in_grid]]) {
        if (g.x >= p.w2 || g.y >= p.h2) return;
        constexpr sampler lin(filter::linear, address::clamp_to_edge);
        uint plane = p.w2 * p.h2, at = g.y * p.w2 + g.x;
        for (uint dy = 0; dy < 2; dy++) for (uint dx = 0; dx < 2; dx++) {
            uint X = 2 * g.x + dx, Yp = 2 * g.y + dy;
            uint sx = min(X, p.inW - 1), sy = min(Yp, p.inH - 1);
            float2 uv = float2((sx + 0.5) / p.inW, (sy + 0.5) / p.inH);
            half3 b = half3((to_rgb(Y.read(uint2(sx, sy)).r, C.sample(lin, uv).rg, p.codeScale) - 0.5) * 2.0);
            uint c0 = (dy * 2 + dx) * 4;
            x[(c0 + 0) * plane + at] = b.r;
            x[(c0 + 1) * plane + at] = b.g;
            x[(c0 + 2) * plane + at] = b.b;
            x[(c0 + 3) * plane + at] = 0.0h;
            if (X < p.inW && Yp < p.inH) base.write(half4(b, 1.0h), uint2(X, Yp));
        }
    }

    // PyTorch's bicubic 2x (a = -0.75, half-pixel centres): two fixed 4-tap filters, edge-clamped.
    constant float EVEN[4] = {-0.03515625, 0.26171875, 0.87890625, -0.10546875};   // inputs i-2 .. i+1
    constant float ODD[4]  = {-0.10546875, 0.87890625, 0.26171875, -0.03515625};   // inputs i-1 .. i+2

    // One thread a picture pixel: the bicubic 2x of its 2 x 2 output pixels from the 5 x 5 pixels around it (even outputs take offsets
    // -2..1 with EVEN, odd ones -1..2 with ODD), the residual added; their Y' (Deepen blacks' bend as in the processor's `prep`) and the
    // block's chroma, scaled with the bend.
    kernel void finish(texture2d<half, access::read> base [[texture(0)]], texture2d<float, access::write> outY [[texture(1)]],
                       texture2d<float, access::write> outC [[texture(2)]], device const half* res [[buffer(0)]],
                       constant Params& p [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {
        if (g.x >= p.inW || g.y >= p.inH) return;
        float3 he[5], ho[5];
        for (int j = 0; j < 5; j++) {
            uint sy = uint(clamp(int(g.y) + j - 2, 0, int(p.inH) - 1));
            float3 t[5];
            for (int i = 0; i < 5; i++) t[i] = float3(base.read(uint2(uint(clamp(int(g.x) + i - 2, 0, int(p.inW) - 1)), sy)).rgb);
            he[j] = EVEN[0] * t[0] + EVEN[1] * t[1] + EVEN[2] * t[2] + EVEN[3] * t[3];
            ho[j] = ODD[0] * t[1] + ODD[1] * t[2] + ODD[2] * t[3] + ODD[3] * t[4];
        }
        uint plane = p.w2 * p.h2;
        float3 sum = 0.0;
        float k = 0.0;
        for (uint n = 0; n < 4; n++) {
            uint dx = n & 1, dy = n >> 1;
            uint2 at = g * 2 + uint2(dx, dy);
            float3 acc = 0.0;
            for (int j = 0; j < 4; j++) acc += (dy ? ODD[j] : EVEN[j]) * (dx ? ho[j + dy] : he[j + dy]);
            uint a = (at.y >> 2) * p.w2 + (at.x >> 2), sub = (at.y & 3) * 4 + (at.x & 3);
            float3 r = float3(res[(0 * 16 + sub) * plane + a], res[(1 * 16 + sub) * plane + a], res[(2 * 16 + sub) * plane + a]);
            float3 rgb = clamp((acc + r) * 0.5 + 0.5, 0.0, 1.0);
            sum += rgb;
            float y = dot(rgb, float3(KR, 1.0 - KR - KB, KB));
            float rb = 1.0;
            if (p.lift > 0.0) {
                float t = saturate(1.0 - y / p.knee);
                rb = y > 1e-4 ? saturate((y - p.lift * t * t) / y) : 0.0;
            }
            k += rb;
            outY.write(float4(saturate(y * rb)), at);
        }
        float3 m = sum * 0.25;
        float ym = dot(m, float3(KR, 1.0 - KR - KB, KB));
        float2 c = float2((m.b - ym) / (2.0 * (1.0 - KB)), (m.r - ym) / (2.0 * (1.0 - KR)));
        outC.write(float4(c * (k * 0.25), 0, 0), g);
    }
    """

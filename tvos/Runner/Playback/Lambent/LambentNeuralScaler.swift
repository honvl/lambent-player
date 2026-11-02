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

    static func modelURL(_ network: String) -> URL? {
        guard let url = directory?.appendingPathComponent("\(network)-\(modelSize.0)x\(modelSize.1).mlmodelc"),
            FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// Both models are in the bundle.
    static var available: Bool { networks.allSatisfy { modelURL($0) != nil } }

    /// Loaded scalers by network, kept for the app's life: loading a model on the Neural Engine takes a while the first time.
    private static let loaded = OSAllocatedUnfairLock(initialState: [String: LambentNeuralScaler]())
    private static let loading = OSAllocatedUnfairLock(initialState: Set<String>())
    private static let loadQueue = DispatchQueue(label: "lambent.neural-load", qos: .utility)
    nonisolated(unsafe) static var failures: [String: String] = [:]

    /// The scaler for `network` if it has loaded; otherwise nil, and it starts loading in the background.
    static func scaler(_ network: String, device: MTLDevice) -> LambentNeuralScaler? {
        if let s = loaded.withLock({ $0[network] }) { return s }
        let start = loading.withLock { $0.insert(network).inserted }
        if start {
            loadQueue.async {
                let t = CACurrentMediaTime()
                do {
                    let s = try LambentNeuralScaler(device: device, network: network)
                    loaded.withLock { $0[network] = s }
                    NSLog("[LambentHDR] AI upscaler %@ loaded in %.0f ms", network, (CACurrentMediaTime() - t) * 1000)
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
        return loaded.withLock { $0[network] }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    let network: String
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let packPipeline: MTLComputePipelineState
    private let finishPipeline: MTLComputePipelineState
    private let model: MLModel
    private let input: MTLBuffer, output: MTLBuffer
    private let features: MLFeatureProvider
    private let options = MLPredictionOptions()
    private var base: MTLTexture?
    private var luma: MTLTexture?
    private var chroma: MTLTexture?
    /// The last picture's Neural Engine and pack milliseconds.
    private(set) var engineMs = 0.0, packMs = 0.0

    private init(device: MTLDevice, network: String) throws {
        guard let url = Self.modelURL(network) else { throw Failure("no model \(network) (tvos/scripts/copy_vsr_models.sh)") }
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
        let (w2, h2) = (Self.modelSize.0 / 2, Self.modelSize.1 / 2)
        // Input and output live in shared memory the GPU writes and reads directly.
        guard let input = device.makeBuffer(length: 16 * w2 * h2 * 2, options: .storageModeShared),
            let output = device.makeBuffer(length: 48 * w2 * h2 * 2, options: .storageModeShared)
        else { throw Failure("no buffers") }
        self.input = input
        self.output = output
        func array(_ buffer: MTLBuffer, _ channels: Int) throws -> MLMultiArray {
            try MLMultiArray(
                dataPointer: buffer.contents(), shape: [1, NSNumber(value: channels), NSNumber(value: h2), NSNumber(value: w2)],
                dataType: .float16,
                strides: [NSNumber(value: channels * h2 * w2), NSNumber(value: h2 * w2), NSNumber(value: w2), 1])
        }
        features = try MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: try array(input, 16))])
        options.outputBackings = ["residual": try array(output, 48)]
    }

    /// Takes a picture of this size.
    static func fits(_ w: Int, _ h: Int) -> Bool { w <= modelSize.0 && h <= modelSize.1 }

    private func textures(_ w: Int, _ h: Int) -> (MTLTexture, MTLTexture, MTLTexture)? {
        if let base, let luma, let chroma, base.width == w, base.height == h { return (base, luma, chroma) }
        func make(_ format: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        base = make(.rgba16Float, w, h)
        luma = make(.r16Float, 2 * w, 2 * h)
        chroma = make(.rg16Float, w, h)
        guard let base, let luma, let chroma else { return nil }
        return (base, luma, chroma)
    }

    /// Packs the picture (its Y' and CbCr planes as Metal textures, video range; `codeScale` turns a sample into a 10-bit code) and runs
    /// the network, waiting for both. Then `encodeFinish`.
    func run(inY: MTLTexture, inC: MTLTexture, codeScale: Float) throws {
        let (w, h) = (inY.width, inY.height)
        guard Self.fits(w, h), let (base, _, _) = textures(w, h) else { throw Failure("\(w)x\(h) does not fit") }
        var params = NeuralParams(
            inW: UInt32(w), inH: UInt32(h), w2: UInt32(Self.modelSize.0 / 2), h2: UInt32(Self.modelSize.1 / 2), codeScale: codeScale,
            lift: 0, knee: 0.5)
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeComputeCommandEncoder() else { throw Failure("no command buffer") }
        encoder.setComputePipelineState(packPipeline)
        encoder.setTextures([inY, inC, base], range: 0..<3)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<NeuralParams>.size, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: Self.modelSize.0 / 2, height: Self.modelSize.1 / 2, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        if let error = buffer.error { throw error }
        packMs = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
        let started = CACurrentMediaTime()
        _ = try model.prediction(from: features, options: options)
        engineMs = (CACurrentMediaTime() - started) * 1000
    }

    /// The residual onto a bicubic 2x, in `buffer`: Y' at twice the picture's size and the 2 x 2 blocks' chroma (the picture's size),
    /// as the processor's `prep` writes them, Deepen blacks' bend (`lift`, 0: none) applied.
    func encodeFinish(_ buffer: MTLCommandBuffer, lift: Float, knee: Float) -> (luma: MTLTexture, chroma: MTLTexture)? {
        guard let base, let luma, let chroma, let encoder = buffer.makeComputeCommandEncoder() else { return nil }
        var params = NeuralParams(
            inW: UInt32(base.width), inH: UInt32(base.height), w2: UInt32(Self.modelSize.0 / 2), h2: UInt32(Self.modelSize.1 / 2),
            codeScale: 0, lift: lift, knee: knee)
        encoder.setComputePipelineState(finishPipeline)
        encoder.setTextures([base, luma, chroma], range: 0..<3)
        encoder.setBuffer(output, offset: 0, index: 0)
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

    static float3 upscaled(texture2d<half, access::read> base, device const half* res, uint X, uint Yp, constant Params& p) {
        int iy = int(Yp >> 1), ix = int(X >> 1);
        int y0 = (Yp & 1) ? iy - 1 : iy - 2, x0 = (X & 1) ? ix - 1 : ix - 2;
        float3 acc = 0.0;
        for (int j = 0; j < 4; j++) {
            float wy = (Yp & 1) ? ODD[j] : EVEN[j];
            uint sy = uint(clamp(y0 + j, 0, int(p.inH) - 1));
            float3 row = 0.0;
            for (int i = 0; i < 4; i++) {
                float wx = (X & 1) ? ODD[i] : EVEN[i];
                row += wx * float3(base.read(uint2(uint(clamp(x0 + i, 0, int(p.inW) - 1)), sy)).rgb);
            }
            acc += wy * row;
        }
        uint plane = p.w2 * p.h2, at = (Yp >> 2) * p.w2 + (X >> 2), sub = (Yp & 3) * 4 + (X & 3);
        float3 r = float3(res[(0 * 16 + sub) * plane + at], res[(1 * 16 + sub) * plane + at], res[(2 * 16 + sub) * plane + at]);
        return clamp((acc + r) * 0.5 + 0.5, 0.0, 1.0);
    }

    // One thread a picture pixel: its 2 x 2 output pixels' Y' (Deepen blacks' bend as in the processor's `prep`) and their chroma,
    // scaled with the bend.
    kernel void finish(texture2d<half, access::read> base [[texture(0)]], texture2d<float, access::write> outY [[texture(1)]],
                       texture2d<float, access::write> outC [[texture(2)]], device const half* res [[buffer(0)]],
                       constant Params& p [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {
        if (g.x >= p.inW || g.y >= p.inH) return;
        float3 sum = 0.0;
        float k = 0.0;
        for (uint n = 0; n < 4; n++) {
            uint2 at = g * 2 + uint2(n & 1, n >> 1);
            float3 rgb = upscaled(base, res, at.x, at.y, p);
            sum += rgb;
            float y = dot(rgb, float3(KR, 1.0 - KR - KB, KB));
            float r = 1.0;
            if (p.lift > 0.0) {
                float t = saturate(1.0 - y / p.knee);
                r = y > 1e-4 ? saturate((y - p.lift * t * t) / y) : 0.0;
            }
            k += r;
            outY.write(float4(saturate(y * r)), at);
        }
        float3 m = sum * 0.25;
        float ym = dot(m, float3(KR, 1.0 - KR - KB, KB));
        float2 c = float2((m.b - ym) / (2.0 * (1.0 - KB)), (m.r - ym) / (2.0 * (1.0 - KR)));
        outC.write(float4(c * (k * 0.25), 0, 0), g);
    }
    """

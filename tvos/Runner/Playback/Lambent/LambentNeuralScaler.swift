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
    /// `student`: the network's Neural Engine student (`<network>-student-<size>`, 4 x 4 packing; `neural-low`'s when the network has
    /// none), and nothing else.
    static func modelURL(_ network: String, int8: Bool = preferInt8, student: Bool = false) -> URL? {
        let names = student ? ["\(network)-student", "neural-low-student"] : int8 ? ["\(network)-w8a8", network] : [network]
        for name in names {
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

    /// Both models are in the bundle (`student`: a Neural Engine student for each, or `neural-low`'s for both).
    static func available(student: Bool) -> Bool { networks.allSatisfy { modelURL($0, int8: false, student: student) != nil } }

    /// Loaded scalers by network, kept for the app's life: loading a model on the Neural Engine takes a while the first time.
    private static let loaded = OSAllocatedUnfairLock(initialState: [String: LambentNeuralScaler]())
    private static let loading = OSAllocatedUnfairLock(initialState: Set<String>())
    private static let loadQueue = DispatchQueue(label: "lambent.neural-load", qos: .utility)
    nonisolated(unsafe) static var failures: [String: String] = [:]

    /// The scaler for `network` if it has loaded; otherwise nil, and it starts loading in the background.
    static func scaler(_ network: String, student: Bool = false, device: MTLDevice) -> LambentNeuralScaler? {
        let int8 = preferInt8 && !student
        let key = network + (int8 ? " int8" : "") + (student ? " student" : "")
        if let s = loaded.withLock({ $0[key] }) { return s }
        let start = loading.withLock { $0.insert(key).inserted }
        if start {
            loadQueue.async {
                let t = CACurrentMediaTime()
                do {
                    let s = try LambentNeuralScaler(device: device, network: network, int8: int8, student: student)
                    if s.f == 4 { NSLog("[LambentHDR] AI upscaler %@: a Neural Engine student (4 x 4 packing)", network) }
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
    static func loadNow(_ network: String, student: Bool = false, device: MTLDevice) -> LambentNeuralScaler? {
        _ = scaler(network, student: student, device: device)
        loadQueue.sync {}
        return loaded.withLock { $0[network + (preferInt8 && !student ? " int8" : "") + (student ? " student" : "")] }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    let network: String
    /// The int8 (W8A8) model.
    let int8: Bool
    /// Pixels packed per side into the network's channels (2: NVIDIA's network; 4: a Neural Engine student).
    let f: Int
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let packPipeline: MTLComputePipelineState
    private let finishPipeline: MTLComputePipelineState, finishOutPipeline: MTLComputePipelineState
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

        /// `f`: pixels packed per side (2: 16 channels in, 48 out at half size; 4: 48 in, 192 out at quarter size).
        init(device: MTLDevice, f: Int) throws {
            let (w2, h2) = (LambentNeuralScaler.modelSize.0 / f, LambentNeuralScaler.modelSize.1 / f)
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
            let (inBuffer, inArray, input) = try surface(f == 2 ? 16 : 3 * f * f)
            let (outBuffer, outArray, output) = try surface(3 * 4 * f * f)
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

    private init(device: MTLDevice, network: String, int8: Bool, student: Bool) throws {
        guard let url = Self.modelURL(network, int8: int8, student: student) else {
            throw Failure("no model \(network)\(student ? " student" : "") (tvos/scripts/copy_vsr_models.sh)")
        }
        self.int8 = url.lastPathComponent.contains("-w8a8-")
        guard let queue = device.makeCommandQueue() else { throw Failure("no command queue") }
        self.device = device
        self.queue = queue
        self.network = network
        let library = try device.makeLibrary(source: neuralSource, options: nil)
        packPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "pack")!)
        finishPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "finish")!)
        finishOutPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "finish_out")!)
        let config = MLModelConfiguration()
        // The Neural Engine: the GPU stays free for decoding, the lift and the last pass.
        config.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: url, configuration: config)
        // The packing follows the model: 16 input channels, the teacher's 2 x 2; 48, a student's 4 x 4.
        let channels = model.modelDescription.inputDescriptionsByName["x"]?.multiArrayConstraint?.shape[1].intValue ?? 16
        f = channels == 48 ? 4 : 2
        slots = [try Slot(device: device, f: f), try Slot(device: device, f: f), try Slot(device: device, f: f)]
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
            inW: UInt32(w), inH: UInt32(h), gw: UInt32(Self.modelSize.0 / f), gh: UInt32(Self.modelSize.1 / f), f: UInt32(f),
            codeScale: codeScale, lift: 0, knee: 0.5)
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeComputeCommandEncoder() else { throw Failure("no command buffer") }
        encoder.setComputePipelineState(packPipeline)
        encoder.setTextures([inY, inC, base], range: 0..<3)
        encoder.setBuffer(slot.input, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<NeuralParams>.size, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: Self.modelSize.0 / f, height: Self.modelSize.1 / f, depth: 1),
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
            inW: UInt32(base.width), inH: UInt32(base.height), gw: UInt32(Self.modelSize.0 / f), gh: UInt32(Self.modelSize.1 / f),
            f: UInt32(f), codeScale: 0, lift: lift, knee: knee)
        encoder.setComputePipelineState(finishPipeline)
        encoder.setTextures([base, luma, chroma], range: 0..<3)
        encoder.setBuffer(slot.output, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<NeuralParams>.size, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: base.width, height: base.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        return (luma, chroma)
    }

    /// `encodeFinish` and the processor's last pass in one, for an output exactly twice the picture: straight into the output's P010
    /// planes (`outY` r16Unorm, `outC` rg16Unorm), PQ through the lift's table `lut` when `hdr`, else the picture's own SDR Y'CbCr.
    func encodeFinishOut(
        _ slot: Slot, _ buffer: MTLCommandBuffer, outY: MTLTexture, outC: MTLTexture, lut: MTLTexture, hdr: Bool, lift: Float, knee: Float
    ) -> Bool {
        guard let base = slot.base, let encoder = buffer.makeComputeCommandEncoder() else { return false }
        var params = NeuralParams(
            inW: UInt32(base.width), inH: UInt32(base.height), gw: UInt32(Self.modelSize.0 / f), gh: UInt32(Self.modelSize.1 / f),
            f: UInt32(f), codeScale: 0, lift: lift, knee: knee, hdr: hdr ? 1 : 0)
        encoder.setComputePipelineState(finishOutPipeline)
        encoder.setTextures([base, outY, outC, lut], range: 0..<4)
        encoder.setBuffer(slot.output, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<NeuralParams>.size, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: base.width, height: base.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        return true
    }
}

private struct NeuralParams {
    var inW: UInt32, inH: UInt32, gw: UInt32, gh: UInt32, f: UInt32
    var codeScale: Float
    var lift: Float, knee: Float
    /// `finish_out`: write PQ through the lift's table (1) or the picture's own SDR Y'CbCr (0).
    var hdr: UInt32 = 0
}

// The Mac enhancer's `pack` and `finish` (NeuralScaler.swift), BT.709 like the rest of the processor; `finish` writes Y' and chroma at
// once (one thread a picture pixel: the 2 x 2 output pixels it becomes) instead of R'G'B' for a separate resample.
private let neuralSource = """
    #include <metal_stdlib>
    using namespace metal;

    // gw x gh: the network's grid (the padded picture over f); f: pixels packed per side.
    struct Params { uint inW, inH, gw, gh, f; float codeScale; float lift; float knee; uint hdr; };

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

    // Each f x f block of the edge-padded picture as channels at the grid's size, (R'G'B' - 0.5) * 2: f = 2 (NVIDIA's network), 16
    // channels, (dy * 2 + dx) * 4 + c with a zero fourth; f = 4 (a student), 48 channels, (dy * 4 + dx) * 3 + c. The same values at the
    // picture's size in `base`.
    kernel void pack(texture2d<float, access::read> Y [[texture(0)]], texture2d<float, access::sample> C [[texture(1)]],
                     texture2d<half, access::write> base [[texture(2)]], device half* x [[buffer(0)]], constant Params& p [[buffer(1)]],
                     uint2 g [[thread_position_in_grid]]) {
        if (g.x >= p.gw || g.y >= p.gh) return;
        constexpr sampler lin(filter::linear, address::clamp_to_edge);
        uint plane = p.gw * p.gh, at = g.y * p.gw + g.x, per = p.f == 2 ? 4 : 3;
        for (uint dy = 0; dy < p.f; dy++) for (uint dx = 0; dx < p.f; dx++) {
            uint X = p.f * g.x + dx, Yp = p.f * g.y + dy;
            uint sx = min(X, p.inW - 1), sy = min(Yp, p.inH - 1);
            float2 uv = float2((sx + 0.5) / p.inW, (sy + 0.5) / p.inH);
            half3 b = half3((to_rgb(Y.read(uint2(sx, sy)).r, C.sample(lin, uv).rg, p.codeScale) - 0.5) * 2.0);
            uint c0 = (dy * p.f + dx) * per;
            x[(c0 + 0) * plane + at] = b.r;
            x[(c0 + 1) * plane + at] = b.g;
            x[(c0 + 2) * plane + at] = b.b;
            if (per == 4) x[(c0 + 3) * plane + at] = 0.0h;
            if (X < p.inW && Yp < p.inH) base.write(half4(b, 1.0h), uint2(X, Yp));
        }
    }

    // PyTorch's bicubic 2x (a = -0.75, half-pixel centres): two fixed 4-tap filters, edge-clamped.
    constant float EVEN[4] = {-0.03515625, 0.26171875, 0.87890625, -0.10546875};   // inputs i-2 .. i+1
    constant float ODD[4]  = {-0.10546875, 0.87890625, 0.26171875, -0.03515625};   // inputs i-1 .. i+2

    // One thread a picture pixel: the bicubic 2x of its 2 x 2 output pixels from the 5 x 5 pixels around it (even outputs take offsets
    // -2..1 with EVEN, odd ones -1..2 with ODD), the residual added; their Y' (Deepen blacks' bend as in the processor's `prep`) and the
    // block's chroma, scaled with the bend.
    // The picture pixel g's 2 x 2 output pixels: the bicubic 2x from the 5 x 5 pixels around it (even outputs take offsets -2..1 with
    // EVEN, odd ones -1..2 with ODD), the residual added; their Y' (Deepen blacks' bend as in the processor's `prep`) in ys, and the
    // block's chroma, scaled with the bend, returned.
    static float2 doubled(texture2d<half, access::read> base, device const half* res, constant Params& p, uint2 g, thread float* ys) {
        float3 he[5], ho[5];
        for (int j = 0; j < 5; j++) {
            uint sy = uint(clamp(int(g.y) + j - 2, 0, int(p.inH) - 1));
            float3 t[5];
            for (int i = 0; i < 5; i++) t[i] = float3(base.read(uint2(uint(clamp(int(g.x) + i - 2, 0, int(p.inW) - 1)), sy)).rgb);
            he[j] = EVEN[0] * t[0] + EVEN[1] * t[1] + EVEN[2] * t[2] + EVEN[3] * t[3];
            ho[j] = ODD[0] * t[1] + ODD[1] * t[2] + ODD[2] * t[3] + ODD[3] * t[4];
        }
        uint plane = p.gw * p.gh, r = 2 * p.f, rr = r * r;
        float3 sum = 0.0;
        float k = 0.0;
        for (uint n = 0; n < 4; n++) {
            uint dx = n & 1, dy = n >> 1;
            uint2 at = g * 2 + uint2(dx, dy);
            float3 acc = 0.0;
            for (int j = 0; j < 4; j++) acc += (dy ? ODD[j] : EVEN[j]) * (dx ? ho[j + dy] : he[j + dy]);
            // The residual pixel-shuffled by 2f: channel c * (2f)^2 + (y % 2f) * 2f + x % 2f at grid cell (x / 2f, y / 2f).
            uint a = (at.y / r) * p.gw + at.x / r, sub = (at.y % r) * r + at.x % r;
            float3 res3 = float3(res[(0 * rr + sub) * plane + a], res[(1 * rr + sub) * plane + a], res[(2 * rr + sub) * plane + a]);
            float3 rgb = clamp((acc + res3) * 0.5 + 0.5, 0.0, 1.0);
            sum += rgb;
            float y = dot(rgb, float3(KR, 1.0 - KR - KB, KB));
            float rb = 1.0;
            if (p.lift > 0.0) {
                float t = saturate(1.0 - y / p.knee);
                rb = y > 1e-4 ? saturate((y - p.lift * t * t) / y) : 0.0;
            }
            k += rb;
            ys[n] = saturate(y * rb);
        }
        float3 m = sum * 0.25;
        float ym = dot(m, float3(KR, 1.0 - KR - KB, KB));
        return float2((m.b - ym) / (2.0 * (1.0 - KB)), (m.r - ym) / (2.0 * (1.0 - KR))) * (k * 0.25);
    }

    // One thread a picture pixel: its 2 x 2 output pixels' Y' and the block's chroma, as the processor's `prep` writes them.
    kernel void finish(texture2d<half, access::read> base [[texture(0)]], texture2d<float, access::write> outY [[texture(1)]],
                       texture2d<float, access::write> outC [[texture(2)]], device const half* res [[buffer(0)]],
                       constant Params& p [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {
        if (g.x >= p.inW || g.y >= p.inH) return;
        float ys[4];
        float2 c = doubled(base, res, p, g, ys);
        for (uint n = 0; n < 4; n++) outY.write(float4(ys[n]), g * 2 + uint2(n & 1, n >> 1));
        outC.write(float4(c, 0, 0), g);
    }

    // `finish` and the processor's last pass in one, when the output is exactly twice the picture (1080p -> 2160p): straight to P010,
    // PQ through the lift's table (`hdr`, as `scale_lift` reading the doubled luma directly) or the picture's own SDR Y'CbCr (as
    // `scale_sdr`). Saves writing and reading the doubled luma.
    constexpr sampler lutSampler(coord::normalized, filter::linear, address::clamp_to_edge);

    kernel void finish_out(texture2d<half, access::read> base [[texture(0)]], texture2d<float, access::write> outY [[texture(1)]],
                           texture2d<float, access::write> outC [[texture(2)]], texture3d<float> lut [[texture(3)]],
                           device const half* res [[buffer(0)]], constant Params& p [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {
        if (g.x >= p.inW || g.y >= p.inH) return;
        float ys[4];
        float2 c = doubled(base, res, p, g, ys);
        if (p.hdr == 0) {
            for (uint n = 0; n < 4; n++) outY.write(float4((ys[n] * 876.0 + 64.0) * 64.0 / 65535.0), g * 2 + uint2(n & 1, n >> 1));
            outC.write(float4((clamp(c, -0.5, 0.5) * 896.0 + 512.0) * 64.0 / 65535.0, 0, 0), g);
            return;
        }
        float2 sum = 0;
        for (uint n = 0; n < 4; n++) {
            float yy = ys[n];
            float3 rgb = clamp(float3(yy + 1.5748 * c.y, yy - 0.187324 * c.x - 0.468124 * c.y, yy + 1.8556 * c.x), 0.0, 1.0);
            float3 e = lut.sample(lutSampler, rgb * (64.0 / 65.0) + 0.5 / 65.0).rgb;
            float yp = dot(e, float3(0.2627, 0.6780, 0.0593));
            sum += float2((e.b - yp) / 1.8814, (e.r - yp) / 1.4746);
            outY.write(float4((yp * 876.0 + 64.0) * 64.0 / 65535.0), g * 2 + uint2(n & 1, n >> 1));
        }
        outC.write(float4((sum * 0.25 * 896.0 + 512.0) * 64.0 / 65535.0, 0, 0), g);
    }
    """

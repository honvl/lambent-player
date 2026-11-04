import CoreVideo
import Foundation
import Metal
import QuartzCore

/// The GPU work, off the main thread: 8- or 10-bit 4:2:0 BT.709 in, P010 BT.2020 PQ out (or, with `hdr` off, P010 with the picture's own
/// SDR colours: upscaling only).
///
/// A picture as big as its place on the screen gets one Metal kernel: Deepen blacks' bend and the lift. A smaller one (a 1080p title on
/// a 4K screen) is upscaled here rather than by tvOS's own scaler (bilinear in the simulator, docs/SHADER_UPSCALE.md in Lambent): a
/// pass at the picture's size bends the blacks and writes Y' and chroma, a luma prescaler doubles Y' (FSRCNNX 8-0-4-1 on an Apple GPU of
/// family 10 or later, an A19; RAVU-lite before it), and a last pass at the screen's size scales (Catmull-Rom), lifts and writes PQ.
/// Above them all, on an A15 or later with the models in the bundle, the AI upscaler (LambentNeuralScaler.swift: NVIDIA's VSR low
/// network on the Neural Engine) doubles the whole picture in place of the picture pass and the prescaler; at most 30 fps before an A19.
/// When a scaler cannot keep up with the film (pictures taking longer than a frame, start to finish), the next one down takes over:
/// FSRCNNX, RAVU-lite, Catmull-Rom, then none (tvOS scales). Measured on an A16 (docs/CLIENT_HDR.md in Lambent), 1080p -> 4K with
/// the lift, back to back: Catmull-Rom 4.1 ms, RAVU-lite 8.4 ms, FSRCNNX 34 ms. GPU time alone does not decide: an A-series GPU lowers
/// its clock when it has room, so a scaler's GPU time stretches toward the frame (RAVU-lite read 12 to 25 ms at 24 fps while keeping up).
final class LambentLiftProcessor: @unchecked Sendable {
    struct Report {
        var frames = 0, late = 0
        var meanMs = 0.0, p95Ms = 0.0
        var floor: Float = -1, lift: Float = 0
        var format = ""
        var scaler = ""
        /// The AI upscaler's Neural Engine time and its pack's wall time (mean, ms), 0 when it did not run.
        var engineMs = 0.0, packWallMs = 0.0
    }

    /// How the picture reaches the screen's size, best first.
    enum Scaler: Equatable, CustomStringConvertible {
        /// The AI upscaler; its network follows the title's bits per pixel (`LambentNeuralScaler.network`). `fast`: its Neural Engine
        /// student (4 x 4 packing; on an A16 6 ms against 13 ms, about 2 VMAF NEG lower), for frame rates the network does not keep up with.
        case neural(fast: Bool)
        case prescaler(String)
        case catmullRom
        case none

        var description: String {
            switch self {
            case .neural(let fast): return fast ? "AI upscaler (fast)" : "AI upscaler"
            case .prescaler(let name): return name
            case .catmullRom: return "catmull-rom"
            case .none: return "none (tvOS scales)"
            }
        }

        var isNeural: Bool { if case .neural = self { return true } else { return false } }
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let prepPipeline: MTLComputePipelineState
    private let scalePipeline: MTLComputePipelineState
    private let scaleSDRPipeline: MTLComputePipelineState
    private let exactPipeline: MTLComputePipelineState, exactScalePipeline: MTLComputePipelineState
    /// The lift baked into a 65^3 table over R'G'B' (Deepen blacks' bend comes before it, the curve and saturation are fixed): on an A16
    /// one trilinear read a pixel instead of `expand`'s powers.
    private var lut: MTLTexture!
    /// `expand` itself instead of the table (a bench, to compare).
    var exactLift = false
    private var prescalers: [String: LambentPrescaler] = [:]
    /// The scalers to try, best first; the first one stays until its GPU time does not fit.
    private(set) var ladder: [Scaler]
    private var step = 0
    private var stepPictures = 0
    private var stepLate = 0
    /// Where the picture is shown, in screen pixels; nil: at its own size.
    var outputSize: (Int, Int)?
    /// The film's rate: a picture has one frame of it, start to finish.
    var frameRate: Double = 24
    /// Off: upscaling only, the picture's own SDR colours out (HDR on this TV is off).
    var hdr = true
    /// The title's video bitrate (bits a second, 0: unknown), for the AI upscaler's network.
    var sourceBitrate: Int64 = 0
    /// `prepare` runs on its own queue for every picture (the player): `process` never runs the network itself.
    var pipelined = false
    /// The ladder was set by `force` (a bench): the AI upscaler runs at any frame rate.
    private var forced = false
    /// The AI upscaler runs at any scale, under `LambentClientUpscale.neuralMinimumScale` too (a bench, to compare).
    var neuralAnyScale = false
    private var engineMs: [Double] = []
    private var neuralInt8 = false
    private var packWallMs: [Double] = []
    private var lumaTex: MTLTexture?
    private var chromaTex: MTLTexture?
    private var outPool: CVPixelBufferPool?
    private var outPoolSize = (0, 0)
    private var cache: CVMetalTextureCache?
    /// `prepare`'s own, as it runs on another queue.
    private var prepareCache: CVMetalTextureCache?
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private let curve: [Float]
    private let blacks = LambentBlackFloor()
    private var deepen = false
    private var frameIndex = 0
    private var gpuMs: [Double] = []
    private var late = 0
    private var format = ""

    init?() {
        func make(_ library: MTLLibrary, _ name: String, exact: Bool) -> MTLComputePipelineState? {
            let constants = MTLFunctionConstantValues()
            var flag = exact
            constants.setConstantValue(&flag, type: .bool, index: 0)
            return (try? library.makeFunction(name: name, constantValues: constants)).flatMap { try? library.device.makeComputePipelineState(function: $0) }
        }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
            let library = try? device.makeLibrary(source: liftSource, options: nil),
            let pipeline = make(library, "lift", exact: false), let exactPipeline = make(library, "lift", exact: true),
            let prep = make(library, "prep", exact: false),
            let scale = make(library, "scale_lift", exact: false), let exactScale = make(library, "scale_lift", exact: true),
            let scaleSDR = make(library, "scale_sdr", exact: false), let bake = make(library, "bake_lut", exact: true)
        else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.exactPipeline = exactPipeline
        prepPipeline = prep
        scalePipeline = scale
        exactScalePipeline = exactScale
        scaleSDRPipeline = scaleSDR
        // Picked by the GPU's Apple family, the same on the Apple TV and the iPad (LambentClientUpscale.ladder says why).
        let ladder = LambentClientUpscale.ladder(
            supports: { device.supportsFamily($0) }, neuralModels: { LambentNeuralScaler.available(student: $0) })
        var loaded: [String: LambentPrescaler] = [:]
        for case .prescaler(let name) in ladder {
            if let p = LambentPrescaler(device: device, name: name) { loaded[name] = p }
        }
        prescalers = loaded
        self.ladder = ladder.filter { if case .prescaler(let n) = $0 { return loaded[n] != nil } else { return true } }
        if case .neural(let fast) = self.ladder.first { _ = LambentNeuralScaler.scaler("neural-low", student: fast, device: device) }
        // A TV's stream (docs/HDR_FALLBACK.md in Lambent): 1000-nit peak, contrast 100, middle grey 50.
        curve = LambentToneParams(peak: 1000).table
        let lutDescriptor = MTLTextureDescriptor()
        lutDescriptor.textureType = .type3D
        lutDescriptor.pixelFormat = .rgba16Float
        (lutDescriptor.width, lutDescriptor.height, lutDescriptor.depth) = (65, 65, 65)
        lutDescriptor.usage = [.shaderRead, .shaderWrite]
        lutDescriptor.storageMode = .private
        guard let lut = device.makeTexture(descriptor: lutDescriptor), let buffer = queue.makeCommandBuffer(),
            let encoder = buffer.makeComputeCommandEncoder()
        else { return nil }
        var params = LiftParams(codeScale: 0, saturation: 1, lift: 0, knee: 0.5)
        encoder.setComputePipelineState(bake)
        encoder.setTexture(lut, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<LiftParams>.size, index: 0)
        curve.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 1) }
        encoder.dispatchThreads(MTLSize(width: 65, height: 65, depth: 65), threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 4))
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        self.lut = lut
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &prepareCache)
    }

    /// Before the first frame of a session (nothing is queued yet).
    func reset(deepen: Bool) {
        self.deepen = deepen
        blacks.reset()
        frameIndex = 0
        step = 0
        stepPictures = 0
        stepLate = 0
        network = nil
    }

    /// Overrides the ladder (a bench, or a test): the scaler named, alone.
    func force(_ scaler: Scaler) { force(ladder: [scaler]) }

    /// Overrides the ladder (a bench): these scalers, best first, stepping down as usual.
    func force(ladder: [Scaler]) {
        for case .prescaler(let name) in ladder where prescalers[name] == nil {
            prescalers[name] = LambentPrescaler(device: device, name: name)
        }
        self.ladder = ladder.filter {
            switch $0 {
            case .prescaler(let n): return prescalers[n] != nil
            case .neural(let fast): return LambentNeuralScaler.available(student: fast)
            default: return true
            }
        }
        forced = true
        step = 0
        stepPictures = 0
        stepLate = 0
    }

    var scaler: Scaler { ladder[min(step, ladder.count - 1)] }

    /// Steps past the AI upscaler for this title: its network was trained on SDR video, and an iPad may be upscaling the PC's HDR10.
    func skipNeural() {
        while scaler.isNeural, step < ladder.count - 1 { step += 1 }
        stepPictures = 0
        stepLate = 0
    }

    /// A picture of this size is upscaled here (rather than shown at its own size, tvOS scaling it).
    func scales(_ w: Int, _ h: Int) -> Bool {
        guard let (ow, oh) = outputSize else { return false }
        return scaler != .none && ow > w * 6 / 5 && oh > h * 6 / 5
    }

    /// The AI upscaler's network for the title, once its first picture has been seen.
    private(set) var network: String?

    /// Every 96 pictures with one scaler: when more than 5 of them took longer than a frame, the next one down. The first second and a
    /// half after a start or a change (at least 24 pictures) is not counted: the GPU's clock and the pools settle (on an A16 the AI
    /// upscaler's student showed 37.6 fps in the first seconds of a 60 fps title, then 58-60). The HDR lift is never dropped to keep a scaler: that would switch
    /// the TV out of HDR10 mid-title.
    private func checkBudget(late wasLate: Bool) {
        let grace = max(24, Int(frameRate * 1.5))
        stepPictures += 1
        guard stepPictures > grace else { return }
        if wasLate { stepLate += 1 }
        guard stepPictures >= grace + 96 else { return }
        if stepLate > 5, step < ladder.count - 1 {
            NSLog("[LambentHDR] %@: %d of 96 pictures over a frame at %.3f fps: %@", "\(scaler)", stepLate, frameRate, "\(ladder[step + 1])")
            step += 1
            stepPictures = 0
        } else {
            stepPictures = grace
        }
        stepLate = 0
    }

    /// A picture through the AI upscaler's network, ready for its finish: `prepare`'s result.
    struct NeuralPrepared: @unchecked Sendable {
        let scaler: LambentNeuralScaler
        let slot: LambentNeuralScaler.Slot
    }

    /// The AI upscaler's first two stages in one: `pack`, then `infer`.
    func prepare(_ picture: CVPixelBuffer) -> NeuralPrepared? {
        guard let packed = pack(picture) else { return nil }
        return infer(packed)
    }

    /// The network's stage (its own queue): `pack`'s picture through the network on the Neural Engine, waited for; nil when it fails.
    func infer(_ packed: NeuralPrepared) -> NeuralPrepared? {
        (try? packed.scaler.infer(packed.slot)) != nil ? packed : nil
    }

    /// The first stage of a picture, on its own queue: when the AI upscaler is the scaler, the picture packed for the network on the GPU
    /// (waited for); nil otherwise, or while the model loads. Then `infer` on another queue, and `process` finishes it on the GPU. The
    /// player runs the three a picture apart (pack N + 2, network N + 1, finish N), at most three pictures in flight (the network has
    /// three slots), so the Neural Engine never waits for a pack. `process` alone does all three, one after the other.
    func pack(_ picture: CVPixelBuffer) -> NeuralPrepared? {
        let w = CVPixelBufferGetWidth(picture), h = CVPixelBufferGetHeight(picture)
        guard case .neural(let fast) = scaler, scales(w, h), LambentNeuralScaler.fits(w, h),
            neuralAnyScale || LambentClientUpscale.neuralPays(picture: (w, h), output: outputSize ?? (w, h))
        else { return nil }
        if network == nil {
            let net = LambentNeuralScaler.network(bitrate: sourceBitrate, width: w, height: h, frameRate: frameRate)
            network = net
            NSLog("[LambentHDR] AI upscaler network %@ (%lld bit/s, %dx%d at %.3f fps)", net, sourceBitrate, w, h, frameRate)
        }
        guard let net = network, let neural = LambentNeuralScaler.scaler(net, student: fast, device: device) else { return nil }
        let tenBit = CVPixelBufferGetPixelFormatType(picture) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let formats: (MTLPixelFormat, MTLPixelFormat) = tenBit ? (.r16Unorm, .rg16Unorm) : (.r8Unorm, .rg8Unorm)
        guard let a = texture(picture, 0, formats.0, prepareCache), let b = texture(picture, 1, formats.1, prepareCache),
            let inY = CVMetalTextureGetTexture(a), let inC = CVMetalTextureGetTexture(b),
            let slot = try? neural.pack(inY: inY, inC: inC, codeScale: tenBit ? 65535.0 / 64.0 : 1020.0)
        else { return nil }
        withExtendedLifetime((a, b)) {}
        return NeuralPrepared(scaler: neural, slot: slot)
    }

    func process(_ picture: CVPixelBuffer, deadline: CFTimeInterval, prepared: NeuralPrepared? = nil) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(picture), h = CVPixelBufferGetHeight(picture)
        let pixelFormat = CVPixelBufferGetPixelFormatType(picture)
        let tenBit = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        format = "\(w)x\(h) \(tenBit ? "10" : "8")-bit"
        if deepen, frameIndex % 4 == 0 {
            blacks.measure(picture, tenBit: tenBit, at: CACurrentMediaTime())
        }
        frameIndex += 1
        if let (ow, oh) = outputSize, scales(w, h) {
            return scale(picture, tenBit: tenBit, from: (w, h), to: (ow & ~1, oh & ~1), deadline: deadline, prepared: prepared)
        }
        // Upscaling only, and the ladder has stepped down to none: the picture as it is.
        if !hdr { return picture }
        if pool == nil || poolSize != (w, h) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            pool = nil
            CVPixelBufferPoolCreate(
                nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary,
                attrs as CFDictionary, &pool)
            poolSize = (w, h)
        }
        var made: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let out = made
        else { return nil }
        CVBufferSetAttachment(out, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferMasteringDisplayColorVolumeKey, Self.masteringDisplay as CFData, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferContentLightLevelInfoKey, Self.contentLightLevel as CFData, .shouldPropagate)

        let inFormats: (MTLPixelFormat, MTLPixelFormat) = tenBit ? (.r16Unorm, .rg16Unorm) : (.r8Unorm, .rg8Unorm)
        guard let a = texture(picture, 0, inFormats.0), let b = texture(picture, 1, inFormats.1),
            let c = texture(out, 0, .r16Unorm), let d = texture(out, 1, .rg16Unorm),
            let inY = CVMetalTextureGetTexture(a), let inC = CVMetalTextureGetTexture(b),
            let outY = CVMetalTextureGetTexture(c), let outC = CVMetalTextureGetTexture(d),
            let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeComputeCommandEncoder()
        else { return nil }
        // Normalised sample to a 10-bit code: P010 keeps the code in the top 10 of 16 bits; 8-bit codes are a quarter of 10-bit ones.
        var params = LiftParams(codeScale: tenBit ? 65535.0 / 64.0 : 1020.0, saturation: 1, lift: deepen ? blacks.lift : 0, knee: 0.5)
        encoder.setComputePipelineState(exactLift ? exactPipeline : pipeline)
        encoder.setTextures([inY, inC, outY, outC, lut], range: 0..<5)
        encoder.setBytes(&params, length: MemoryLayout<LiftParams>.size, index: 0)
        curve.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 1) }
        encoder.dispatchThreads(
            MTLSize(width: outC.width, height: outC.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        withExtendedLifetime((a, b, c, d)) {}
        guard buffer.error == nil else { return nil }
        gpuMs.append((buffer.gpuEndTime - buffer.gpuStartTime) * 1000)
        if CACurrentMediaTime() > deadline { late += 1 }
        return out
    }

    /// The picture pass, the prescaler and the scale-and-lift pass, in one command buffer.
    private func scale(
        _ picture: CVPixelBuffer, tenBit: Bool, from src: (Int, Int), to dst: (Int, Int), deadline: CFTimeInterval,
        prepared: NeuralPrepared?
    ) -> CVPixelBuffer? {
        let started = CACurrentMediaTime()
        format = "\(src.0)x\(src.1) \(tenBit ? "10" : "8")-bit -> \(dst.0)x\(dst.1)"
        if scaler == .neural(fast: false), !forced, frameRate > 30.5, !device.supportsFamily(.apple10), step < ladder.count - 1 {
            NSLog("[LambentHDR] AI upscaler: %.3f fps is over 30 on this chip: %@", frameRate, "\(ladder[step + 1])")
            step += 1
            stepPictures = 0
        }
        if scaler.isNeural, !neuralAnyScale, !LambentClientUpscale.neuralPays(picture: src, output: dst) {
            NSLog("[LambentHDR] AI upscaler: %dx%d -> %dx%d is under %.1fx: the shaders", src.0, src.1, dst.0, dst.1, LambentClientUpscale.neuralMinimumScale)
            skipNeural()
        }
        if outPool == nil || outPoolSize != dst {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: dst.0, kCVPixelBufferHeightKey as String: dst.1,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            outPool = nil
            CVPixelBufferPoolCreate(
                nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary, attrs as CFDictionary, &outPool)
            outPoolSize = dst
        }
        if lumaTex?.width != src.0 || lumaTex?.height != src.1 {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: src.0, height: src.1, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            lumaTex = device.makeTexture(descriptor: d)
            let c = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float, width: (src.0 + 1) / 2, height: (src.1 + 1) / 2, mipmapped: false)
            c.usage = [.shaderRead, .shaderWrite]
            c.storageMode = .private
            chromaTex = device.makeTexture(descriptor: c)
        }
        var made: CVPixelBuffer?
        guard let outPool, CVPixelBufferPoolCreatePixelBuffer(nil, outPool, &made) == kCVReturnSuccess, let out = made,
            let lumaTex, let chromaTex
        else { return nil }
        if hdr { attachHDR10(out) } else { CVBufferPropagateAttachments(picture, out) }
        let inFormats: (MTLPixelFormat, MTLPixelFormat) = tenBit ? (.r16Unorm, .rg16Unorm) : (.r8Unorm, .rg8Unorm)
        guard let a = texture(picture, 0, inFormats.0), let b = texture(picture, 1, inFormats.1),
            let c = texture(out, 0, .r16Unorm), let d = texture(out, 1, .rg16Unorm),
            let inY = CVMetalTextureGetTexture(a), let inC = CVMetalTextureGetTexture(b),
            let outY = CVMetalTextureGetTexture(c), let outC = CVMetalTextureGetTexture(d),
            let buffer = queue.makeCommandBuffer()
        else { return nil }
        var params = LiftParams(codeScale: tenBit ? 65535.0 / 64.0 : 1020.0, saturation: 1, lift: deepen ? blacks.lift : 0, knee: 0.5)
        var luma: MTLTexture = lumaTex
        var chroma: MTLTexture = chromaTex
        var packMs = 0.0
        var fused = false
        var used = scaler
        if case .neural = used {
            let net = network ?? LambentNeuralScaler.network(bitrate: sourceBitrate, width: src.0, height: src.1, frameRate: frameRate)
            if let ready = prepared ?? (pipelined ? nil : prepare(picture)), ready.scaler.network == net, used == .neural(fast: ready.scaler.f == 4) {
                // Exactly twice the picture (1080p -> 2160p): the finish and the last pass in one kernel, straight to the output.
                if dst == (2 * src.0, 2 * src.1), !exactLift {
                    fused = ready.scaler.encodeFinishOut(
                        ready.slot, buffer, outY: outY, outC: outC, lut: lut, hdr: hdr, lift: params.lift, knee: params.knee)
                }
                if !fused, let (l, c) = ready.scaler.encodeFinish(ready.slot, buffer, lift: params.lift, knee: params.knee) { (luma, chroma) = (l, c) }
                packMs = ready.slot.packMs
                neuralInt8 = ready.scaler.int8
                engineMs.append(ready.slot.engineMs)
                packWallMs.append(ready.slot.packWallMs)
            } else {
                // Still loading (or it cannot take this picture): the next scaler down, uncounted.
                used = ladder.count > step + 1 ? ladder[step + 1] : .catmullRom
            }
        }
        if !used.isNeural {
            guard let encoder = buffer.makeComputeCommandEncoder() else { return nil }
            encoder.setComputePipelineState(prepPipeline)
            encoder.setTextures([inY, inC, lumaTex, chromaTex], range: 0..<4)
            encoder.setBytes(&params, length: MemoryLayout<LiftParams>.size, index: 0)
            encoder.dispatchThreads(
                MTLSize(width: chromaTex.width, height: chromaTex.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
        }
        if case .prescaler(let name) = used, let prescaler = prescalers[name] {
            luma = prescaler.encode(buffer, luma: lumaTex, output: dst)
        }
        if !fused {
            guard let final = buffer.makeComputeCommandEncoder() else { return nil }
            final.setComputePipelineState(hdr ? (exactLift ? exactScalePipeline : scalePipeline) : scaleSDRPipeline)
            final.setTextures([luma, chroma, outY, outC, lut], range: 0..<5)
            final.setBytes(&params, length: MemoryLayout<LiftParams>.size, index: 0)
            curve.withUnsafeBytes { final.setBytes($0.baseAddress!, length: $0.count, index: 1) }
            final.dispatchThreads(
                MTLSize(width: outC.width, height: outC.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            final.endEncoding()
        }
        buffer.commit()
        buffer.waitUntilCompleted()
        withExtendedLifetime((a, b, c, d)) {}
        guard buffer.error == nil else { return nil }
        gpuMs.append((buffer.gpuEndTime - buffer.gpuStartTime) * 1000 + packMs)
        let now = CACurrentMediaTime()
        if now > deadline { late += 1 }
        // Late: the picture's slowest stage took longer than a frame. Run one after the other (`prepared` nil), that is the whole picture;
        // in the player's three stages, the pack, the network or this GPU stage, each a picture apart.
        var slowest = now - started
        if let prepared { slowest = max(slowest, prepared.slot.packWallMs / 1000, prepared.slot.engineMs / 1000) }
        if used == scaler { checkBudget(late: slowest > 1 / max(frameRate, 1)) }
        return out
    }

    private func attachHDR10(_ out: CVPixelBuffer) {
        CVBufferSetAttachment(out, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferMasteringDisplayColorVolumeKey, Self.masteringDisplay as CFData, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferContentLightLevelInfoKey, Self.contentLightLevel as CFData, .shouldPropagate)
    }

    func takeReport() -> Report {
        defer { gpuMs.removeAll(keepingCapacity: true); engineMs.removeAll(keepingCapacity: true); late = 0 }
        var r = Report(
            frames: gpuMs.count, late: late, floor: blacks.floor, lift: blacks.lift, format: format,
            scaler: scaler.isNeural ? "\(scaler) (\(network ?? "?")\(neuralInt8 ? ", int8" : ""))" : "\(scaler)")
        if !engineMs.isEmpty { r.engineMs = engineMs.reduce(0, +) / Double(engineMs.count) }
        if !packWallMs.isEmpty { r.packWallMs = packWallMs.reduce(0, +) / Double(packWallMs.count) }
        packWallMs.removeAll(keepingCapacity: true)
        if !gpuMs.isEmpty {
            let sorted = gpuMs.sorted()
            r.meanMs = sorted.reduce(0, +) / Double(sorted.count)
            r.p95Ms = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        }
        return r
    }

    private func texture(_ buffer: CVPixelBuffer, _ plane: Int, _ format: MTLPixelFormat, _ from: CVMetalTextureCache? = nil) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, from ?? cache!, buffer, nil, format, CVPixelBufferGetWidthOfPlane(buffer, plane),
            CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &texture)
        return texture
    }

    /// SMPTE ST 2086 as CoreVideo takes it (the `mdcv` box): BT.2020 primaries G, B, R and D65 in 0.00002 units, then
    /// max and min luminance in 0.0001 nits, all big-endian. 1000 nits peak, 0.005 black, as the PC's HDR10 streams carry.
    static let masteringDisplay: Data = {
        var d = Data()
        func u16(_ v: Int) { d.append(contentsOf: [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
        func u32(_ v: Int) { d.append(contentsOf: [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
        for (x, y) in [(0.170, 0.797), (0.131, 0.046), (0.708, 0.292), (0.3127, 0.3290)] {
            u16(Int((x * 50000).rounded()))
            u16(Int((y * 50000).rounded()))
        }
        u32(1000 * 10000)
        u32(50)
        return d
    }()

    /// CTA-861.3 MaxCLL, MaxFALL (the `clli` box), big-endian nits.
    static let contentLightLevel = Data([0x03, 0xE8, 0x01, 0x90])
}

struct LiftParams {
    var codeScale: Float
    var saturation: Float
    var lift: Float
    var knee: Float
}

/// Deepen blacks' measurement, as Lambent's Mac enhancer does it (DeepenBlacks.swift): the 1st percentile of luma over the middle 60%
/// of the picture on a 256 x 144 grid, followed over 8 s so the picture never pumps, bent so the floor lands near black.
final class LambentBlackFloor {
    private static let noShadows: Float = 0.15, floorSeconds = 8.0
    private static let floorMost: Float = 0.12, blackLands: Float = 0.016, knee: Float = 0.5
    private static let gridW = 256, gridH = 144, measuredPart = 0.6, bins = 256

    private(set) var floor: Float = -1
    private(set) var lift: Float = 0
    private var floorTime = 0.0

    func reset() {
        floor = -1
        lift = 0
        floorTime = 0
    }

    func measure(_ picture: CVPixelBuffer, tenBit: Bool, at time: Double) {
        CVPixelBufferLockBaseAddress(picture, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(picture, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(picture, 0) else { return }
        let w = CVPixelBufferGetWidthOfPlane(picture, 0), h = CVPixelBufferGetHeightOfPlane(picture, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(picture, 0)
        var bins = [Int](repeating: 0, count: Self.bins)
        let x0 = Double(w) * (1 - Self.measuredPart) / 2, y0 = Double(h) * (1 - Self.measuredPart) / 2
        let dx = Double(w) * Self.measuredPart / Double(Self.gridW), dy = Double(h) * Self.measuredPart / Double(Self.gridH)
        for j in 0..<Self.gridH {
            let row = base + min(Int(y0 + Double(j) * dy), h - 1) * rowBytes
            for i in 0..<Self.gridW {
                let x = min(Int(x0 + Double(i) * dx), w - 1)
                let code = tenBit
                    ? Float(row.assumingMemoryBound(to: UInt16.self)[x] >> 6)
                    : Float(row.assumingMemoryBound(to: UInt8.self)[x]) * 4
                let y = (code - 64) / 876
                bins[min(Int(max(y, 0) * 1024), Self.bins - 1)] += 1
            }
        }
        let want = (Self.gridW * Self.gridH + 99) / 100
        var sum = 0, bin = 0
        while bin < Self.bins - 1 {
            sum += bins[bin]
            if sum >= want { break }
            bin += 1
        }
        let p1 = (Float(bin) + 0.5) / 1024
        guard bin < Self.bins - 1, p1 < Self.noShadows else { return }
        if floor < 0 {
            floor = p1
        } else {
            let dt = min(max(time - floorTime, 0), 1)
            floor += (p1 - floor) * Float(min(1, dt / Self.floorSeconds))
        }
        floorTime = time
        let f = min(floor, Self.floorMost)
        let t = 1 - f / Self.knee
        lift = f > Self.blackLands ? (f - Self.blackLands) / (t * t) : 0
    }
}

/// The stream's curve: PQ at 65 SDR code values, from Lambent's TrueHDR tables (InverseToneMap.swift `ToneParams.table`).
struct LambentToneParams {
    var peak: Float = 1000
    var contrast: Float = 100
    var middleGrey: Float = 50

    var blend: Float { log(peak / 406) / log(1000 / 406) }

    var table: [Float] {
        typealias T = LambentTrueHDRTables
        func lerp(_ a: [Float], _ b: [Float], _ t: Float) -> [Float] { zip(a, b).map { $0 + ($1 - $0) * t } }
        func scaled(_ a: [Float], _ t: Float) -> [Float] { a.map { $0 * t } }
        let zero = [Float](repeating: 0, count: T.base406.count)
        var curve = lerp(T.base406, T.base1000, blend)
        let con: [Float]
        switch contrast {
        case ..<50: con = lerp(T.con0, T.con50, contrast / 50)
        case ..<100: con = lerp(T.con50, zero, (contrast - 50) / 50)
        case ..<150: con = lerp(zero, T.con150, (contrast - 100) / 50)
        default: con = lerp(T.con150, T.con200, (contrast - 150) / 50)
        }
        let g = log2(middleGrey / 50)
        let mid100 = lerp(T.mid100, T.mid100At1000, min(max(blend, 0), 1))
        let mid: [Float]
        if g >= 0 {
            mid = scaled(mid100, g)
        } else if g >= log2(Float(25) / 50) {
            mid = scaled(T.mid25, g / log2(Float(25) / 50))
        } else {
            mid = lerp(T.mid25, T.mid10, (g - log2(Float(25) / 50)) / (log2(Float(10) / 50) - log2(Float(25) / 50)))
        }
        for i in curve.indices { curve[i] = i == 0 ? 0 : min(max(curve[i] + con[i] + mid[i], 0), 1) }
        for i in curve.indices.dropFirst() { curve[i] = max(curve[i], curve[i - 1]) }
        return curve
    }
}

// Lambent's InverseToneMap.swift `itm` with DeepenBlacks.swift's bend folded in: per 2 x 2 block, each Y' bent below the knee and
// the block's chroma scaled by the mean ratio, then R'G'B' -> BT.1886 linear -> the curve on luminance (RGB scaled with it) ->
// BT.2020 -> PQ -> Y'CbCr BT.2020 video range.
private let liftSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params { float codeScale; float saturation; float lift; float knee; };

    inline float3 pq(float3 nits) {
        const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
        float3 l = pow(clamp(nits / 10000.0, 0.0, 1.0), m1);
        return pow((c1 + c2 * l) / (1.0 + c3 * l), m2);
    }

    inline float pq_nits(float e) {
        const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
        float p = pow(clamp(e, 0.0, 1.0), 1.0 / m2);
        return 10000.0 * pow(max(p - c1, 0.0) / (c2 - c3 * p), 1.0 / m1);
    }

    inline float3 expand(float3 rgb, constant Params& p, constant float* curve) {
        float3 lin = pow(rgb, 2.4);
        float y = dot(lin, float3(0.2126, 0.7152, 0.0722));
        float x = pow(y, 1.0 / 2.4) * 64.0;
        uint i = min(uint(x), 63u);
        float nits = pq_nits(mix(curve[i], curve[i + 1], x - float(i)));
        float3 out = lin * (y > 1e-7 ? nits / y : 0.0);
        float yo = dot(out, float3(0.2126, 0.7152, 0.0722));
        out = max(yo + (out - yo) * (0.985 * p.saturation), 0.0);
        const float3x3 to2020 = float3x3(float3(0.6274, 0.0691, 0.0164), float3(0.3293, 0.9195, 0.0880), float3(0.0433, 0.0114, 0.8956));
        return pq(to2020 * out);
    }

    // The lift as a 65 x 65 x 65 table over R'G'B' (`bake_lut`), read with the hardware's trilinear filter: one texture read a pixel instead
    // of `expand`'s powers. `exact` (a function constant) takes `expand` itself (a bench, to compare).
    constant bool exact [[function_constant(0)]];
    constexpr sampler lutSampler(coord::normalized, filter::linear, address::clamp_to_edge);

    inline float3 lifted(float3 rgb, constant Params& p, constant float* curve, texture3d<float> lut) {
        if (exact) return expand(rgb, p, curve);
        return lut.sample(lutSampler, rgb * (64.0 / 65.0) + 0.5 / 65.0).rgb;
    }

    kernel void bake_lut(texture3d<float, access::write> lut [[texture(0)]], constant Params& p [[buffer(0)]],
                         constant float* curve [[buffer(1)]], uint3 gid [[thread_position_in_grid]]) {
        if (any(gid >= 65)) return;
        lut.write(float4(expand(float3(gid) / 64.0, p, curve), 1.0), gid);
    }

    kernel void lift(texture2d<float> inY [[texture(0)]], texture2d<float> inC [[texture(1)]],
                     texture2d<float, access::write> outY [[texture(2)]], texture2d<float, access::write> outC [[texture(3)]],
                     texture3d<float> lut [[texture(4)]],
                     constant Params& p [[buffer(0)]], constant float* curve [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= outC.get_width() || gid.y >= outC.get_height()) return;
        float ys[4];
        float k = 0;
        for (uint n = 0; n < 4; n++) {
            uint2 at = min(gid * 2 + uint2(n & 1, n >> 1), uint2(inY.get_width() - 1, inY.get_height() - 1));
            float y = (inY.read(at).r * p.codeScale - 64.0) / 876.0;
            float r = 1.0;
            if (p.lift > 0.0) {
                float t = saturate(1.0 - y / p.knee);
                r = y > 1e-4 ? saturate((y - p.lift * t * t) / y) : 0.0;
            }
            ys[n] = saturate(y * r);
            k += r;
        }
        float2 c = (inC.read(gid).rg * p.codeScale - 512.0) / 896.0 * (k * 0.25);
        float2 sum = 0;
        for (uint n = 0; n < 4; n++) {
            float yy = ys[n];
            float3 rgb = clamp(float3(yy + 1.5748 * c.y, yy - 0.187324 * c.x - 0.468124 * c.y, yy + 1.8556 * c.x), 0.0, 1.0);
            float3 e = lifted(rgb, p, curve, lut);
            float yp = dot(e, float3(0.2627, 0.6780, 0.0593));
            sum += float2((e.b - yp) / 1.8814, (e.r - yp) / 1.4746);
            outY.write(float4((yp * 876.0 + 64.0) * 64.0 / 65535.0), gid * 2 + uint2(n & 1, n >> 1));
        }
        outC.write(float4((sum * 0.25 * 896.0 + 512.0) * 64.0 / 65535.0, 0, 0), gid);
    }

    // The picture pass of the upscaled path, at the picture's size, one thread a 2 x 2 block: Deepen blacks' bend as in `lift`, Y' (full
    // range, 0-1) to `outY` for the prescaler, the block's chroma (centred, -0.5-0.5, scaled with the bend) to `outC`.
    kernel void prep(texture2d<float> inY [[texture(0)]], texture2d<float> inC [[texture(1)]],
                     texture2d<float, access::write> outY [[texture(2)]], texture2d<float, access::write> outC [[texture(3)]],
                     constant Params& p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= outC.get_width() || gid.y >= outC.get_height()) return;
        float k = 0;
        for (uint n = 0; n < 4; n++) {
            uint2 at = min(gid * 2 + uint2(n & 1, n >> 1), uint2(inY.get_width() - 1, inY.get_height() - 1));
            float y = (inY.read(at).r * p.codeScale - 64.0) / 876.0;
            float r = 1.0;
            if (p.lift > 0.0) {
                float t = saturate(1.0 - y / p.knee);
                r = y > 1e-4 ? saturate((y - p.lift * t * t) / y) : 0.0;
            }
            k += r;
            if (all(gid * 2 + uint2(n & 1, n >> 1) < uint2(outY.get_width(), outY.get_height()))) outY.write(float4(saturate(y * r)), at);
        }
        outC.write(float4((inC.read(gid).rg * p.codeScale - 512.0) / 896.0 * (k * 0.25), 0, 0), gid);
    }

    constexpr sampler lin(coord::normalized, filter::linear, address::clamp_to_edge);

    // Catmull-Rom in nine bilinear taps.
    inline float catrom(texture2d<float> t, float2 uv) {
        float2 size = float2(t.get_width(), t.get_height());
        float2 sp = uv * size, t1 = floor(sp - 0.5) + 0.5, f = sp - t1;
        float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f)), w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
        float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f)), w3 = f * f * (-0.5 + 0.5 * f);
        float2 w12 = w1 + w2, t0 = (t1 - 1.0) / size, t3 = (t1 + 2.0) / size, t12 = (t1 + w2 / w12) / size;
        return t.sample(lin, float2(t0.x, t0.y)).r * w0.x * w0.y + t.sample(lin, float2(t12.x, t0.y)).r * w12.x * w0.y
             + t.sample(lin, float2(t3.x, t0.y)).r * w3.x * w0.y + t.sample(lin, float2(t0.x, t12.y)).r * w0.x * w12.y
             + t.sample(lin, float2(t12.x, t12.y)).r * w12.x * w12.y + t.sample(lin, float2(t3.x, t12.y)).r * w3.x * w12.y
             + t.sample(lin, float2(t0.x, t3.y)).r * w0.x * w3.y + t.sample(lin, float2(t12.x, t3.y)).r * w12.x * w3.y
             + t.sample(lin, float2(t3.x, t3.y)).r * w3.x * w3.y;
    }

    // The last pass, at the screen's size, one thread a 2 x 2 block: Y' from the prescaler's (or the picture's) luma by Catmull-Rom,
    // chroma bilinear, then the lift as in `lift`.
    kernel void scale_lift(texture2d<float> luma [[texture(0)]], texture2d<float> chroma [[texture(1)]],
                           texture2d<float, access::write> outY [[texture(2)]], texture2d<float, access::write> outC [[texture(3)]],
                           texture3d<float> lut [[texture(4)]], constant Params& p [[buffer(0)]], constant float* curve [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= outC.get_width() || gid.y >= outC.get_height()) return;
        float2 size = float2(outY.get_width(), outY.get_height());
        // The doubled luma already at the screen's size (1080p -> 2160p): Catmull-Rom at its own pixel centres is the pixel itself.
        bool same = luma.get_width() == outY.get_width() && luma.get_height() == outY.get_height();
        float2 c = chroma.sample(lin, (float2(gid * 2) + 1.0) / size).rg;
        float2 sum = 0;
        for (uint n = 0; n < 4; n++) {
            uint2 at = gid * 2 + uint2(n & 1, n >> 1);
            float yy = saturate(same ? luma.read(at).r : catrom(luma, (float2(at) + 0.5) / size));
            float3 rgb = clamp(float3(yy + 1.5748 * c.y, yy - 0.187324 * c.x - 0.468124 * c.y, yy + 1.8556 * c.x), 0.0, 1.0);
            float3 e = lifted(rgb, p, curve, lut);
            float yp = dot(e, float3(0.2627, 0.6780, 0.0593));
            sum += float2((e.b - yp) / 1.8814, (e.r - yp) / 1.4746);
            outY.write(float4((yp * 876.0 + 64.0) * 64.0 / 65535.0), at);
        }
        outC.write(float4((sum * 0.25 * 896.0 + 512.0) * 64.0 / 65535.0, 0, 0), gid);
    }

    // `scale_lift` without the lift (HDR on this TV off): Y' by Catmull-Rom, the block's chroma bilinear, written back as the picture's
    // own video-range Y'CbCr in P010.
    kernel void scale_sdr(texture2d<float> luma [[texture(0)]], texture2d<float> chroma [[texture(1)]],
                          texture2d<float, access::write> outY [[texture(2)]], texture2d<float, access::write> outC [[texture(3)]],
                          constant Params& p [[buffer(0)]], constant float* curve [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= outC.get_width() || gid.y >= outC.get_height()) return;
        float2 size = float2(outY.get_width(), outY.get_height());
        // The doubled luma already at the screen's size (1080p -> 2160p): Catmull-Rom at its own pixel centres is the pixel itself.
        bool same = luma.get_width() == outY.get_width() && luma.get_height() == outY.get_height();
        float2 c = chroma.sample(lin, (float2(gid * 2) + 1.0) / size).rg;
        for (uint n = 0; n < 4; n++) {
            uint2 at = gid * 2 + uint2(n & 1, n >> 1);
            float yy = saturate(same ? luma.read(at).r : catrom(luma, (float2(at) + 0.5) / size));
            outY.write(float4((yy * 876.0 + 64.0) * 64.0 / 65535.0), at);
        }
        outC.write(float4((clamp(c, -0.5, 0.5) * 896.0 + 512.0) * 64.0 / 65535.0, 0, 0), gid);
    }
    """

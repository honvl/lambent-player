import CoreVideo
import Foundation
import Metal
import QuartzCore
import os

/// The GPU work, off the main thread: 8- or 10-bit 4:2:0 in (BT.709, or the matrix the picture names: `LambentYCbCr`), P010 BT.2020 PQ
/// out (or, with `hdr` off, P010 with the picture's own SDR colours: upscaling only).
///
/// The lift is Lambent Auto HDR's bank of sixteen tables (LambentAutoHDR.swift): each picture's own 65^3 table, made from the picture
/// ahead of the pass that reads it, in the same command buffer. A picture as big as its place on the screen gets one Metal kernel, the
/// lift. A smaller one (a 1080p title on a 4K screen) is upscaled here rather than by tvOS's own scaler (bilinear in the simulator,
/// docs/SHADER_UPSCALE.md in Lambent): a pass at the picture's size writes Y' and chroma, a luma prescaler doubles Y' (FSRCNNX 8-0-4-1 on
/// an Apple GPU of family 10 or later, an A19; RAVU-lite before it), and a last pass at the screen's size scales (Catmull-Rom), lifts
/// and writes PQ. Catmull-Rom alone needs no picture pass: the last pass reads the decoder's planes.
/// Above them all, on an A15 or later with the models in the bundle, the AI upscaler (LambentNeuralScaler.swift: NVIDIA's VSR low
/// network on the Neural Engine) doubles the whole picture in place of the picture pass and the prescaler; at most 30 fps before an A19.
/// When a scaler cannot keep up with the film (pictures taking longer than a frame, start to finish), the next one down takes over:
/// FSRCNNX, RAVU-lite, Catmull-Rom, then none (tvOS scales). Measured on an A16 (docs/CLIENT_HDR.md in Lambent), 1080p -> 4K with
/// the formula lift the tables replaced, back to back: Catmull-Rom 4.1 ms, RAVU-lite 8.4 ms, FSRCNNX 34 ms. GPU time alone does not decide: an A-series GPU lowers
/// its clock when it has room, so a scaler's GPU time stretches toward the frame (RAVU-lite read 12 to 25 ms at 24 fps while keeping up).
final class LambentLiftProcessor: @unchecked Sendable {
    struct Report {
        var frames = 0, late = 0
        var meanMs = 0.0, p95Ms = 0.0
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
    /// Lambent Auto HDR (the bank of sixteen tables); nil without its weights in the bundle: then nothing is lifted here.
    private let autoHDR: LambentAutoHDR?
    /// This device can lift SDR to HDR10 (Auto HDR's weights are in the bundle and its kernels built).
    var canLift: Bool { autoHDR != nil }
    /// Bound where a pass takes a table but the picture is not lifted (the AI upscaler's fused finish writing SDR).
    private let noTable: MTLTexture
    private var prescalers: [String: LambentPrescaler] = [:]
    /// The scalers to try, best first; the first one stays until its GPU time does not fit.
    private(set) var ladder: [Scaler]
    /// The device's whole ladder, which a plan's `cup` buys.
    private let paidLadder: [Scaler]
    private var step = 0
    private var stepPictures = 0
    private var stepLate = 0
    /// Where the picture is shown, in screen pixels; nil: at its own size.
    var outputSize: (Int, Int)? {
        get { outputSizeLock.withLock { $0 } }
        set { outputSizeLock.withLock { $0 = newValue } }
    }
    private let outputSizeLock = OSAllocatedUnfairLock<(Int, Int)?>(initialState: nil)
    /// The film's rate: a picture has one frame of it, start to finish.
    var frameRate: Double = 24
    /// Off: upscaling only, the picture's own SDR colours out (HDR on this TV is off).
    var hdr = true
    /// The title's video bitrate (bits a second, 0: unknown) and codec (libavcodec's name, "": unknown), for the AI upscaler's network.
    var sourceBitrate: Int64 = 0
    var sourceCodec = ""
    /// `prepare` runs on its own queue for every picture (the player): `process` never runs the network itself.
    var pipelined = false
    /// The ladder was set by `force` (a bench): the AI upscaler runs at any frame rate.
    private var forced = false
    /// The AI upscaler runs at any scale, under `LambentClientUpscale.neuralMinimumScale` too (a bench, to compare).
    var neuralAnyScale = false
    private var engineMs: [Double] = []
    private var neuralInt8 = false
    private var packWallMs: [Double] = []
    /// The picture pass's Y' and chroma, for a prescaler.
    private var lumaTex: MTLTexture?
    private var chromaTex: MTLTexture?
    private var outPool: CVPixelBufferPool?
    private var outPoolSize = (0, 0)
    private var cache: CVMetalTextureCache?
    /// `prepare`'s own, as it runs on another queue.
    private var prepareCache: CVMetalTextureCache?
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var frameIndex = 0
    private var gpuMs: [Double] = []
    private var late = 0
    private var format = ""

    init?() {
        func make(_ library: MTLLibrary, _ name: String) -> MTLComputePipelineState? {
            library.makeFunction(name: name).flatMap { try? library.device.makeComputePipelineState(function: $0) }
        }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
            let library = try? device.makeLibrary(source: liftSource, options: nil),
            let pipeline = make(library, "lift"), let prep = make(library, "prep"),
            let scale = make(library, "scale_lift"), let scaleSDR = make(library, "scale_sdr")
        else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        prepPipeline = prep
        scalePipeline = scale
        scaleSDRPipeline = scaleSDR
        autoHDR = LambentAutoHDR(device: device)
        let none = MTLTextureDescriptor()
        none.textureType = .type3D
        none.pixelFormat = .rgba16Float
        (none.width, none.height, none.depth) = (1, 1, 1)
        none.usage = [.shaderRead]
        none.storageMode = .private
        guard let noTable = device.makeTexture(descriptor: none) else { return nil }
        self.noTable = noTable
        // Picked by the GPU's Apple family, the same on the Apple TV and the iPad (LambentClientUpscale.ladder says why).
        let ladder = LambentClientUpscale.ladder(
            supports: { device.supportsFamily($0) }, neuralModels: { LambentNeuralScaler.available(student: $0) })
        var loaded: [String: LambentPrescaler] = [:]
        for case .prescaler(let name) in ladder {
            if let p = LambentPrescaler(device: device, name: name) { loaded[name] = p }
        }
        prescalers = loaded
        self.ladder = ladder.filter { if case .prescaler(let n) = $0 { return loaded[n] != nil } else { return true } }
        paidLadder = self.ladder
        if case .neural(let fast) = self.ladder.first { _ = LambentNeuralScaler.scaler("neural-low", student: fast, device: device) }
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &prepareCache)
    }

    /// Before the first frame of a session (nothing is queued yet).
    func reset() {
        frameIndex = 0
        step = 0
        stepPictures = 0
        stepLate = 0
        network = nil
    }

    /// The title's ladder: the free one, or the device's whole ladder when a plan asked. Called with no picture in flight (`start`).
    func useLadder(free: Bool) {
        guard !forced else { return }
        ladder = free ? LambentClientUpscale.freeLadder.filter { if case .prescaler(let n) = $0 { return prescalers[n] != nil } else { return true } } : paidLadder
        step = 0
        stepPictures = 0
        stepLate = 0
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

    private func neuralNetwork(_ w: Int, _ h: Int) -> String {
        LambentNeuralScaler.network(bitrate: sourceBitrate, width: w, height: h, frameRate: frameRate, codec: sourceCodec)
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
            let net = neuralNetwork(w, h)
            network = net
            NSLog("[LambentHDR] AI upscaler network %@ (%@ %lld bit/s, %dx%d at %.3f fps)", net, sourceCodec, sourceBitrate, w, h, frameRate)
        }
        guard let net = network, let size = LambentNeuralScaler.size(for: w, h, network: net, student: fast),
            let neural = LambentNeuralScaler.scaler(net, student: fast, size: size, device: device)
        else { return nil }
        let tenBit = CVPixelBufferGetPixelFormatType(picture) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let formats: (MTLPixelFormat, MTLPixelFormat) = tenBit ? (.r16Unorm, .rg16Unorm) : (.r8Unorm, .rg8Unorm)
        guard let a = texture(picture, 0, formats.0, prepareCache), let b = texture(picture, 1, formats.1, prepareCache),
            let inY = CVMetalTextureGetTexture(a), let inC = CVMetalTextureGetTexture(b),
            let slot = try? neural.pack(
                inY: inY, inC: inC, codeScale: tenBit ? 65535.0 / 64.0 : 1020.0, colour: LambentYCbCr(picture: picture))
        else { return nil }
        withExtendedLifetime((a, b)) {}
        return NeuralPrepared(scaler: neural, slot: slot)
    }

    func process(_ picture: CVPixelBuffer, deadline: CFTimeInterval, prepared: NeuralPrepared? = nil) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(picture), h = CVPixelBufferGetHeight(picture)
        let pixelFormat = CVPixelBufferGetPixelFormatType(picture)
        let tenBit = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        format = "\(w)x\(h) \(tenBit ? "10" : "8")-bit"
        frameIndex += 1
        if let (ow, oh) = outputSize, scales(w, h) {
            return scale(picture, tenBit: tenBit, from: (w, h), to: (ow & ~1, oh & ~1), deadline: deadline, prepared: prepared)
        }
        // Upscaling only, and the ladder has stepped down to none: the picture as it is.
        guard hdr, let autoHDR else { return picture }
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
        attachHDR10(out, from: picture)
        let colour = LambentYCbCr(picture: picture)

        let inFormats: (MTLPixelFormat, MTLPixelFormat) = tenBit ? (.r16Unorm, .rg16Unorm) : (.r8Unorm, .rg8Unorm)
        guard let a = texture(picture, 0, inFormats.0), let b = texture(picture, 1, inFormats.1),
            let c = texture(out, 0, .r16Unorm), let d = texture(out, 1, .rg16Unorm),
            let inY = CVMetalTextureGetTexture(a), let inC = CVMetalTextureGetTexture(b),
            let outY = CVMetalTextureGetTexture(c), let outC = CVMetalTextureGetTexture(d),
            let buffer = queue.makeCommandBuffer(),
            let table = autoHDR.encodeTable(buffer, luma: inY, chroma: inC, tenBit: tenBit, matrix: colour),
            let encoder = buffer.makeComputeCommandEncoder()
        else { return nil }
        // Normalised sample to a 10-bit code: P010 keeps the code in the top 10 of 16 bits; 8-bit codes are a quarter of 10-bit ones.
        var params = LiftParams(codeScale: tenBit ? 65535.0 / 64.0 : 1020.0, colour: colour)
        encoder.setComputePipelineState(pipeline)
        encoder.setTextures([inY, inC, outY, outC, table], range: 0..<5)
        encoder.setBytes(&params, length: MemoryLayout<LiftParams>.size, index: 0)
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

    /// The picture pass and the prescaler (or the AI upscaler's finish) and the scale-and-lift pass, in one command buffer.
    private func scale(
        _ picture: CVPixelBuffer, tenBit: Bool, from src: (Int, Int), to dst: (Int, Int), deadline: CFTimeInterval,
        prepared: NeuralPrepared?
    ) -> CVPixelBuffer? {
        let started = CACurrentMediaTime()
        format = "\(src.0)x\(src.1) \(tenBit ? "10" : "8")-bit -> \(dst.0)x\(dst.1)"
        // Before an A19 the network itself keeps up with 30 pictures a second at 1920 x 1088; its time follows its model's area, so a
        // smaller picture's model takes more of them (720p at 60).
        if scaler == .neural(fast: false), !forced, !device.supportsFamily(.apple10), step < ladder.count - 1 {
            let net = network ?? neuralNetwork(src.0, src.1)
            let area = LambentNeuralScaler.area(src.0, src.1, network: net, student: false)
            if frameRate * area > 30.5 {
                NSLog(
                    "[LambentHDR] AI upscaler: %.3f fps at %.2f of 1080p's work is over 30 on this chip: %@", frameRate, area,
                    "\(ladder[step + 1])")
                step += 1
                stepPictures = 0
            }
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
        var made: CVPixelBuffer?
        guard let outPool, CVPixelBufferPoolCreatePixelBuffer(nil, outPool, &made) == kCVReturnSuccess, let out = made else { return nil }
        let hdr = hdr && autoHDR != nil
        let colour = LambentYCbCr(picture: picture)
        if hdr {
            attachHDR10(out, from: picture)
        } else {
            CVBufferPropagateAttachments(picture, out)
            // A picture that names no matrix was read by its size's convention; at the output's size the system would guess again.
            if CVBufferCopyAttachment(picture, kCVImageBufferYCbCrMatrixKey, nil) == nil {
                CVBufferSetAttachment(out, kCVImageBufferYCbCrMatrixKey, colour.matrix as CFString, .shouldPropagate)
            }
        }
        let inFormats: (MTLPixelFormat, MTLPixelFormat) = tenBit ? (.r16Unorm, .rg16Unorm) : (.r8Unorm, .rg8Unorm)
        guard let a = texture(picture, 0, inFormats.0), let b = texture(picture, 1, inFormats.1),
            let c = texture(out, 0, .r16Unorm), let d = texture(out, 1, .rg16Unorm),
            let inY = CVMetalTextureGetTexture(a), let inC = CVMetalTextureGetTexture(b),
            let outY = CVMetalTextureGetTexture(c), let outC = CVMetalTextureGetTexture(d),
            let buffer = queue.makeCommandBuffer()
        else { return nil }
        // This picture's Auto HDR table, made from the picture before anything reads it; without one the picture keeps its SDR.
        var table: MTLTexture?
        if hdr { table = autoHDR?.encodeTable(buffer, luma: inY, chroma: inC, tenBit: tenBit, matrix: colour) }
        guard !hdr || table != nil else { return nil }
        let lut = table ?? noTable
        var params = LiftParams(codeScale: tenBit ? 65535.0 / 64.0 : 1020.0, colour: colour)
        // What the last pass reads: the decoder's planes, unless a scaler's own replace them below.
        var luma: MTLTexture = inY
        var chroma: MTLTexture = inC
        // The chroma the last pass reads sits where the picture's does (the AI upscaler's finish puts its own mid-block).
        var chromaSiting = (colour.sitingX, colour.sitingY)
        var chromaLumaSize = src
        var packMs = 0.0
        var fused = false
        var used = scaler
        if case .neural = used {
            let net = network ?? neuralNetwork(src.0, src.1)
            if let ready = prepared ?? (pipelined ? nil : prepare(picture)), ready.scaler.network == net, used == .neural(fast: ready.scaler.f == 4) {
                // Exactly twice the picture (1080p -> 2160p): the finish and the last pass in one kernel, straight to the output.
                if dst == (2 * src.0, 2 * src.1) {
                    fused = ready.scaler.encodeFinishOut(ready.slot, buffer, outY: outY, outC: outC, lut: lut, hdr: hdr)
                }
                if !fused {
                    guard let (l, c) = ready.scaler.encodeFinish(ready.slot, buffer) else { return nil }
                    (luma, chroma) = (l, c)
                    chromaSiting = (0, 0)
                    chromaLumaSize = (2 * src.0, 2 * src.1)
                }
                packMs = ready.slot.packMs
                neuralInt8 = ready.scaler.int8
                engineMs.append(ready.slot.engineMs)
                packWallMs.append(ready.slot.packWallMs)
            } else {
                // Still loading (or it cannot take this picture): the next scaler down that is not the network's other model (nothing
                // was packed for it either), uncounted.
                used = ladder[(step + 1)...].first { !$0.isNeural } ?? .catmullRom
            }
        }
        if case .prescaler(let name) = used, let prescaler = prescalers[name] {
            // The picture pass (Y' full range and centred chroma, as the prescaler's shader reads them), then the prescaler.
            guard let (lumaTex, chromaTex) = pictureTextures(src), let encoder = buffer.makeComputeCommandEncoder() else { return nil }
            encoder.setComputePipelineState(prepPipeline)
            encoder.setTextures([inY, inC, lumaTex, chromaTex], range: 0..<4)
            encoder.setBytes(&params, length: MemoryLayout<LiftParams>.size, index: 0)
            encoder.dispatchThreads(
                MTLSize(width: chromaTex.width, height: chromaTex.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
            luma = prescaler.encode(buffer, luma: lumaTex, output: dst)
            chroma = chromaTex
        } else if !used.isNeural {
            // Catmull-Rom alone: the last pass reads the decoder's planes themselves (video-range codes), with no picture pass between.
            params.lumaScale = params.codeScale / 876
            params.lumaBias = -64 / 876
            params.chromaScale = params.codeScale / 896
            params.chromaBias = -512 / 896
        }
        if !fused {
            // From the middle of an output block to where its chroma sample is read in `chroma`: the output's samples sit as the
            // picture's do, and `chroma`'s where `chromaSiting` says.
            params.chromaX = colour.sitingX / Float(dst.0) - chromaSiting.0 / Float(chromaLumaSize.0)
            params.chromaY = colour.sitingY / Float(dst.1) - chromaSiting.1 / Float(chromaLumaSize.1)
            guard let final = buffer.makeComputeCommandEncoder() else { return nil }
            final.setComputePipelineState(hdr ? scalePipeline : scaleSDRPipeline)
            final.setTextures(hdr ? [luma, chroma, outY, outC, lut] : [luma, chroma, outY, outC], range: hdr ? 0..<5 : 0..<4)
            final.setBytes(&params, length: MemoryLayout<LiftParams>.size, index: 0)
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

    /// The picture pass's textures for a `src`-sized picture: Y' at its size, chroma at half.
    private func pictureTextures(_ src: (Int, Int)) -> (MTLTexture, MTLTexture)? {
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
        guard let lumaTex, let chromaTex else { return nil }
        return (lumaTex, chromaTex)
    }

    /// HDR10's attachments on a lifted picture; its chroma samples sit where `picture`'s do.
    private func attachHDR10(_ out: CVPixelBuffer, from picture: CVPixelBuffer) {
        for key in [kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocationBottomFieldKey] {
            if let location = CVBufferCopyAttachment(picture, key, nil) { CVBufferSetAttachment(out, key, location, .shouldPropagate) }
        }
        CVBufferSetAttachment(out, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferMasteringDisplayColorVolumeKey, Self.masteringDisplay as CFData, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferContentLightLevelInfoKey, Self.contentLightLevel as CFData, .shouldPropagate)
    }

    func takeReport() -> Report {
        defer { gpuMs.removeAll(keepingCapacity: true); engineMs.removeAll(keepingCapacity: true); late = 0 }
        var r = Report(
            frames: gpuMs.count, late: late, format: format,
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

/// A picture's Y'CbCr: its matrix and where its chroma samples sit.
struct LambentYCbCr: Equatable {
    /// The matrix's luma weights of red and blue.
    var kr: Float, kb: Float
    /// CoreVideo's name for the matrix (`kCVImageBufferYCbCrMatrix_...`).
    var matrix: String
    /// A chroma sample's place against the middle of its 2 x 2 luma block, in luma pixels (x right, y down). MPEG-2's, H.264's and
    /// HEVC's usual siting is (-0.5, 0): the sample beside the block's left pixels, half way down.
    var sitingX: Float = -0.5, sitingY: Float = 0

    static let bt709 = LambentYCbCr(kr: 0.2126, kb: 0.0722, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    static let bt601 = LambentYCbCr(kr: 0.299, kb: 0.114, matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
    static let smpte240M = LambentYCbCr(kr: 0.212, kb: 0.087, matrix: kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as String)
    static let bt2020 = LambentYCbCr(kr: 0.2627, kb: 0.0593, matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)

    init(kr: Float, kb: Float, matrix: String) { (self.kr, self.kb, self.matrix) = (kr, kb, matrix) }

    /// The picture's own, by its attachments. One that names no matrix is read by the convention for its size (as mpv and ffmpeg guess):
    /// BT.601 for SD, BT.709 from 720p.
    init(picture: CVPixelBuffer) {
        func named(_ key: CFString) -> String? { CVBufferCopyAttachment(picture, key, nil) as? String }
        func isName(_ value: String?, _ name: CFString) -> Bool { value == (name as String) }
        let matrix = named(kCVImageBufferYCbCrMatrixKey)
        if isName(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2) {
            self = .bt709
        } else if isName(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4) {
            self = .bt601
        } else if isName(matrix, kCVImageBufferYCbCrMatrix_SMPTE_240M_1995) {
            self = .smpte240M
        } else if isName(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020) {
            self = .bt2020
        } else {
            self = CVPixelBufferGetWidth(picture) < 1280 && CVPixelBufferGetHeight(picture) <= 576 ? .bt601 : .bt709
        }
        let location = named(kCVImageBufferChromaLocationTopFieldKey)
        if isName(location, kCVImageBufferChromaLocation_Center) {
            (sitingX, sitingY) = (0, 0)
        } else if isName(location, kCVImageBufferChromaLocation_TopLeft) {
            (sitingX, sitingY) = (-0.5, -0.5)
        } else if isName(location, kCVImageBufferChromaLocation_Top) {
            (sitingX, sitingY) = (0, -0.5)
        } else if isName(location, kCVImageBufferChromaLocation_BottomLeft) {
            (sitingX, sitingY) = (-0.5, 0.5)
        } else if isName(location, kCVImageBufferChromaLocation_Bottom) {
            (sitingX, sitingY) = (0, 0.5)
        }
    }
}

struct LiftParams {
    /// A normalised sample to a 10-bit code: 65535 / 64 for P010 (the code in the top 10 of 16 bits), 1020 for 8-bit planes.
    var codeScale: Float
    /// Centred chroma to R'G'B' about Y', by the picture's matrix: R' = Y' + crR Cr, B' = Y' + cbB Cb, G' = Y' - cbG Cb - crG Cr.
    var crR: Float, cbB: Float, cbG: Float, crG: Float
    /// The scale passes: from the middle of an output block to where its chroma is read in the chroma texture, normalised.
    var chromaX: Float = 0, chromaY: Float = 0
    /// The scale passes: a luma sample to Y' (0-1) and a chroma sample to centred chroma. The picture pass's textures hold those already;
    /// the decoder's planes hold video-range codes.
    var lumaScale: Float = 1, lumaBias: Float = 0, chromaScale: Float = 1, chromaBias: Float = 0

    init(codeScale: Float, colour: LambentYCbCr) {
        self.codeScale = codeScale
        let kg = 1 - colour.kr - colour.kb
        crR = 2 * (1 - colour.kr)
        cbB = 2 * (1 - colour.kb)
        cbG = colour.kb * cbB / kg
        crG = colour.kr * crR / kg
    }
}

// Lambent Auto HDR's lift: R'G'B' (from the picture's Y'CbCr by its matrix) through the picture's table (LambentAutoHDR.swift: BT.2020
// PQ over R'G'B', 65 points a side, read with the hardware's trilinear filter), then Y'CbCr BT.2020 video range.
private let liftSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params { float codeScale, crR, cbB, cbG, crG, chromaX, chromaY, lumaScale, lumaBias, chromaScale, chromaBias; };

    // Y' (0-1) and centred chroma to R'G'B', by the picture's matrix.
    inline float3 to_rgb(float yy, float2 c, constant Params& p) {
        return clamp(float3(yy + p.crR * c.y, yy - p.cbG * c.x - p.crG * c.y, yy + p.cbB * c.x), 0.0, 1.0);
    }

    constexpr sampler lutSampler(coord::normalized, filter::linear, address::clamp_to_edge);

    inline float3 lifted(float3 rgb, texture3d<float> lut) {
        return lut.sample(lutSampler, rgb * (64.0 / 65.0) + 0.5 / 65.0).rgb;
    }

    kernel void lift(texture2d<float> inY [[texture(0)]], texture2d<float> inC [[texture(1)]],
                     texture2d<float, access::write> outY [[texture(2)]], texture2d<float, access::write> outC [[texture(3)]],
                     texture3d<float> lut [[texture(4)]], constant Params& p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= outC.get_width() || gid.y >= outC.get_height()) return;
        float2 c = (inC.read(gid).rg * p.codeScale - 512.0) / 896.0;
        float2 sum = 0;
        for (uint n = 0; n < 4; n++) {
            uint2 at = min(gid * 2 + uint2(n & 1, n >> 1), uint2(inY.get_width() - 1, inY.get_height() - 1));
            float yy = saturate((inY.read(at).r * p.codeScale - 64.0) / 876.0);
            float3 e = lifted(to_rgb(yy, c, p), lut);
            float yp = dot(e, float3(0.2627, 0.6780, 0.0593));
            sum += float2((e.b - yp) / 1.8814, (e.r - yp) / 1.4746);
            outY.write(float4((yp * 876.0 + 64.0) * 64.0 / 65535.0), gid * 2 + uint2(n & 1, n >> 1));
        }
        outC.write(float4((sum * 0.25 * 896.0 + 512.0) * 64.0 / 65535.0, 0, 0), gid);
    }

    // The picture pass of the upscaled path, at the picture's size, one thread a 2 x 2 block: Y' (full range, 0-1) to `outY` for the
    // prescaler, the block's chroma (centred, -0.5-0.5) to `outC`.
    kernel void prep(texture2d<float> inY [[texture(0)]], texture2d<float> inC [[texture(1)]],
                     texture2d<float, access::write> outY [[texture(2)]], texture2d<float, access::write> outC [[texture(3)]],
                     constant Params& p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= outC.get_width() || gid.y >= outC.get_height()) return;
        for (uint n = 0; n < 4; n++) {
            uint2 at = min(gid * 2 + uint2(n & 1, n >> 1), uint2(inY.get_width() - 1, inY.get_height() - 1));
            float y = (inY.read(at).r * p.codeScale - 64.0) / 876.0;
            if (all(gid * 2 + uint2(n & 1, n >> 1) < uint2(outY.get_width(), outY.get_height()))) outY.write(float4(saturate(y)), at);
        }
        outC.write(float4((inC.read(gid).rg * p.codeScale - 512.0) / 896.0, 0, 0), gid);
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
    // chroma bilinear where the output's chroma sample sits, then the lift as in `lift`. `luma` and `chroma` are the picture pass's or a
    // scaler's textures, or the decoder's own planes (lumaScale and the rest turn their codes into Y' and centred chroma).
    kernel void scale_lift(texture2d<float> luma [[texture(0)]], texture2d<float> chroma [[texture(1)]],
                           texture2d<float, access::write> outY [[texture(2)]], texture2d<float, access::write> outC [[texture(3)]],
                           texture3d<float> lut [[texture(4)]], constant Params& p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= outC.get_width() || gid.y >= outC.get_height()) return;
        float2 size = float2(outY.get_width(), outY.get_height());
        // The doubled luma already at the screen's size (1080p -> 2160p): Catmull-Rom at its own pixel centres is the pixel itself.
        bool same = luma.get_width() == outY.get_width() && luma.get_height() == outY.get_height();
        float2 c = chroma.sample(lin, (float2(gid * 2) + 1.0) / size + float2(p.chromaX, p.chromaY)).rg * p.chromaScale + p.chromaBias;
        float2 sum = 0;
        for (uint n = 0; n < 4; n++) {
            uint2 at = gid * 2 + uint2(n & 1, n >> 1);
            float yy = saturate((same ? luma.read(at).r : catrom(luma, (float2(at) + 0.5) / size)) * p.lumaScale + p.lumaBias);
            float3 e = lifted(to_rgb(yy, c, p), lut);
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
                          constant Params& p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= outC.get_width() || gid.y >= outC.get_height()) return;
        float2 size = float2(outY.get_width(), outY.get_height());
        // The doubled luma already at the screen's size (1080p -> 2160p): Catmull-Rom at its own pixel centres is the pixel itself.
        bool same = luma.get_width() == outY.get_width() && luma.get_height() == outY.get_height();
        float2 c = chroma.sample(lin, (float2(gid * 2) + 1.0) / size + float2(p.chromaX, p.chromaY)).rg * p.chromaScale + p.chromaBias;
        for (uint n = 0; n < 4; n++) {
            uint2 at = gid * 2 + uint2(n & 1, n >> 1);
            float yy = saturate((same ? luma.read(at).r : catrom(luma, (float2(at) + 0.5) / size)) * p.lumaScale + p.lumaBias);
            outY.write(float4((yy * 876.0 + 64.0) * 64.0 / 65535.0), at);
        }
        outC.write(float4((clamp(c, -0.5, 0.5) * 896.0 + 512.0) * 64.0 / 65535.0, 0, 0), gid);
    }
    """

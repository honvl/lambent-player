import AVFoundation
import AVKit
import AetherEngine
import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import UIKit

/// Lambent's Auto HDR on the Apple TV: an SDR title direct-plays, and the
/// Apple TV turns it into HDR10 itself, so the PC needs no transcode.
///
/// AetherEngine plays the title through AVPlayer as usual. Its frames are
/// taken from an `AVPlayerItemVideoOutput`, lifted on the GPU (Lambent's
/// TrueHDR-fitted tone curve, and optionally Deepen blacks), and presented as
/// BT.2020 PQ in an `AVSampleBufferDisplayLayer` laid over the hidden
/// `AVPlayerLayer`. The panel is asked for HDR10 at the film's rate.
///
/// Turned on in Settings > Lambent enhancement > HDR on this TV (with
/// Enhance on PC off, so the server direct-plays), stored by Flutter as
/// `flutter.pref_lambent_client_hdr`; a launch argument
/// `-flutter.pref_lambent_client_hdr YES` does the same. Logs `[LambentHDR]`
/// lines every 2 s.
@MainActor
final class LambentHDRLift {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "flutter.pref_lambent_client_hdr") }
    static var deepenBlacks: Bool { UserDefaults.standard.bool(forKey: "flutter.pref_lambent_client_blacks") }

    private weak var playerLayer: AVPlayerLayer?
    private weak var item: AVPlayerItem?
    private weak var host: UIView?
    private var output: AVPlayerItemVideoOutput?
    private let liftView = LiftView()
    private var displayLayer: AVSampleBufferDisplayLayer { liftView.layer as! AVSampleBufferDisplayLayer }
    private var link: CADisplayLink?
    private let processor: LambentLiftProcessor
    private let queue = DispatchQueue(label: "lambent.hdr-lift", qos: .userInteractive)
    private var frameRate: Double = 24
    private var lastReport = CACurrentMediaTime()
    private var requestedHDR = false

    init?() {
        guard let processor = LambentLiftProcessor() else { return nil }
        self.processor = processor
    }

    var isRunning: Bool { output != nil }

    /// Starts on the engine's AVPlayer once its item exists. Only for SDR.
    func start(engine: AetherEngine, in view: UIView) -> Bool {
        guard output == nil, engine.sourceVideoFormat == .sdr,
            let layer = engine.nativePlayerLayer, let item = layer.player?.currentItem
        else { return false }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            // What VideoToolbox decodes H.264 / 8-bit HEVC into: no conversion on the way out.
            kCVPixelBufferPixelFormatTypeKey as String: [
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            ],
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        output.suppressesPlayerRendering = true
        item.add(output)
        self.output = output
        self.item = item
        self.playerLayer = layer
        host = view
        frameRate = engine.sourceVideoFrameRate ?? 24
        processor.reset(deepen: Self.deepenBlacks)

        displayLayer.videoGravity = layer.videoGravity
        liftView.frame = view.bounds
        liftView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        liftView.isUserInteractionEnabled = false
        liftView.backgroundColor = .black
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: nil, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        if let timebase {
            CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(timebase, rate: 1)
            displayLayer.controlTimebase = timebase
        }
        view.addSubview(liftView)
        layer.opacity = 0

        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        NSLog("[LambentHDR] started fps %.3f deepen %@", frameRate, Self.deepenBlacks ? "on" : "off")
        return true
    }

    func stop() {
        link?.invalidate()
        link = nil
        if let output, let item { item.remove(output) }
        output = nil
        item = nil
        playerLayer?.opacity = 1
        playerLayer = nil
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        liftView.removeFromSuperview()
        if requestedHDR, let window = host?.window {
            window.avDisplayManager.preferredDisplayCriteria = nil
        }
        requestedHDR = false
        host = nil
    }

    /// Asks the panel for HDR10 at the film's rate. AetherEngine programmed SDR
    /// criteria for an SDR source at load; this replaces them.
    private func requestHDR10(in view: UIView, width: Int, height: Int) {
        requestedHDR = true
        guard let window = view.window else { return }
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
        ]
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: kCMVideoCodecType_HEVC, width: Int32(max(width, 1)),
            height: Int32(max(height, 1)), extensions: extensions as CFDictionary,
            formatDescriptionOut: &description)
        guard let description else { return }
        window.avDisplayManager.preferredDisplayCriteria = AVDisplayCriteria(
            refreshRate: Float(frameRate), formatDescription: description)
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let output else { return }
        let target = link.targetTimestamp
        let itemTime = output.itemTime(forHostTime: target)
        if output.hasNewPixelBuffer(forItemTime: itemTime),
            let source = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
        {
            if !requestedHDR {
                // The first picture: a stream that is already HDR (an enhanced one, or a source the probe called SDR) is
                // left to AVPlayer; otherwise the panel goes to HDR10 at the picture's size.
                let transfer = CVBufferCopyAttachment(source, kCVImageBufferTransferFunctionKey, nil) as? String
                if transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
                    || transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
                {
                    NSLog("[LambentHDR] the stream is already HDR (%@): not lifting", transfer ?? "")
                    stop()
                    return
                }
                if let view = host {
                    requestHDR10(in: view, width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
                }
                NSLog("[LambentHDR] first picture %dx%d, HDR10 requested at %.3f Hz",
                    CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source), frameRate)
            }
            let renderer = displayLayer.sampleBufferRenderer
            let processor = processor
            queue.async {
                guard let lifted = processor.process(source, deadline: target),
                    let sample = Self.sampleBuffer(lifted, at: target)
                else { return }
                renderer.enqueue(sample)
            }
        }
        let now = CACurrentMediaTime()
        if now - lastReport >= 2 {
            lastReport = now
            let headroom = host?.window?.screen.currentEDRHeadroom ?? 0
            let switching = host?.window?.avDisplayManager.isDisplayModeSwitchInProgress ?? false
            queue.async { [processor] in
                let r = processor.takeReport()
                NSLog(
                    "[LambentHDR] frames %d late %d gpu_ms mean %.3f p95 %.3f floor %.3f lift %.3f edr_headroom %.2f switching %@ %@",
                    r.frames, r.late, r.meanMs, r.p95Ms, r.floor, r.lift, headroom, switching ? "yes" : "no", r.format)
            }
        }
    }

    private nonisolated static func sampleBuffer(_ buffer: CVPixelBuffer, at hostTime: CFTimeInterval) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: CMTime(seconds: hostTime, preferredTimescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing,
            sampleBufferOut: &sample)
        return sample
    }
}

/// The lifted picture's view: its layer is the sample-buffer layer.
private final class LiftView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
}

/// The GPU pass, off the main thread: Deepen blacks' bend and the lift in one
/// Metal kernel, 8- or 10-bit 4:2:0 BT.709 in, P010 BT.2020 PQ out.
final class LambentLiftProcessor: @unchecked Sendable {
    struct Report {
        var frames = 0, late = 0
        var meanMs = 0.0, p95Ms = 0.0
        var floor: Float = -1, lift: Float = 0
        var format = ""
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var cache: CVMetalTextureCache?
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
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
            let library = try? device.makeLibrary(source: liftSource, options: nil),
            let function = library.makeFunction(name: "lift"),
            let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        // A TV's stream (docs/HDR_FALLBACK.md in Lambent): 1000-nit peak, contrast 100, middle grey 50.
        curve = LambentToneParams(peak: 1000).table
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    /// Before the first frame of a session (nothing is queued yet).
    func reset(deepen: Bool) {
        self.deepen = deepen
        blacks.reset()
        frameIndex = 0
    }

    func process(_ picture: CVPixelBuffer, deadline: CFTimeInterval) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(picture), h = CVPixelBufferGetHeight(picture)
        let pixelFormat = CVPixelBufferGetPixelFormatType(picture)
        let tenBit = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        format = "\(w)x\(h) \(tenBit ? "10" : "8")-bit"
        if deepen, frameIndex % 4 == 0 {
            blacks.measure(picture, tenBit: tenBit, at: CACurrentMediaTime())
        }
        frameIndex += 1
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
        encoder.setComputePipelineState(pipeline)
        encoder.setTextures([inY, inC, outY, outC], range: 0..<4)
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

    func takeReport() -> Report {
        defer { gpuMs.removeAll(keepingCapacity: true); late = 0 }
        var r = Report(frames: gpuMs.count, late: late, floor: blacks.floor, lift: blacks.lift, format: format)
        if !gpuMs.isEmpty {
            let sorted = gpuMs.sorted()
            r.meanMs = sorted.reduce(0, +) / Double(sorted.count)
            r.p95Ms = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        }
        return r
    }

    private func texture(_ buffer: CVPixelBuffer, _ plane: Int, _ format: MTLPixelFormat) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, cache!, buffer, nil, format, CVPixelBufferGetWidthOfPlane(buffer, plane),
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

    kernel void lift(texture2d<float> inY [[texture(0)]], texture2d<float> inC [[texture(1)]],
                     texture2d<float, access::write> outY [[texture(2)]], texture2d<float, access::write> outC [[texture(3)]],
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
            float3 e = expand(rgb, p, curve);
            float yp = dot(e, float3(0.2627, 0.6780, 0.0593));
            sum += float2((e.b - yp) / 1.8814, (e.r - yp) / 1.4746);
            outY.write(float4((yp * 876.0 + 64.0) * 64.0 / 65535.0), gid * 2 + uint2(n & 1, n >> 1));
        }
        outC.write(float4((sum * 0.25 * 896.0 + 512.0) * 64.0 / 65535.0, 0, 0), gid);
    }
    """

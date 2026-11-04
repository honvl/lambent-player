import AVFoundation
import AVKit
import AetherEngine
import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import UIKit
import os

/// Lambent Enhance's steps on the device: the upscale and the HDR lift, each only when Lambent Server's plan asks
/// (LambentClientUpscale.swift). There is no setting: without Lambent Enhance or a trial, and on a direct play, the plan has no
/// step and AVPlayer shows the picture.
///
/// AetherEngine plays the title through AVPlayer as usual. Its frames are
/// taken from an `AVPlayerItemVideoOutput`, lifted on the GPU (Lambent's
/// TrueHDR-fitted tone curve, and optionally Deepen blacks), and presented as
/// BT.2020 PQ in an `AVSampleBufferDisplayLayer` laid over the hidden
/// `AVPlayerLayer`. The panel is asked for HDR10 at the film's rate.
///
/// `cup` in the enhanced stream's URL upscales (the AI upscaler on the Neural Engine, else a shader; LambentLiftProcessor.swift; the
/// picture keeps the PC's colours, SDR or HDR10, an HDR10 one through the shaders: the AI upscaler's network was trained on SDR),
/// `chdr=1` lifts an SDR picture to HDR10. The Apple TV does what the plan asks (`LambentClientUpscale.appleTVWork`); the iPad only
/// what is worth its power (`LambentClientUpscale.iPadWork`); else AVPlayer shows the picture itself. A Dolby Vision stream is left
/// to AVPlayer, which keeps its metadata. In a compare (`cmp=1`, the PC's original on the left half) only the right half is done
/// here, over AVPlayer's own picture. Logs `[LambentHDR]` lines every 2 s.
@MainActor
final class LambentHDRLift {
    private weak var playerLayer: AVPlayerLayer?
    private weak var item: AVPlayerItem?
    private weak var host: UIView?
    private var output: AVPlayerItemVideoOutput?
    private let liftView = LiftView()
    private var displayLayer: AVSampleBufferDisplayLayer { liftView.layer as! AVSampleBufferDisplayLayer }
    private var link: CADisplayLink?
    private let processor: LambentLiftProcessor
    private let queue = DispatchQueue(label: "lambent.hdr-lift", qos: .userInteractive)
    /// The AI upscaler's first two stages, each a picture ahead of the next: the pack on the GPU, then the network on the Neural Engine;
    /// `queue` finishes on the GPU.
    private let packQueue = DispatchQueue(label: "lambent.hdr-lift.pack", qos: .userInteractive)
    private let neuralQueue = DispatchQueue(label: "lambent.hdr-lift.neural", qos: .userInteractive)
    /// Seconds from fetching a picture to handing it to the display layer, smoothed (`queue` writes it, the main thread reads it).
    private let latency = OSAllocatedUnfairLock(initialState: 0.0)
    private var frameRate: Double = 24
    private var lastReport = CACurrentMediaTime()
    private var requestedHDR = false
    private var started = false
    private var hdr = false
    /// The plan's most lines for the client's upscale (`cup`); nil: the plan does not ask.
    private var maxHeight: Int?
    /// The plan gives this device the HDR lift (`chdr=1`).
    private var liftAsked = false
    /// A compare stream: the left half stays AVPlayer's.
    private var compare = false
    /// What the player's chip and panel call the upscale running here (`LambentClientUpscale.label`), nil when none is; called on the
    /// main thread when it changes.
    var onUpscale: ((String?) -> Void)?
    private var reportedLabel: String?
    /// How far ahead of the next vsync a picture is fetched and shown, so the processing time does not put the picture behind the
    /// sound (0 when a picture is ready by the next vsync).
    private var lead: CFTimeInterval = 0
    /// Pictures handed to the stages and not yet shown; a new one is dropped at 3 (the network's slots), so a slow picture never queues
    /// more behind it.
    private let inFlight = OSAllocatedUnfairLock(initialState: 0)

    init?() {
        guard let processor = LambentLiftProcessor() else { return nil }
        self.processor = processor
    }

    var isRunning: Bool { output != nil }

    /// Starts on the engine's AVPlayer once its item exists, only when the plan asks (`planHeight`, its `cup`; `lift`, its `chdr=1`),
    /// and not for Dolby Vision; `compare`: the stream is a compare (`cmp=1`).
    func start(engine: AetherEngine, in view: UIView, planHeight: Int?, lift: Bool, compare: Bool) -> Bool {
        guard planHeight != nil || lift, engine.sourceVideoFormat != .dolbyVision else { return false }
        guard output == nil, let layer = engine.nativePlayerLayer, let item = layer.player?.currentItem
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
        // A compare keeps AVPlayer's picture under the lifted right half.
        output.suppressesPlayerRendering = !compare
        item.add(output)
        self.output = output
        self.item = item
        self.playerLayer = layer
        host = view
        frameRate = engine.sourceVideoFrameRate ?? 24
        hdr = false
        maxHeight = planHeight
        liftAsked = lift
        self.compare = compare
        liftView.rightHalfOnly = compare
        started = false
        lead = 0
        processor.reset(deepen: false)
        processor.hdr = hdr
        processor.sourceBitrate = engine.sourceVideoBitrate
        processor.outputSize = nil
        processor.pipelined = true
        latency.withLock { $0 = 0 }

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
        layer.opacity = compare ? 1 : 0

        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        NSLog("[LambentHDR] started fps %.3f bitrate %lld plan %@%@%@", frameRate, engine.sourceVideoBitrate,
            planHeight.map { "cup=\($0)" } ?? "none", lift ? " chdr" : "", compare ? " compare" : "")
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
        #if os(tvOS)
            if requestedHDR, let window = host?.window {
                window.avDisplayManager.preferredDisplayCriteria = nil
            }
        #endif
        requestedHDR = false
        report(label: nil)
        started = false
        host = nil
    }

    /// Asks the panel for HDR10 at the film's rate. AetherEngine programmed SDR
    /// criteria for an SDR source at load; this replaces them.
    private func requestHDR10(in view: UIView, width: Int, height: Int) {
        requestedHDR = true
        #if os(tvOS)
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
        #endif
    }

    /// Tells the player what upscales here, when that changes.
    private func report(label: String?) {
        guard label != reportedLabel else { return }
        reportedLabel = label
        onUpscale?(label)
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let output else { return }
        let target = link.targetTimestamp + lead
        let itemTime = output.itemTime(forHostTime: target)
        if output.hasNewPixelBuffer(forItemTime: itemTime),
            let source = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
        {
            if !started {
                started = true
                // The first picture says what the stream really is (the probe can call it SDR). A lift puts the panel in HDR10 at
                // the picture's size.
                let transfer = CVBufferCopyAttachment(source, kCVImageBufferTransferFunctionKey, nil) as? String
                let alreadyHDR = transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
                    || transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
                let w = CVPixelBufferGetWidth(source), h = CVPixelBufferGetHeight(source)
                guard let host, let screen = host.window?.screen else { stop(); return }
                #if os(tvOS)
                    // What the plan asks: the lift, the upscale (to the screen, in its own pixels: 3840 x 2160 on a 4K panel, up to the
                    // plan's lines), both, or neither (AVPlayer shows it).
                    let fitted = LambentClientUpscale.outputSize(
                        picture: (w, h), bounds: screen.nativeBounds.size, scale: 1, maxHeight: maxHeight)
                    let work = LambentClientUpscale.appleTVWork(
                        liftAsked: liftAsked, sourceHDR: alreadyHDR, upscaleAsked: maxHeight != nil, picture: (w, h), fitted: fitted)
                #else
                    // Only the work worth the iPad's power: the lift, the upscale (to the player's place on the screen, in pixels, up to
                    // the plan's lines), both, or neither (AVPlayer shows it).
                    let fitted = LambentClientUpscale.outputSize(
                        picture: (w, h), bounds: host.bounds.size, scale: screen.nativeScale, maxHeight: maxHeight)
                    let work = LambentClientUpscale.iPadWork(
                        liftAsked: liftAsked, sourceHDR: alreadyHDR, headroom: screen.potentialEDRHeadroom,
                        lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, upscaleAsked: maxHeight != nil, picture: (w, h),
                        fitted: fitted)
                #endif
                guard let work else {
                    NSLog("[LambentHDR] %dx%d to %dx%d, %@: nothing to do here: AVPlayer shows it", w, h, fitted.0, fitted.1,
                        alreadyHDR ? "HDR" : "SDR")
                    stop()
                    report(label: LambentClientUpscale.notNeeded)
                    return
                }
                hdr = work.hdr
                processor.hdr = hdr
                processor.outputSize = work.size
                // The PC's HDR10 keeps its colours (upscaling only); the shaders take it.
                if alreadyHDR {
                    NSLog("[LambentHDR] the stream is HDR (%@): upscaling with the shaders", transfer ?? "")
                    processor.skipNeural()
                }
                processor.frameRate = frameRate
                if !hdr && !processor.scales(w, h) {
                    NSLog("[LambentHDR] %dx%d: no lift and nothing to upscale: AVPlayer shows it", w, h)
                    stop()
                    report(label: LambentClientUpscale.notNeeded)
                    return
                }
                if hdr { requestHDR10(in: host, width: w, height: h) }
                updateLead(link)
                NSLog("[LambentHDR] first picture %dx%d, %@ at %.3f Hz, shown at %@, scaler %@", w, h, hdr ? "HDR10" : "SDR", frameRate,
                    processor.outputSize.map { "\($0.0)x\($0.1)" } ?? "its own size", "\(processor.scaler)")
                report(label: LambentClientUpscale.label(hdr: hdr, scaler: processor.scales(w, h) ? processor.scaler : nil))
            }
            let renderer = displayLayer.sampleBufferRenderer
            let processor = processor
            let inFlight = inFlight
            let taken = inFlight.withLock { n -> Bool in
                guard n < LambentNeuralScaler.slotCount else { return false }
                n += 1
                return true
            }
            if taken {
                let fetched = CACurrentMediaTime()
                let queue = queue, latency = latency, neuralQueue = neuralQueue
                packQueue.async {
                  let packed = processor.pack(source)
                  neuralQueue.async {
                    let prepared = packed.flatMap { processor.infer($0) }
                    queue.async {
                        defer { inFlight.withLock { $0 -= 1 } }
                        guard let lifted = processor.process(source, deadline: target, prepared: prepared),
                            let sample = Self.sampleBuffer(lifted, at: target)
                        else { return }
                        renderer.enqueue(sample)
                        let took = CACurrentMediaTime() - fetched
                        latency.withLock { $0 = $0 == 0 ? took : $0 + (took - $0) * 0.05 }
                    }
                  }
                }
            }
        }
        let now = CACurrentMediaTime()
        if now - lastReport >= 2 {
            lastReport = now
            updateLead(link)
            let headroom = host?.window?.screen.currentEDRHeadroom ?? 0
            #if os(tvOS)
                let switching = host?.window?.avDisplayManager.isDisplayModeSwitchInProgress ?? false
            #else
                let switching = false
            #endif
            let hdr = hdr
            queue.async { [processor] in
                let r = processor.takeReport()
                // The ladder may have stepped down (or to none) since the last report.
                let label = r.frames > 0
                    ? LambentClientUpscale.label(
                        hdr: hdr, scaler: processor.outputSize != nil && r.format.contains("->") ? processor.scaler : nil) : nil
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.output != nil else { return }
                    self.report(label: label)
                }
                NSLog(
                    "[LambentHDR] frames %d late %d gpu_ms mean %.3f p95 %.3f ane_ms %.3f floor %.3f lift %.3f edr_headroom %.2f switching %@ %@ %@",
                    r.frames, r.late, r.meanMs, r.p95Ms, r.engineMs, r.floor, r.lift, headroom, switching ? "yes" : "no", r.format, r.scaler)
            }
        }
    }

    /// As many vsyncs ahead as a picture takes from fetch to display layer, less the one the display link already gives (with 3 ms to
    /// spare). With the AI upscaler that is its three stages, a picture apart, so pictures are fetched two or three film frames ahead;
    /// the shaders fit in one. Before the first measurement, the AI upscaler counts as 60 ms. Changes only when that count of vsyncs does (one picture is skipped or repeated then).
    private func updateLead(_ link: CADisplayLink) {
        let d = max(link.duration, 1.0 / 120)
        var took = latency.withLock { $0 }
        if took == 0 { took = processor.scaler.isNeural ? 0.060 : 0 }
        let want = d * min(8, max(0, ceil((took + 0.003) / d) - 1))
        if abs(want - lead) > 0.001 { lead = want }
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

    /// A compare: only the right half shows, the original (AVPlayer's own picture) shows through on the left.
    var rightHalfOnly = false {
        didSet {
            layer.mask = rightHalfOnly ? CALayer() : nil
            layer.mask?.backgroundColor = UIColor.black.cgColor
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.mask?.frame = CGRect(x: bounds.midX, y: 0, width: bounds.width - bounds.midX, height: bounds.height)
    }
}

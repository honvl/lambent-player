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
/// On by default whenever Enhance on PC is off (the server then direct-plays);
/// Settings > Lambent enhancement > HDR on this TV turns it off. Flutter stores
/// both as `flutter.pref_lambent_enhance_on_pc` / `flutter.pref_lambent_client_hdr`. Logs `[LambentHDR]`
/// lines every 2 s.
@MainActor
final class LambentHDRLift {
    /// On while Enhance on PC is off (Flutter's defaults: Enhance on PC on, HDR on this TV on, so an unset key is true).
    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        let enhanceOnPc = defaults.object(forKey: "flutter.pref_lambent_enhance_on_pc") as? Bool ?? true
        let clientHdr = defaults.object(forKey: "flutter.pref_lambent_client_hdr") as? Bool ?? true
        return !enhanceOnPc && clientHdr
    }
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
                let w = CVPixelBufferGetWidth(source), h = CVPixelBufferGetHeight(source)
                if let view = host {
                    requestHDR10(in: view, width: w, height: h)
                    // Upscaled here to its place on the screen, in the screen's own pixels (3840 x 2160 on a 4K panel).
                    if let screen = view.window?.screen {
                        let native = screen.nativeBounds.size
                        let k = min(native.width / CGFloat(w), native.height / CGFloat(h))
                        processor.outputSize = (Int(CGFloat(w) * k), Int(CGFloat(h) * k))
                    }
                }
                processor.frameRate = frameRate
                NSLog("[LambentHDR] first picture %dx%d, HDR10 requested at %.3f Hz, shown at %@, scaler %@", w, h, frameRate,
                    processor.outputSize.map { "\($0.0)x\($0.1)" } ?? "its own size", "\(processor.scaler)")
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
                    "[LambentHDR] frames %d late %d gpu_ms mean %.3f p95 %.3f floor %.3f lift %.3f edr_headroom %.2f switching %@ %@ %@",
                    r.frames, r.late, r.meanMs, r.p95Ms, r.floor, r.lift, headroom, switching ? "yes" : "no", r.format, r.scaler)
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

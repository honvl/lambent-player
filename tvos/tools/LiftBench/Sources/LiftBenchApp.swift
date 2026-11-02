import AVFoundation
import SwiftUI
import UIKit

// Plays each clip through the processor with one scaler at a time (and once with the player's own ladder, which steps down when a
// scaler does not fit the frame), 12 s each, at the screen's 4K size. Prints BENCH lines: GPU ms a picture (mean, p95), pictures late
// for their vsync, and pictures shown against the clip's rate.
@main
struct LiftBenchApp: App {
    var body: some Scene { WindowGroup { BenchView() } }
}

struct BenchView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = PlayerHost()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { v.run() }
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

final class LayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
}

final class PlayerHost: UIView {
    private let shown = LayerView()
    private var link: CADisplayLink?
    private var output: AVPlayerItemVideoOutput?
    private var player: AVPlayer?
    private var processor: LambentLiftProcessor?
    private let queue = DispatchQueue(label: "bench", qos: .userInteractive)
    private var runs: [(String, String, [LambentLiftProcessor.Scaler]?)] = []
    private var runStart = 0.0, lastReport = 0.0, enqueued = 0
    private var label = ""

    func run() {
        backgroundColor = .black
        shown.frame = bounds
        shown.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        (shown.layer as! AVSampleBufferDisplayLayer).videoGravity = .resizeAspect
        addSubview(shown)
        let ravu = LambentLiftProcessor.Scaler.prescaler("ravu-lite-ar-r3"), fsr = LambentLiftProcessor.Scaler.prescaler("FSRCNNX_x2_8-0-4-1")
        print("BENCH device \(MTLCreateSystemDefaultDevice()?.name ?? "?") apple10 \(MTLCreateSystemDefaultDevice()?.supportsFamily(.apple10) ?? false)")
        for clip in ["sdr1080p24", "sdr1080p60"] {
            for sc in [LambentLiftProcessor.Scaler.none, .catmullRom, ravu, fsr] { runs.append((clip, "\(sc)", [sc])) }
            runs.append((clip, "ladder from FSRCNNX", [fsr, ravu, .catmullRom, .none]))
            runs.append((clip, "player's own ladder", nil))
        }
        next()
    }

    private func next() {
        link?.invalidate()
        player?.pause()
        guard !runs.isEmpty else { print("BENCH done"); return }
        let (clip, name, ladder) = runs.removeFirst()
        label = "\(clip) \(name)"
        guard let url = Bundle.main.url(forResource: "Videos/\(clip)", withExtension: "mp4"), let processor = LambentLiftProcessor() else {
            print("BENCH \(label): missing clip or processor"); return next()
        }
        processor.reset(deepen: true)
        if let ladder { processor.force(ladder: ladder) }
        processor.outputSize = (3840, 2160)
        processor.frameRate = clip.hasSuffix("60") ? 59.94 : 23.976
        self.processor = processor
        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange],
            kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        output.suppressesPlayerRendering = true
        item.add(output)
        self.output = output
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        self.player = player
        let layer = shown.layer as! AVSampleBufferDisplayLayer
        layer.sampleBufferRenderer.flush()
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        CMTimebaseSetTime(timebase!, time: CMClockGetTime(CMClockGetHostTimeClock()))
        CMTimebaseSetRate(timebase!, rate: 1)
        layer.controlTimebase = timebase
        player.play()
        runStart = CACurrentMediaTime(); lastReport = runStart; enqueued = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let output, let processor else { return }
        let target = link.targetTimestamp
        let t = output.itemTime(forHostTime: target)
        if output.hasNewPixelBuffer(forItemTime: t), let source = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
            let renderer = (shown.layer as! AVSampleBufferDisplayLayer).sampleBufferRenderer
            queue.async { [weak self] in
                guard let lifted = processor.process(source, deadline: target) else { return }
                var format: CMVideoFormatDescription?
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: lifted, formatDescriptionOut: &format)
                var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: target, preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
                var sample: CMSampleBuffer?
                CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: lifted, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
                if let sample { renderer.enqueue(sample) }
                DispatchQueue.main.async { self?.enqueued += 1 }
            }
        }
        let now = CACurrentMediaTime()
        if now - lastReport >= 3 {
            let secs = now - lastReport
            lastReport = now
            let shownCount = enqueued
            enqueued = 0
            let label = label
            queue.async {
                let r = processor.takeReport()
                print(String(format: "BENCH %@: %@ gpu_ms mean %.2f p95 %.2f late %d shown %.1f fps (%@) thermal %d", label, r.format, r.meanMs, r.p95Ms,
                             r.late, Double(shownCount) / secs, r.scaler, ProcessInfo.processInfo.thermalState.rawValue))
            }
        }
        if now - runStart > 12 { next() }
    }
}

import AVFoundation
import os
import SwiftUI
import UIKit

// First the capacity of each scaler: 240 pictures back to back through the processor, as the player runs it (one at a time, waited
// for), wall-clock ms a picture: what it can keep up with once the GPU's clock has risen. Then each clip played through the processor
// with one scaler at a time (and with the player's own ladder, which steps down when pictures keep missing their vsync), 12 s each,
// at the screen's 4K size, the display at the clip's rate as an Apple TV's is after its mode switch. Prints BENCH lines: GPU ms a
// picture (mean, p95; it follows the GPU's clock, which drops when there is room), pictures late for their vsync, pictures shown a
// second.
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
    private let neuralQueue = DispatchQueue(label: "bench.neural", qos: .userInteractive)
    private let inFlight = OSAllocatedUnfairLock(initialState: 0)
    private var runs: [(String, String, [LambentLiftProcessor.Scaler]?)] = []
    /// Runs whose pictures are processed but not shown: an iPhone's compositor scales and tone-maps every 4K HDR picture to its own
    /// screen, which an Apple TV showing 4K on a 4K panel does not.
    private var hideOutput = false
    private var runStart = 0.0, lastReport = 0.0, enqueued = 0
    private var label = ""
    private var endObserver: NSObjectProtocol?

    func run() {
        backgroundColor = .black
        shown.frame = bounds
        shown.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        (shown.layer as! AVSampleBufferDisplayLayer).videoGravity = .resizeAspect
        addSubview(shown)
        let ravu = LambentLiftProcessor.Scaler.prescaler("ravu-lite-ar-r3"), fsr = LambentLiftProcessor.Scaler.prescaler("FSRCNNX_x2_8-0-4-1")
        // The screen must not lock mid-run: a backgrounded app's GPU work is throttled.
        UIApplication.shared.isIdleTimerDisabled = true
        print("BENCH device \(MTLCreateSystemDefaultDevice()?.name ?? "?") apple10 \(MTLCreateSystemDefaultDevice()?.supportsFamily(.apple10) ?? false) low power \(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        if let p = LambentLiftProcessor() { print("BENCH ladder \(p.ladder) failures \(LambentPrescaler.failures)") }
        let ai = LambentLiftProcessor.Scaler.neural
        if let device = MTLCreateSystemDefaultDevice() {
            for n in LambentNeuralScaler.networks {
                let t = CACurrentMediaTime()
                let s = LambentNeuralScaler.loadNow(n, device: device)
                print(String(format: "BENCH AI upscaler %@ %@ in %.0f ms %@", n, s != nil ? "loaded" : "did not load",
                             (CACurrentMediaTime() - t) * 1000, LambentNeuralScaler.failures[n] ?? ""))
            }
        }
        if let device = MTLCreateSystemDefaultDevice(), let s = LambentNeuralScaler.loadNow("neural-low", device: device) {
            _ = s.timeNetwork(10)
            print(String(format: "BENCH AI upscaler network alone, back to back: %.2f ms", s.timeNetwork(100)))
        }
        // LIFT_NEURAL in the environment: the AI upscaler only (capacity, playback at 24 and 60 fps, SDR out, a long run).
        if ProcessInfo.processInfo.environment["LIFT_NEURAL"] != nil {
            capacity([ai, ravu])
            runs = [("sdr1080p24", "AI upscaler", [ai]), ("sdr1080p24", "AI upscaler SDR out", [ai]),
                    ("sdr1080p60", "AI upscaler hidden", [ai]), ("sdr1080p24", "player's own ladder", nil),
                    ("sdr1080p60", "player's own ladder hidden", nil), ("sdr1080p24", "AI upscaler long", [ai])]
            return next()
        }
        capacity([.none, .catmullRom, ravu, fsr, ai])
        for clip in ["sdr1080p24", "sdr1080p60"] {
            for sc in [LambentLiftProcessor.Scaler.none, .catmullRom, ravu, fsr, ai] { runs.append((clip, "\(sc)", [sc])) }
            runs.append((clip, "ladder from FSRCNNX", [fsr, ravu, .catmullRom, .none]))
            runs.append((clip, "player's own ladder", nil))
        }
        var first: [(String, String, [LambentLiftProcessor.Scaler]?)] = [ravu, fsr].map { ("sdr1080p60", "\($0) hidden", [$0]) }
        first.append(("sdr1080p60", "ladder from FSRCNNX hidden", [fsr, ravu, .catmullRom, .none]))
        runs = first + runs
        // LIFT_QUICK in the environment: the ladders only.
        if (ProcessInfo.processInfo.environment["LIFT_QUICK"] != nil) {
            runs = [("sdr1080p24", "ladder from FSRCNNX", [fsr, ravu, .catmullRom, .none]),
                    ("sdr1080p60", "ladder from FSRCNNX hidden", [fsr, ravu, .catmullRom, .none]),
                    ("sdr1080p24", "player's own ladder", nil), ("sdr1080p60", "player's own ladder hidden", nil)]
        }
        next()
    }

    private func capacity(_ scalers: [LambentLiftProcessor.Scaler]) {
        guard let url = Bundle.main.url(forResource: "Videos/sdr1080p24", withExtension: "mp4") else { return }
        let asset = AVURLAsset(url: url)
        guard let reader = try? AVAssetReader(asset: asset), let track = asset.tracks(withMediaType: .video).first else { return }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        reader.add(out)
        reader.startReading()
        var pictures: [CVPixelBuffer] = []
        while pictures.count < 24, let s = out.copyNextSampleBuffer() { if let b = CMSampleBufferGetImageBuffer(s) { pictures.append(b) } }
        // A fingerprint of each scaler's output on the first picture (mean Y' code, and mean |difference| from Catmull-Rom's), to
        // compare with the same on a Mac: a prescaler that skipped passes would not match.
        var catrom: CVPixelBuffer?
        for sc in [LambentLiftProcessor.Scaler.catmullRom] + scalers {
            guard let p = LambentLiftProcessor() else { continue }
            p.force(sc)
            p.outputSize = (3840, 2160)
            guard let o = p.process(pictures[0], deadline: .infinity) else { continue }
            if sc == .catmullRom && catrom == nil { catrom = o; continue }
            print(String(format: "BENCH fingerprint %@: %@", "\(sc)", fingerprint(o, catrom)))
        }
        // The AI upscaler twice: its network for a low bitrate (neural-low) and for a high one (neural-hb).
        let timed = scalers.flatMap { sc -> [(LambentLiftProcessor.Scaler, Int64)] in sc == .neural ? [(sc, Int64(0)), (sc, Int64(200_000_000))] : [(sc, Int64(0))] }
        for (sc, bitrate) in timed {
            guard let p = LambentLiftProcessor() else { continue }
            p.reset(deepen: true)
            p.force(sc)
            p.sourceBitrate = bitrate
            p.outputSize = (3840, 2160)
            for i in 0..<48 { _ = p.process(pictures[i % pictures.count], deadline: .infinity) }
            _ = p.takeReport()
            let start = CACurrentMediaTime()
            for i in 0..<240 { _ = p.process(pictures[i % pictures.count], deadline: .infinity) }
            let wall = (CACurrentMediaTime() - start) * 1000 / 240
            var r = p.takeReport()
            if sc == .neural {
                print(String(format: "BENCH capacity %@ one after the other: %.2f ms a picture (%.0f fps), GPU %.2f ms, Neural Engine %.2f ms",
                             r.scaler, wall, 1000 / wall, r.meanMs, r.engineMs))
                // Pipelined, as the player runs it: the network for picture N + 1 while the GPU finishes picture N.
                p.pipelined = true
                let a = DispatchQueue(label: "cap.a"), b = DispatchQueue(label: "cap.b"), gate = DispatchSemaphore(value: 2)
                let group = DispatchGroup()
                let t0 = CACurrentMediaTime()
                for i in 0..<240 {
                    gate.wait()
                    group.enter()
                    let pic = pictures[i % pictures.count]
                    a.async {
                        let prepared = p.prepare(pic)
                        b.async { _ = p.process(pic, deadline: .infinity, prepared: prepared); gate.signal(); group.leave() }
                    }
                }
                group.wait()
                let piped = (CACurrentMediaTime() - t0) * 1000 / 240
                r = p.takeReport()
                print(String(format: "BENCH capacity %@ pipelined: %.2f ms a picture (%.0f fps), GPU %.2f ms, Neural Engine %.2f ms, thermal %d",
                             r.scaler, piped, 1000 / piped, r.meanMs, r.engineMs, ProcessInfo.processInfo.thermalState.rawValue))
                continue
            }
            print(String(format: "BENCH capacity %@: %.2f ms a picture back to back (%.0f fps), GPU %.2f ms, Neural Engine %.2f ms, thermal %d",
                         r.scaler, wall, 1000 / wall, r.meanMs, r.engineMs, ProcessInfo.processInfo.thermalState.rawValue))
        }
    }

    func fingerprint(_ a: CVPixelBuffer, _ b: CVPixelBuffer?) -> String {
        CVPixelBufferLockBaseAddress(a, .readOnly); defer { CVPixelBufferUnlockBaseAddress(a, .readOnly) }
        if let b { CVPixelBufferLockBaseAddress(b, .readOnly) }
        defer { if let b { CVPixelBufferUnlockBaseAddress(b, .readOnly) } }
        let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a), ra = CVPixelBufferGetBytesPerRowOfPlane(a, 0)
        let pa = CVPixelBufferGetBaseAddressOfPlane(a, 0)!
        let pb = b.flatMap { CVPixelBufferGetBaseAddressOfPlane($0, 0) }, rb = b.map { CVPixelBufferGetBytesPerRowOfPlane($0, 0) } ?? 0
        var sum = 0.0, diff = 0.0, n = 0.0
        for y in stride(from: 0, to: h, by: 2) { for x in stride(from: 0, to: w, by: 2) {
            let va = Double(pa.load(fromByteOffset: y * ra + x * 2, as: UInt16.self) >> 6)
            sum += va
            if let pb { diff += abs(va - Double(pb.load(fromByteOffset: y * rb + x * 2, as: UInt16.self) >> 6)) }
            n += 1
        } }
        return String(format: "%dx%d mean Y %.3f, mean |diff| from Catmull-Rom %.4f", w, h, sum / n, diff / n)
    }

    private func next() {
        link?.invalidate()
        player?.pause()
        guard !runs.isEmpty else { print("BENCH done"); return }
        let (clip, name, ladder) = runs.removeFirst()
        label = "\(clip) \(name)"
        hideOutput = name.hasSuffix("hidden")
        let h = hideOutput
        hiddenFlag.withLock { $0 = h }
        guard let url = Bundle.main.url(forResource: "Videos/\(clip)", withExtension: "mp4"), let processor = LambentLiftProcessor() else {
            print("BENCH \(label): missing clip or processor"); return next()
        }
        processor.reset(deepen: !name.contains("SDR out"))
        processor.hdr = !name.contains("SDR out")
        processor.pipelined = true
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
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if name.hasSuffix("long") {
            // The 20 s clip again and again, for a sustained run.
            player.actionAtItemEnd = .none
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) {
                [weak player] _ in player?.seek(to: .zero)
            }
        }
        player.play()
        runStart = CACurrentMediaTime(); lastReport = runStart; enqueued = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private var hiddenNow: Bool { hiddenFlag.withLock { $0 } }
    private let hiddenFlag = OSAllocatedUnfairLock(initialState: false)

    @objc private func tick(_ link: CADisplayLink) {
        guard let output, let processor else { return }
        let target = link.targetTimestamp
        let t = output.itemTime(forHostTime: target)
        if output.hasNewPixelBuffer(forItemTime: t), let source = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
            let renderer = (shown.layer as! AVSampleBufferDisplayLayer).sampleBufferRenderer
            // As the player does it: the network a picture ahead on its own queue, at most two pictures in flight.
            let taken = inFlight.withLock { n -> Bool in
                guard n < 2 else { return false }
                n += 1
                return true
            }
            guard taken else { return }
            let queue = queue, inFlight = inFlight
            neuralQueue.async { [weak self] in
              let prepared = processor.prepare(source)
              queue.async { [weak self] in
                defer { inFlight.withLock { $0 -= 1 } }
                guard let lifted = processor.process(source, deadline: target, prepared: prepared) else { return }
                var format: CMVideoFormatDescription?
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: lifted, formatDescriptionOut: &format)
                var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: target, preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
                var sample: CMSampleBuffer?
                CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: lifted, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
                if let sample, !(self?.hiddenNow ?? false) { renderer.enqueue(sample) }
                DispatchQueue.main.async { self?.enqueued += 1 }
              }
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
                print(String(format: "BENCH %@: %@ gpu_ms mean %.2f p95 %.2f ane_ms %.2f late %d shown %.1f fps (%@) thermal %d", label, r.format,
                             r.meanMs, r.p95Ms, r.engineMs, r.late, Double(shownCount) / secs, r.scaler, ProcessInfo.processInfo.thermalState.rawValue))
            }
        }
        let length: Double = label.hasSuffix("long") ? 300 : (ProcessInfo.processInfo.environment["LIFT_QUICK"] != nil) ? 15 : 12
        if now - runStart > length { next() }
    }
}

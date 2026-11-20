import AVFoundation
import os
import SwiftUI
import UIKit
import VideoToolbox

// With no LIFT_* variable (an Apple TV started from its home screen): the Apple TV run (`appleTV`): Lambent Server's own models timed
// on this chip (ServerBench.swift), then the player's floor, the AI upscaler with Auto HDR's sixteen tables at 24, 30 and 60 fps, its summary
// on the screen. LIFT_SCALERS: the older run below, every scaler.
//
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
    private let packQueue = DispatchQueue(label: "bench.pack", qos: .userInteractive)
    private let inFlight = OSAllocatedUnfairLock(initialState: 0)
    private var runs: [(String, String, [LambentLiftProcessor.Scaler]?)] = []
    /// Runs whose pictures are processed but not shown: an iPhone's compositor scales and tone-maps every 4K HDR picture to its own
    /// screen, which an Apple TV showing 4K on a 4K panel does not.
    private var hideOutput = false
    private var runStart = 0.0, lastReport = 0.0, enqueued = 0
    private var label = ""
    private var endObserver: NSObjectProtocol?
    /// Where each run's pictures go, and whether the lift is on (off: upscaling only, the iPad).
    private var runSize = (3840, 2160)
    private var runHDR = true

    func run() {
        backgroundColor = .black
        shown.frame = bounds
        shown.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        (shown.layer as! AVSampleBufferDisplayLayer).videoGravity = .resizeAspect
        addSubview(shown)
        summaryLabel.frame = bounds.insetBy(dx: 60, dy: 40)
        summaryLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        summaryLabel.numberOfLines = 0
        summaryLabel.textColor = .white
        summaryLabel.shadowColor = .black
        summaryLabel.font = .monospacedSystemFont(ofSize: 21, weight: .regular)
        summaryLabel.textAlignment = .left
        summaryLabel.contentMode = .top
        addSubview(summaryLabel)
        BenchLog.onSummary = { [weak self] text in self?.show(text) }
        let ravu = LambentLiftProcessor.Scaler.prescaler("ravu-lite-ar-r3"), fsr = LambentLiftProcessor.Scaler.prescaler("FSRCNNX_x2_8-0-4-1")
        // The screen must not lock mid-run: a backgrounded app's GPU work is throttled.
        UIApplication.shared.isIdleTimerDisabled = true
        print("BENCH device \(MTLCreateSystemDefaultDevice()?.name ?? "?") apple10 \(MTLCreateSystemDefaultDevice()?.supportsFamily(.apple10) ?? false) low power \(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        #if os(iOS)
        let scr = window?.windowScene?.screen ?? UIScreen.main
        print("BENCH screen EDR headroom potential \(scr.potentialEDRHeadroom) current \(scr.currentEDRHeadroom) HDR playback \(AVPlayer.eligibleForHDRPlayback)")
        #endif
        if let p = LambentLiftProcessor() { print("BENCH ladder \(p.ladder) failures \(LambentPrescaler.failures)") }
        // LIFT_STUDENT in the environment: the AI upscaler's Neural Engine student (`<network>-student`) wherever the bench says "AI upscaler".
        let student = ProcessInfo.processInfo.environment["LIFT_STUDENT"] != nil
        let ai = LambentLiftProcessor.Scaler.neural(fast: student)
        if let device = MTLCreateSystemDefaultDevice() {
            for int8 in [false, true] {
                LambentNeuralScaler.preferInt8 = int8
                for n in LambentNeuralScaler.networks {
                    let t = CACurrentMediaTime()
                    let s = LambentNeuralScaler.loadNow(n, student: student && !int8, device: device)
                    print(String(format: "BENCH AI upscaler %@ %@ %@ in %.0f ms %@", n, s.map { $0.int8 ? "int8" : "fp16" } ?? "", s != nil ? "loaded" : "did not load",
                                 (CACurrentMediaTime() - t) * 1000, LambentNeuralScaler.failures[n] ?? ""))
                }
            }
        }
        if let device = MTLCreateSystemDefaultDevice() {
            for int8 in [false, true] {
                LambentNeuralScaler.preferInt8 = int8
                guard let s = LambentNeuralScaler.loadNow("neural-low", student: student && !int8, device: device) else { continue }
                _ = s.timeNetwork(10)
                print(String(format: "BENCH AI upscaler network alone, back to back, %@: %.2f ms", s.f == 4 ? "student" : s.int8 ? "int8" : "fp16",
                             s.timeNetwork(100)))
            }
            // LIFT_FP16 in the environment: the fp16 models for everything after this.
            LambentNeuralScaler.preferInt8 = ProcessInfo.processInfo.environment["LIFT_FP16"] == nil
        }
        if ProcessInfo.processInfo.environment["LIFT_COMPARE"] != nil { return compare() }
        if ProcessInfo.processInfo.environment["LIFT_IPAD"] != nil { return iPad(ravu: ravu, fsr: fsr) }
        if ProcessInfo.processInfo.environment["LIFT_PLAN"] != nil {
            Task {
                await ComputePlanBench.run("neural-low")
                print("BENCH done")
            }
            return
        }
        if ProcessInfo.processInfo.environment["LIFT_EXP"] != nil {
            capacity([ai])
            print("BENCH done")
            return
        }
        // LIFT_KERNELS in the environment: the lift kernels alone.
        if ProcessInfo.processInfo.environment["LIFT_KERNELS"] != nil {
            capacity([])
            print("BENCH done")
            return
        }
        // LIFT_NEURAL in the environment: the AI upscaler only (capacity, playback at 24 and 60 fps, SDR out, a long run).
        if ProcessInfo.processInfo.environment["LIFT_NEURAL"] != nil {
            LambentNeuralScaler.preferInt8 = false
            if ProcessInfo.processInfo.environment["LIFT_LADDER"] == nil { capacity([ai]) }
            LambentNeuralScaler.preferInt8 = ProcessInfo.processInfo.environment["LIFT_FP16"] == nil
            if ProcessInfo.processInfo.environment["LIFT_LADDER"] == nil { capacity([ai, ravu]) }
            // LIFT_LADDER in the environment: the step-down alone (60 fps from the AI upscaler; 30 fps, the player's own ladder, five minutes).
            // LIFT_SIXTY: the player's own ladder at 60 fps, shown (the AI upscaler's student above 30 fps), and the student forced.
            if ProcessInfo.processInfo.environment["LIFT_SIXTY"] != nil {
                runs = [("sdr1080p60", "player's own ladder", nil), ("sdr1080p60", "AI upscaler (fast)", [.neural(fast: true)]),
                        ("sdr1080p30", "player's own ladder", nil), ("sdr1080p60", "player's own ladder long", nil)]
                return next()
            }
            if ProcessInfo.processInfo.environment["LIFT_LADDER"] != nil {
                runs = [("sdr1080p60", "ladder from AI upscaler hidden", [ai, ravu, .catmullRom, .none]), ("sdr1080p30", "player's own ladder long", nil)]
                return next()
            }
            runs = [("sdr1080p24", "AI upscaler", [ai]), ("sdr1080p30", "AI upscaler", [ai]), ("sdr1080p30", "AI upscaler SDR out", [ai]),
                    ("sdr1080p60", "AI upscaler hidden", [ai]), ("sdr1080p30", "player's own ladder", nil),
                    ("sdr1080p60", "player's own ladder hidden", nil), ("sdr1080p30", "AI upscaler long", [ai])]
            return next()
        }
        if ProcessInfo.processInfo.environment["LIFT_SCALERS"] == nil { return appleTV() }
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

    private let summaryLabel = UILabel()
    private var summaryLines: [String] = []

    private func show(_ text: String) {
        summaryLines.append(text)
        if summaryLines.count > 34 { summaryLines.removeFirst(summaryLines.count - 34) }
        summaryLabel.text = summaryLines.joined(separator: "\n")
        summaryLabel.sizeToFit()
        summaryLabel.frame.origin = CGPoint(x: 60, y: 40)
    }

    /// The Apple TV run: Lambent Server's models on this chip (off the main thread, so the screen keeps showing lines), then the player's
    /// own processor: the AI upscaler and its student with Auto HDR one picture after another, then each clip played with the player's own
    /// ladder and with each forced, Auto HDR on, to 4K. The floor the owner set (2026-11-17): the low AI upscaler and the sixteen tables
    /// together.
    private func appleTV() {
        BenchLog.summary("Lambent Apple TV benchmark: about 6 minutes. Keep this app open.")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            ServerBench.run()
            DispatchQueue.main.async {
                guard let self else { return }
                BenchLog.summary("The player's own processor, 1080p to 4K with Auto HDR (16 tables):")
                self.summarizeRuns = true
                self.capacity([.neural(fast: false), .neural(fast: true)])
                for clip in ["sdr1080p24", "sdr1080p30", "sdr1080p60"] {
                    self.runs.append((clip, "player's own ladder", nil))
                    self.runs.append((clip, "AI upscaler", [.neural(fast: false)]))
                    self.runs.append((clip, "AI upscaler (fast)", [.neural(fast: true)]))
                }
                self.next()
            }
        }
    }

    /// Played runs' totals for the summary (on `queue`): the first report (the GPU's clock settling) left out.
    private var summarizeRuns = false
    private var runReports = 0, runShown = 0, runSecs = 0.0, runScaler = ""

    /// The iPad's upscale: a 1080p title fit to the screen (the player full screen, capped at the plan's `cup=2160`), the picture's own
    /// SDR colours out. Each scaler's capacity, then each clip played with the player's own ladder and with each scaler alone.
    private func iPad(ravu: LambentLiftProcessor.Scaler, fsr: LambentLiftProcessor.Scaler) {
        let screen = window?.windowScene?.screen ?? UIScreen.main
        runSize = LambentClientUpscale.outputSize(picture: (1920, 1080), bounds: bounds.size, scale: screen.nativeScale, maxHeight: 2160)
        runHDR = false
        print("BENCH iPad \(Int(bounds.width))x\(Int(bounds.height)) pt at \(screen.nativeScale): 1920x1080 -> \(runSize.0)x\(runSize.1)")
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
        // The HDR lift on the iPad (SDR in, HDR10 out): at the picture's own size, and in Catmull-Rom's last pass at the screen's.
        for (what, size, sc) in [("1080p at its size", nil, LambentLiftProcessor.Scaler.none), ("to the screen with Catmull-Rom", Optional(runSize), .catmullRom)] {
            guard let p = LambentLiftProcessor() else { continue }
            p.reset()
            p.force(sc)
            p.outputSize = size
            for i in 0..<48 { _ = p.process(pictures[i % pictures.count], deadline: .infinity) }
            _ = p.takeReport()
            let start = CACurrentMediaTime()
            for i in 0..<240 { _ = p.process(pictures[i % pictures.count], deadline: .infinity) }
            let wall = (CACurrentMediaTime() - start) * 1000 / 240
            let r = p.takeReport()
            print(String(format: "BENCH iPad HDR lift %@: %.2f ms a picture, GPU %.2f ms p95 %.2f (%@)", what, wall, r.meanMs, r.p95Ms, r.format))
        }
        if ProcessInfo.processInfo.environment["LIFT_HDR"] != nil {
            // The lift shown (Catmull-Rom in its last pass, as the iPad runs it with `cup`), and at the picture's own size: the
            // screen's current EDR headroom in each report says whether the display layer shows it as HDR.
            runHDR = true
            runs = [("sdr1080p24", "HDR lift shown", [.catmullRom]), ("sdr1080p24", "HDR lift at its size shown", [LambentLiftProcessor.Scaler.none])]
            return next()
        }
        let scalers: [LambentLiftProcessor.Scaler] = [.neural(fast: false), .neural(fast: true), fsr, ravu, .catmullRom]
        if let device = MTLCreateSystemDefaultDevice() { _ = LambentNeuralScaler.loadNow("neural-low", student: true, device: device) }
        iPadCapacity(scalers, pictures, label: "1080p")
        // A 720p title: 1.86x to the screen, where the prescalers run (RAVU-lite from 1.41x, FSRCNNX from 1.3x).
        let small = pictures.compactMap { resized($0, 1280, 720) }
        let saved = runSize
        runSize = LambentClientUpscale.outputSize(picture: (1280, 720), bounds: bounds.size, scale: screen.nativeScale, maxHeight: 2160)
        iPadCapacity(scalers, small, label: "720p -> \(runSize.0)x\(runSize.1)")
        runSize = saved
        if ProcessInfo.processInfo.environment["LIFT_CAPACITY"] != nil { print("BENCH done"); return }
        for clip in ["sdr1080p24", "sdr1080p30", "sdr1080p60"] {
            runs.append((clip, "player's own ladder", nil))
            for sc in scalers { runs.append((clip, "\(sc)", [sc])) }
        }
        next()
    }

    /// The AI upscaler, its student and Catmull-Rom on real titles at the iPad's 1.24x (`Videos/cmp-*.mp4`, 1080p, made by the
    /// comparison script from 4K masters): each one's first 12 pictures at 2388 x 1342, SDR out, as raw 8-bit 4:2:0 in Documents
    /// (`<clip>.<scaler>.yuv`), for VMAF against the master on the Mac.
    private func compare() {
        let size = (2388, 1342)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let clips = (Bundle.main.urls(forResourcesWithExtension: "mp4", subdirectory: "Videos") ?? [])
            .filter { $0.lastPathComponent.hasPrefix("cmp-") }.sorted { $0.path < $1.path }
        if let device = MTLCreateSystemDefaultDevice() {
            _ = LambentNeuralScaler.loadNow("neural-low", device: device)
            _ = LambentNeuralScaler.loadNow("neural-low", student: true, device: device)
        }
        for clip in clips {
            let asset = AVURLAsset(url: clip)
            guard let reader = try? AVAssetReader(asset: asset), let track = asset.tracks(withMediaType: .video).first else { continue }
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
            reader.add(out)
            reader.startReading()
            var pictures: [CVPixelBuffer] = []
            while pictures.count < 12, let s = out.copyNextSampleBuffer() { if let b = CMSampleBufferGetImageBuffer(s) { pictures.append(b) } }
            let name = clip.deletingPathExtension().lastPathComponent
            for (tag, sc) in [("ai", LambentLiftProcessor.Scaler.neural(fast: false)), ("student", .neural(fast: true)), ("catrom", .catmullRom)] {
                guard let p = LambentLiftProcessor() else { continue }
                p.reset()
                p.hdr = false
                p.force(sc)
                p.neuralAnyScale = true
                p.outputSize = size
                // The network's network choice and its first pictures settle before the pictures that are kept.
                for _ in 0..<3 { _ = p.process(pictures[0], deadline: .infinity) }
                var data = Data()
                for pic in pictures {
                    guard let o = p.process(pic, deadline: .infinity) else { continue }
                    data.append(yuv420p8(o))
                }
                try? data.write(to: docs.appendingPathComponent("\(name).\(tag).yuv"))
                print("BENCH compare \(name) \(tag): \(p.takeReport().scaler) \(data.count / (size.0 * size.1 * 3 / 2)) pictures")
            }
        }
        print("BENCH done")
    }

    /// A P010 picture as 8-bit planar 4:2:0 (Y', Cb, Cr), rounded.
    private func yuv420p8(_ b: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(b, .readOnly); defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let w = CVPixelBufferGetWidth(b), h = CVPixelBufferGetHeight(b)
        var y = [UInt8](repeating: 0, count: w * h), cb = [UInt8](repeating: 0, count: w / 2 * (h / 2)), cr = cb
        let py = CVPixelBufferGetBaseAddressOfPlane(b, 0)!, ry = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
        let pc = CVPixelBufferGetBaseAddressOfPlane(b, 1)!, rc = CVPixelBufferGetBytesPerRowOfPlane(b, 1)
        func eight(_ v: UInt16) -> UInt8 { UInt8(min(255, (Int(v >> 6) + 2) >> 2)) }
        for j in 0..<h { for i in 0..<w { y[j * w + i] = eight(py.load(fromByteOffset: j * ry + i * 2, as: UInt16.self)) } }
        for j in 0..<(h / 2) { for i in 0..<(w / 2) {
            cb[j * (w / 2) + i] = eight(pc.load(fromByteOffset: j * rc + i * 4, as: UInt16.self))
            cr[j * (w / 2) + i] = eight(pc.load(fromByteOffset: j * rc + i * 4 + 2, as: UInt16.self))
        } }
        return Data(y) + Data(cb) + Data(cr)
    }

    private func resized(_ picture: CVPixelBuffer, _ w: Int, _ h: Int) -> CVPixelBuffer? {
        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        var made: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &made)
        guard let session, let made, VTPixelTransferSessionTransferImage(session, from: picture, to: made) == noErr else { return nil }
        CVBufferPropagateAttachments(picture, made)
        return made
    }

    private func iPadCapacity(_ scalers: [LambentLiftProcessor.Scaler], _ pictures: [CVPixelBuffer], label: String) {
        for sc in scalers {
            guard let p = LambentLiftProcessor() else { continue }
            p.reset()
            p.hdr = false
            p.force(sc)
            p.neuralAnyScale = true
            guard p.ladder == [sc] else { print("BENCH iPad capacity \(sc): not available here"); continue }
            p.outputSize = runSize
            for i in 0..<48 { _ = p.process(pictures[i % pictures.count], deadline: .infinity) }
            _ = p.takeReport()
            let start = CACurrentMediaTime()
            for i in 0..<240 { _ = p.process(pictures[i % pictures.count], deadline: .infinity) }
            let wall = (CACurrentMediaTime() - start) * 1000 / 240
            var r = p.takeReport()
            print(String(format: "BENCH iPad capacity %@ %@ one after the other: %.2f ms a picture (%.0f fps), GPU %.2f ms p95 %.2f, Neural Engine %.2f ms, thermal %d",
                         label, r.scaler, wall, 1000 / wall, r.meanMs, r.p95Ms, r.engineMs, ProcessInfo.processInfo.thermalState.rawValue))
            guard sc.isNeural else { continue }
            // Pipelined, as the player runs it: pack N + 2, network N + 1 and finish N at once.
            p.pipelined = true
            let pk = DispatchQueue(label: "cap.pack"), a = DispatchQueue(label: "cap.a"), b = DispatchQueue(label: "cap.b")
            let gate = DispatchSemaphore(value: LambentNeuralScaler.slotCount), group = DispatchGroup()
            let t0 = CACurrentMediaTime()
            for i in 0..<240 {
                gate.wait()
                group.enter()
                let pic = pictures[i % pictures.count]
                pk.async {
                    let packed = p.pack(pic)
                    a.async {
                        let prepared = packed.flatMap { p.infer($0) }
                        b.async { _ = p.process(pic, deadline: .infinity, prepared: prepared); gate.signal(); group.leave() }
                    }
                }
            }
            group.wait()
            let piped = (CACurrentMediaTime() - t0) * 1000 / 240
            r = p.takeReport()
            print(String(format: "BENCH iPad capacity %@ %@ pipelined: %.2f ms a picture (%.0f fps), GPU %.2f ms, Neural Engine %.2f ms, pack wall %.2f ms, thermal %d",
                         label, r.scaler, piped, 1000 / piped, r.meanMs, r.engineMs, r.packWallMs, ProcessInfo.processInfo.thermalState.rawValue))
        }
    }

    /// A capacity line: in the summary during the Apple TV run.
    private func capacityLine(_ text: String) {
        if summarizeRuns { BenchLog.summary(text) } else { print("BENCH \(text)") }
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
        let timed = scalers.flatMap { sc -> [(LambentLiftProcessor.Scaler, Int64)] in sc.isNeural ? [(sc, Int64(0)), (sc, Int64(200_000_000))] : [(sc, Int64(0))] }
        for (sc, bitrate) in timed {
            guard let p = LambentLiftProcessor() else { continue }
            p.reset()
            p.force(sc)
            p.sourceBitrate = bitrate
            p.outputSize = (3840, 2160)
            for i in 0..<48 { _ = p.process(pictures[i % pictures.count], deadline: .infinity) }
            _ = p.takeReport()
            let start = CACurrentMediaTime()
            for i in 0..<240 { _ = p.process(pictures[i % pictures.count], deadline: .infinity) }
            let wall = (CACurrentMediaTime() - start) * 1000 / 240
            var r = p.takeReport()
            if sc.isNeural {
                capacityLine(String(format: "capacity %@ one after the other: %.2f ms a picture (%.0f fps), GPU %.2f ms, Neural Engine %.2f ms",
                             r.scaler, wall, 1000 / wall, r.meanMs, r.engineMs))
                // Pipelined, as the player runs it: pack N + 2, network N + 1 and finish N at once.
                p.pipelined = true
                let pk = DispatchQueue(label: "cap.pack")
                let a = DispatchQueue(label: "cap.a"), b = DispatchQueue(label: "cap.b"), gate = DispatchSemaphore(value: LambentNeuralScaler.slotCount)
                let group = DispatchGroup()
                let t0 = CACurrentMediaTime()
                for i in 0..<240 {
                    gate.wait()
                    group.enter()
                    let pic = pictures[i % pictures.count]
                    pk.async {
                        let packed = p.pack(pic)
                        a.async {
                            let prepared = packed.flatMap { p.infer($0) }
                            b.async { _ = p.process(pic, deadline: .infinity, prepared: prepared); gate.signal(); group.leave() }
                        }
                    }
                }
                group.wait()
                let piped = (CACurrentMediaTime() - t0) * 1000 / 240
                r = p.takeReport()
                capacityLine(String(format: "capacity %@ pipelined: %.2f ms a picture (%.0f fps), GPU %.2f ms, Neural Engine %.2f ms, pack wall %.2f ms, thermal %d",
                             r.scaler, piped, 1000 / piped, r.meanMs, r.engineMs, r.packWallMs, ProcessInfo.processInfo.thermalState.rawValue))
                // Experiments (LIFT_EXP): the network's stage with no GPU stage beside it, and the GPU stage with SDR output.
                if ProcessInfo.processInfo.environment["LIFT_EXP"] != nil {
                    for variant in ["no GPU stage", "SDR out"] {
                        p.hdr = variant != "SDR out"
                        var ane: [Double] = [], packs: [Double] = []
                        let t1 = CACurrentMediaTime()
                        for i in 0..<120 {
                            gate.wait()
                            group.enter()
                            let pic = pictures[i % pictures.count]
                            pk.async {
                              let packed = p.pack(pic)
                              a.async {
                                let prepared = packed.flatMap { p.infer($0) }
                                if let prepared { ane.append(prepared.slot.engineMs); packs.append(prepared.slot.packWallMs) }
                                b.async {
                                    if variant != "no GPU stage" { _ = p.process(pic, deadline: .infinity, prepared: prepared) }
                                    gate.signal(); group.leave()
                                }
                              }
                            }
                        }
                        group.wait()
                        let ms = (CACurrentMediaTime() - t1) * 1000 / 120
                        let gpu = p.takeReport().meanMs
                        print(String(format: "BENCH experiment %@: %.2f ms a picture, Neural Engine %.2f ms, pack wall %.2f ms, GPU %.2f ms", variant, ms,
                                     ane.reduce(0, +) / Double(max(ane.count, 1)), packs.reduce(0, +) / Double(max(packs.count, 1)), gpu))
                    }
                    p.hdr = true
                }
                continue
            }
            print(String(format: "BENCH capacity %@: %.2f ms a picture back to back (%.0f fps), GPU %.2f ms, Neural Engine %.2f ms, thermal %d",
                         r.scaler, wall, 1000 / wall, r.meanMs, r.engineMs, ProcessInfo.processInfo.thermalState.rawValue))
        }
    }

    /// A 1920 x 1080 8-bit picture whose 2 x 2 blocks run through every Y' (across) and Cb, Cr (down, in 32 x 32 tiles of chroma).
    func colourRamp() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](), kCVPixelBufferMetalCompatibilityKey as String: true]
        CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &buffer)
        guard let pic = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pic, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(pic, 0)!.assumingMemoryBound(to: UInt8.self), ry = CVPixelBufferGetBytesPerRowOfPlane(pic, 0)
        let c = CVPixelBufferGetBaseAddressOfPlane(pic, 1)!.assumingMemoryBound(to: UInt8.self), rc = CVPixelBufferGetBytesPerRowOfPlane(pic, 1)
        for j in 0..<1080 { for i in 0..<1920 { y[j * ry + i] = UInt8(16 + (i * 219) / 1919) } }
        for j in 0..<540 { for i in 0..<960 {
            c[j * rc + 2 * i] = UInt8(16 + ((j / 17) * 224) / 31)
            c[j * rc + 2 * i + 1] = UInt8(16 + (((i / 30) % 32) * 224) / 31)
        } }
        CVPixelBufferUnlockBaseAddress(pic, [])
        return pic
    }

    /// Mean and largest |difference| of two P010 pictures in 10-bit codes, Y' and CbCr.
    func codeDiff(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> String {
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        var out: [String] = []
        for plane in 0..<2 {
            let pa = CVPixelBufferGetBaseAddressOfPlane(a, plane)!, pb = CVPixelBufferGetBaseAddressOfPlane(b, plane)!
            let ra = CVPixelBufferGetBytesPerRowOfPlane(a, plane), rb = CVPixelBufferGetBytesPerRowOfPlane(b, plane)
            let w = CVPixelBufferGetWidthOfPlane(a, plane) * (plane == 0 ? 1 : 2), h = CVPixelBufferGetHeightOfPlane(a, plane)
            var sum = 0.0, most = 0, n = 0.0, over2 = 0
            for j in 0..<h { for i in 0..<w {
                let d = abs(Int(pa.load(fromByteOffset: j * ra + i * 2, as: UInt16.self) >> 6) - Int(pb.load(fromByteOffset: j * rb + i * 2, as: UInt16.self) >> 6))
                sum += Double(d); most = max(most, d); n += 1; if d > 2 { over2 += 1 }
            } }
            out.append(String(format: "%@ mean %.3f max %d (>2: %.4f%%)", plane == 0 ? "Y'" : "CbCr", sum / n, most, Double(over2) * 100 / n))
        }
        return out.joined(separator: ", ")
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
        if summarizeRuns, !label.isEmpty {
            let finished = label
            queue.async { [weak self] in
                guard let self else { return }
                // Pictures shown a second against the clip's rate: the measure that counts (`late` compares each picture with the vsync at
                // the head of a three-deep pipeline, so it counts nearly all of them however smoothly they play).
                let fps = self.runSecs > 0 ? Double(self.runShown) / self.runSecs : 0
                let rate = finished.contains("p60") ? 59.94 : finished.contains("p30") ? 29.97 : 23.976
                BenchLog.summary(String(format: "%@: %@, %.1f of %.1f fps shown%@", finished, self.runScaler, fps, rate,
                                        fps >= rate * 0.98 ? "" : "  <- drops pictures"))
                self.runReports = 0; self.runShown = 0; self.runSecs = 0; self.runScaler = ""
            }
        }
        guard !runs.isEmpty else {
            if summarizeRuns { queue.async { BenchLog.summary("Done."); print("BENCH done") } } else { print("BENCH done") }
            return
        }
        let (clip, name, ladder) = runs.removeFirst()
        label = "\(clip) \(name)"
        hideOutput = name.hasSuffix("hidden")
        let h = hideOutput
        hiddenFlag.withLock { $0 = h }
        guard let url = Bundle.main.url(forResource: "Videos/\(clip)", withExtension: "mp4"), let processor = LambentLiftProcessor() else {
            print("BENCH \(label): missing clip or processor"); return next()
        }
        processor.reset()
        processor.hdr = runHDR && !name.contains("SDR out")
        processor.pipelined = true
        if let ladder { processor.force(ladder: ladder) }
        // A scaler forced is timed at the run's size, under 1.4x too; the player's own ladder keeps its rule.
        processor.neuralAnyScale = ladder != nil
        processor.outputSize = name.contains("at its size") ? nil : runSize
        processor.frameRate = clip.hasSuffix("60") ? 59.94 : clip.hasSuffix("30") ? 29.97 : 23.976
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
            // As the player does it: pack, network and finish a picture apart, each on its own queue, at most three pictures in flight.
            let taken = inFlight.withLock { n -> Bool in
                guard n < LambentNeuralScaler.slotCount else { return false }
                n += 1
                return true
            }
            guard taken else { return }
            let queue = queue, inFlight = inFlight, neuralQueue = neuralQueue
            packQueue.async { [weak self] in
             let packed = processor.pack(source)
             neuralQueue.async { [weak self] in
              let prepared = packed.flatMap { processor.infer($0) }
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
        }
        let now = CACurrentMediaTime()
        if now - lastReport >= 3 {
            let secs = now - lastReport
            lastReport = now
            let shownCount = enqueued
            enqueued = 0
            let label = label
            let edr = window?.windowScene?.screen.currentEDRHeadroom ?? 0
            queue.async { [weak self] in
                let r = processor.takeReport()
                if let self, self.summarizeRuns {
                    self.runReports += 1
                    if self.runReports > 1 { self.runShown += shownCount; self.runSecs += secs }
                    self.runScaler = r.scaler
                }
                if label.contains("HDR lift") { print(String(format: "BENCH %@: current EDR headroom %.2f", label, edr)) }
                print(String(format: "BENCH %@: %@ gpu_ms mean %.2f p95 %.2f ane_ms %.2f late %d shown %.1f fps (%@) thermal %d", label, r.format,
                             r.meanMs, r.p95Ms, r.engineMs, r.late, Double(shownCount) / secs, r.scaler, ProcessInfo.processInfo.thermalState.rawValue))
            }
        }
        let length: Double = label.hasSuffix("long") ? 300 : (ProcessInfo.processInfo.environment["LIFT_QUICK"] != nil) ? 15 : 12
        if now - runStart > length { next() }
    }
}

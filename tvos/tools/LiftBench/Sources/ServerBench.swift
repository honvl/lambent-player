import CoreVideo
import Foundation
import Metal
import QuartzCore

/// The bench's output: every line printed (`BENCH ...`, read with `devicectl ... --console`) and kept in Documents/bench.txt (copied off
/// with `devicectl device copy from --domain-type appDataContainer`); summary lines also shown on the screen, for a photo.
enum BenchLog {
    nonisolated(unsafe) static var onSummary: ((String) -> Void)?
    private static let lock = NSLock()
    private static let file: URL = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("bench.txt")
        try? Data().write(to: url)
        return url
    }()

    static func line(_ text: String) {
        print("BENCH \(text)")
        lock.lock()
        defer { lock.unlock() }
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(Data("\(text)\n".utf8))
            try? h.close()
        }
    }

    static func summary(_ text: String) {
        line("SUMMARY \(text)")
        let show = onSummary
        DispatchQueue.main.async { show?(text) }
    }
}

/// The Apple TV's classes of model, timed with Lambent Server's own code (Server/, copy_server_networks.sh) on a 1080p grey ramp taken to
/// 4K, as a Mac's `--lift-bench` times them: every AI upscaler tier on the Neural Engine and, where the GPU has neural accelerators (A19,
/// M5), through Metal 4's tensor ops; Auto HDR's bank of sixteen tables (`lutg`) and the spatial-aware tables + U-Net (`salutu`) alone;
/// then each upscaler with each HDR network, one after the other and with the HDR network's first half beside the Neural Engine. A frame's
/// time is against 41.7 ms (24 fps), 33.4 (30) and 16.7 (60).
enum ServerBench {
    static let upscalers = ["neural-low-student", "neural-hb-student", "neural-low", "neural-hb", "neural-medium", "neural-hb-medium",
                            "neural-high", "neural-hb-high"]
    static let hdrNetworks = ["lutg", "salutu"]
    /// Set when the server's code said salutu's U-Net could not run here (no Metal 4 tensor ops): salutu was then its tables alone.
    nonisolated(unsafe) static var unetFailed = false
    static func hdrName(_ folder: String) -> String {
        folder == "salutu" && unetFailed ? "salutu (tables only: its U-Net did not run here)" : folder
    }

    static func run() {
        guard let shaders = Bundle.main.url(forResource: "ServerShaders", withExtension: nil) else {
            BenchLog.summary("Server networks: not in this build (run copy_server_networks.sh)")
            return
        }
        shaderDirectoryOverride = shaders
        let device = MTLCreateSystemDefaultDevice()
        BenchLog.summary(String(format: "%@, Apple10 GPU (neural accelerators) %@, thermal %d", device?.name ?? "no GPU",
                                TensorNet.accelerated ? "yes" : "no", ProcessInfo.processInfo.thermalState.rawValue))

        // 1. Each upscaler alone, 1080p to 4K: median ms a picture (the whole step: pack, network, finish, encode).
        var best: [String: (NeuralUnit, Double)] = [:]
        for net in upscalers {
            var parts: [String] = []
            for unit in units(net) {
                guard let ms = upscalerMs(net, unit) else { parts.append("\(unit) did not run"); continue }
                parts.append(String(format: "%@ %.1f ms", "\(unit)", ms))
                if ms < best[net]?.1 ?? .infinity { best[net] = (unit, ms) }
            }
            BenchLog.summary("upscaler \(net), 1080p to 4K: \(parts.joined(separator: ", "))")
        }

        // 2. Each HDR network alone at 4K from a 1080p source.
        for folder in hdrNetworks {
            guard let ms = hdrMs(folder, shaders) else { BenchLog.summary("Auto HDR \(folder): did not run"); continue }
            BenchLog.summary(String(format: "Auto HDR %@ alone, 1080p source at 4K: %.1f ms", hdrName(folder), ms))
        }

        // 3. Upscaler + HDR network, each upscaler on its faster unit.
        for net in ["neural-low-student", "neural-low", "neural-medium", "neural-high"] {
            guard let (unit, alone) = best[net], alone < 100 else { continue }
            for folder in hdrNetworks {
                guard let (serial, beside) = comboMs(net, unit, folder, shaders) else {
                    BenchLog.summary("\(net) + \(folder): did not run"); continue
                }
                let frame = min(serial, beside)
                BenchLog.summary(String(format: "%@ (%@) + %@: %.1f ms a frame one after the other, %.1f beside: %@", net, "\(unit)", hdrName(folder),
                                        serial, beside, verdict(frame)))
            }
        }
    }

    /// Which frame rates a frame of `ms` keeps.
    static func verdict(_ ms: Double) -> String {
        let rates = [(24, 41.7), (30, 33.4), (60, 16.7)].filter { ms <= $0.1 }.map { "\($0.0)" }
        return rates.isEmpty ? "too slow for 24 fps" : "fits " + rates.joined(separator: "/") + " fps"
    }

    static func units(_ net: String) -> [NeuralUnit] {
        TensorNet.accelerated && !net.hasSuffix("-student") ? [.neuralEngine, .tensorGPU] : [.neuralEngine]
    }

    /// As the server's NeuralScaler.medianMs: 25 pictures, the first 5 not counted, wall time of the whole step.
    static func upscalerMs(_ net: String, _ unit: NeuralUnit) -> Double? {
        do {
            let scaler = try NeuralScaler(network: net, inWidth: 1920, inHeight: 1080, outWidth: 3840, outHeight: 2160, unit: unit)
            guard let picture = greyRamp(1920, 1080) else { return nil }
            var times: [Double] = []
            for i in 0..<25 {
                _ = try scaler.scale(picture)
                let ms = scaler.takeMs(wall: true)
                if i >= 1 && ms > 100 { return ms }
                if i >= 5 { times.append(ms) }
            }
            return times.sorted()[times.count / 2]
        } catch {
            BenchLog.line("upscaler \(net) on \(unit): \(error)")
            return nil
        }
    }

    static func hdrMs(_ folder: String, _ shaders: URL) -> Double? {
        do {
            let lift = try Agcm(width: 3840, height: 2160, sourceWidth: 1920, sourceHeight: 1080, params: ToneParams(peak: 1000, tv: true),
                                dir: shaders.appendingPathComponent(folder))
            guard let source = greyRamp(1920, 1080), let up = greyRamp(3840, 2160) else { return nil }
            var times: [Double] = []
            for i in 0..<30 {
                let t = CACurrentMediaTime()
                _ = try lift.apply(up, source: source)
                if i >= 5 { times.append((CACurrentMediaTime() - t) * 1000) }
            }
            return times.sorted()[times.count / 2]
        } catch {
            BenchLog.line("Auto HDR \(folder): \(error)")
            return nil
        }
    }

    /// The Mac's `--lift-bench`: the upscaler then the HDR network, one after the other and with the HDR network's first half started
    /// beside the upscaler (it only overlaps the Neural Engine), median of 20 frames each, twice alternating; the better of the two runs.
    static func comboMs(_ net: String, _ unit: NeuralUnit, _ folder: String, _ shaders: URL) -> (Double, Double)? {
        do {
            let scaler = try NeuralScaler(network: net, inWidth: 1920, inHeight: 1080, outWidth: 3840, outHeight: 2160, unit: unit)
            let lift = try Agcm(width: 3840, height: 2160, sourceWidth: 1920, sourceHeight: 1080, params: ToneParams(peak: 1000, tv: true),
                                dir: shaders.appendingPathComponent(folder))
            guard let picture = greyRamp(1920, 1080) else { return nil }
            func frame(_ overlap: Bool) throws {
                let up = overlap ? try scaler.scale(picture, beside: { try lift.begin(source: picture) }) : try scaler.scale(picture)
                _ = try lift.apply(up, source: picture)
            }
            func median(_ overlap: Bool) throws -> Double {
                var times: [Double] = []
                for i in 0..<25 {
                    let t = CACurrentMediaTime()
                    try frame(overlap)
                    if i >= 5 { times.append((CACurrentMediaTime() - t) * 1000) }
                }
                return times.sorted()[times.count / 2]
            }
            var serial = Double.infinity, beside = Double.infinity
            for _ in 0..<2 {
                serial = min(serial, try median(false))
                beside = min(beside, try median(true))
            }
            return (serial, beside)
        } catch {
            BenchLog.line("\(net) + \(folder): \(error)")
            return nil
        }
    }
}

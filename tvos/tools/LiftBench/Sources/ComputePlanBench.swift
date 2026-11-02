import CoreML
import CoreVideo
import Metal
import Foundation
import QuartzCore

// Where each op of the AI upscaler's network runs and its estimated share of the cost, from Core ML's compute plan (LIFT_PLAN=1): op by
// op, then totals by device and by op type.
enum ComputePlanBench {
    static func run(_ network: String) async {
        guard let url = LambentNeuralScaler.modelURL(network, int8: false) else { print("BENCH plan: no model \(network)"); return }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let plan: MLComputePlan
        do { plan = try await MLComputePlan.load(contentsOf: url, configuration: config) } catch { print("BENCH plan: \(error)"); return }
        guard case .program(let program) = plan.modelStructure, let main = program.functions["main"] else { print("BENCH plan: not a program"); return }
        var byDevice: [String: Double] = [:], byOp: [String: (Int, Double)] = [:]
        var lines: [String] = []
        func device(_ d: MLComputeDevice?) -> String {
            switch d {
            case .some(.cpu): return "CPU"
            case .some(.gpu): return "GPU"
            case .some(.neuralEngine): return "ANE"
            default: return "-"
            }
        }
        func walk(_ block: MLModelStructure.Program.Block, _ depth: Int) {
            for op in block.operations {
                let usage = plan.deviceUsage(for: op)
                let cost = plan.estimatedCost(of: op)?.weight ?? 0
                let d = device(usage?.preferred)
                let supported = usage?.supported.map { device($0) }.joined(separator: "/") ?? ""
                byDevice[d, default: 0] += cost
                byOp[op.operatorName, default: (0, 0)].0 += 1
                byOp[op.operatorName, default: (0, 0)].1 += cost
                if cost > 0 || d != "ANE" {
                    lines.append(String(format: "%@%@ -> %@ on %@ (can %@) cost %.4f", String(repeating: " ", count: depth), op.operatorName,
                                        op.outputs.first?.name ?? "", d, supported, cost))
                }
                for b in op.blocks { walk(b, depth + 1) }
            }
        }
        walk(main.block, 0)
        print("BENCH plan \(network): \(lines.count) ops with a cost or off the Neural Engine")
        for l in lines { print("BENCH plan op \(l)") }
        for (d, c) in byDevice.sorted(by: { $0.value > $1.value }) { print(String(format: "BENCH plan device %@: %.3f of the cost", d, c)) }
        for (o, v) in byOp.sorted(by: { $0.value.1 > $1.value.1 }) { print(String(format: "BENCH plan type %@: %d ops, %.3f of the cost", o, v.0, v.1)) }
    }
}

// Network variants for timing only (LIFT_VARIANTS=1): every `Shaders/vsr/variants/*.mlmodelc` (input "x" [1, 16, 544, 960], output
// "residual"), 100 runs back to back on the Neural Engine after 10, mean ms. Three rounds, interleaved, so the clock treats them alike.
enum VariantBench {
    static func run() {
        guard let dir = LambentNeuralScaler.directory?.appendingPathComponent("variants"),
            let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path).filter({ $0.hasSuffix(".mlmodelc") }).sorted()
        else { print("BENCH variants: none"); return }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        var models: [(String, MLModel, MLFeatureProvider)] = []
        for n in names {
            guard let m = try? MLModel(contentsOf: dir.appendingPathComponent(n), configuration: config),
                let x = try? MLMultiArray(shape: [1, 16, 544, 960], dataType: .float16),
                let f = try? MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: x)])
            else { print("BENCH variant \(n): did not load"); continue }
            for i in 0..<x.count { x[i] = NSNumber(value: Float((i * 7919) % 2001) / 1000 - 1) }
            models.append((n, m, f))
        }
        var times: [String: [Double]] = [:]
        for _ in 0..<3 {
            for (n, m, f) in models {
                for _ in 0..<10 { _ = try? m.prediction(from: f) }
                let t = CACurrentMediaTime()
                for _ in 0..<100 { _ = try? m.prediction(from: f) }
                times[n, default: []].append((CACurrentMediaTime() - t) * 10)
            }
        }
        for (n, _, _) in models {
            let t = times[n] ?? []
            print(String(format: "BENCH variant %@: %@ ms", n, t.map { String(format: "%.2f", $0) }.joined(separator: " / ")))
        }
    }
}

// How the network's input and output are handed to Core ML (LIFT_IO=1), the real neural-low model, 100 runs back to back after 10, three
// interleaved rounds: Core ML's own arrays; the player's (arrays over shared Metal buffers, output backing); IOSurface pixel buffers
// (half-float, width 960, height channels x 544) as arrays, output backing.
enum IOBench {
    static func run() {
        guard let url = LambentNeuralScaler.modelURL("neural-low", int8: false), let device = MTLCreateSystemDefaultDevice() else { return }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        guard let model = try? MLModel(contentsOf: url, configuration: config) else { return }
        let (w2, h2) = (960, 544)
        func fill(_ a: MLMultiArray) { a.withUnsafeMutableBytes { p, _ in
            let h = p.bindMemory(to: Float16.self)
            for i in 0..<h.count { h[i] = Float16(Float((i * 7919) % 2001) / 1000 - 1) }
        } }
        var cases: [(String, MLFeatureProvider, MLPredictionOptions)] = []
        if let x = try? MLMultiArray(shape: [1, 16, NSNumber(value: h2), NSNumber(value: w2)], dataType: .float16),
            let f = try? MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: x)]) {
            fill(x); cases.append(("Core ML's arrays", f, MLPredictionOptions()))
        }
        func metalArray(_ c: Int) -> MLMultiArray? {
            guard let b = device.makeBuffer(length: c * h2 * w2 * 2, options: .storageModeShared) else { return nil }
            return try? MLMultiArray(dataPointer: b.contents(), shape: [1, NSNumber(value: c), NSNumber(value: h2), NSNumber(value: w2)],
                                     dataType: .float16, strides: [NSNumber(value: c * h2 * w2), NSNumber(value: h2 * w2), NSNumber(value: w2), 1],
                                     deallocator: { _ in _ = b })
        }
        if let x = metalArray(16), let y = metalArray(48), let f = try? MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: x)]) {
            fill(x); let o = MLPredictionOptions(); o.outputBackings = ["residual": y]; cases.append(("Metal buffers + backing (the player)", f, o))
        }
        func surfaceArray(_ c: Int) -> MLMultiArray? {
            var pb: CVPixelBuffer?
            let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](), kCVPixelBufferMetalCompatibilityKey as String: true]
            CVPixelBufferCreate(nil, w2, c * h2, kCVPixelFormatType_OneComponent16Half, attrs as CFDictionary, &pb)
            guard let pb else { return nil }
            return MLMultiArray(pixelBuffer: pb, shape: [1, NSNumber(value: c), NSNumber(value: h2), NSNumber(value: w2)])
        }
        if let x = surfaceArray(16), let y = surfaceArray(48), let f = try? MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: x)]) {
            fill(x); let o = MLPredictionOptions(); o.outputBackings = ["residual": y]; cases.append(("IOSurface pixel buffers + backing", f, o))
            print("BENCH io: IOSurface rows \(CVPixelBufferGetBytesPerRow(x.pixelBuffer!)) bytes, strides \(x.strides)")
        }
        var times: [String: [Double]] = [:]
        for _ in 0..<3 {
            for (n, f, o) in cases {
                for _ in 0..<10 { _ = try? model.prediction(from: f, options: o) }
                let t = CACurrentMediaTime()
                for _ in 0..<100 { _ = try? model.prediction(from: f, options: o) }
                times[n, default: []].append((CACurrentMediaTime() - t) * 10)
            }
        }
        for (n, _, _) in cases { print("BENCH io \(n): " + (times[n] ?? []).map { String(format: "%.2f", $0) }.joined(separator: " / ") + " ms") }
    }
}

import Foundation
import Metal

/// An mpv luma prescaler (RAVU-lite, FSRCNNX) as Metal compute passes, loaded at run time from the app bundle's `Shaders` folder:
/// `<name>.metal` and `<name>.json`, the mechanical translation of the upstream shader made by Lambent's
/// `companion/shaders/hook2native.py` (both shaders are LGPL-3.0-or-later; the folder carries the upstream sources, the licences and a
/// NOTICE, and any file in it can be replaced). The app contains none of the shaders' code.
///
/// `encode` runs the passes on a luma texture (the picture's Y', full range, `r16Float`) and returns Y' at twice the size.
final class LambentPrescaler {
    private struct Pass {
        let pipeline: MTLComputePipelineState
        let binds: [String]
        let save: String?
        let width: String?, height: String?, when: String?
        let format: MTLPixelFormat
        let compute: [Int]?
    }

    let name: String
    private let passes: [Pass]
    private var own: [String: MTLTexture] = [:]
    private var scratch: [String: MTLTexture] = [:]

    static var bundleDirectory: URL? { Bundle.main.resourceURL?.appendingPathComponent("Shaders", isDirectory: true) }

    init?(device: MTLDevice, name: String, directory: URL? = LambentPrescaler.bundleDirectory) {
        self.name = name
        guard let directory,
            let data = try? Data(contentsOf: directory.appendingPathComponent("\(name).json")),
            let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let source = try? String(contentsOf: directory.appendingPathComponent("\(name).metal"), encoding: .utf8)
        else {
            NSLog("[LambentHDR] no shader %@", name)
            return nil
        }
        let options = MTLCompileOptions()
        options.mathMode = .fast
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: source, options: options) } catch {
            NSLog("[LambentHDR] shader %@ did not compile: %@", name, "\(error)")
            return nil
        }
        var passes: [Pass] = []
        for p in manifest["passes"] as? [[String: Any]] ?? [] {
            guard (p["hook"] as? String ?? "LUMA") == "LUMA", let kernel = p["kernel"] as? String,
                let function = library.makeFunction(name: kernel),
                let pipeline = try? device.makeComputePipelineState(function: function)
            else {
                NSLog("[LambentHDR] shader %@: a pass cannot run", name)
                return nil
            }
            passes.append(
                Pass(
                    pipeline: pipeline, binds: p["binds"] as? [String] ?? [], save: p["save"] as? String,
                    width: p["width"] as? String, height: p["height"] as? String, when: p["when"] as? String,
                    format: (p["components"] as? Int ?? 4) == 1 ? .r16Float : .rgba16Float,
                    compute: (p["compute"] as? [Int]).flatMap { $0.count == 4 ? $0 : nil }))
        }
        self.passes = passes
        for t in manifest["textures"] as? [[String: Any]] ?? [] {
            guard let tname = t["name"] as? String, let w = t["width"] as? Int, let h = t["height"] as? Int,
                let b64 = t["data"] as? String, let bytes = Data(base64Encoded: b64)
            else { continue }
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            d.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: d) else { return nil }
            bytes.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 8)
            }
            own[tname] = texture
        }
        if passes.isEmpty { return nil }
    }

    /// mpv's size and condition expressions: reverse Polish over numbers, `NAME.w` / `NAME.h` and `+ - * / > < = !`.
    private static func evaluate(_ expression: String, sizes: [String: (Int, Int)]) -> Double {
        var stack: [Double] = []
        for token in expression.split(separator: " ") {
            let t = String(token)
            if let v = Double(t) {
                stack.append(v)
            } else if let dot = t.firstIndex(of: "."), ["w", "h", "width", "height"].contains(String(t[t.index(after: dot)...])) {
                let size = sizes[String(t[..<dot])] ?? (0, 0)
                stack.append(Double(t[t.index(after: dot)...].hasPrefix("w") ? size.0 : size.1))
            } else if t == "!" {
                stack.append((stack.popLast() ?? 0) == 0 ? 1 : 0)
            } else {
                let b = stack.popLast() ?? 0, a = stack.popLast() ?? 0
                switch t {
                case "+": stack.append(a + b)
                case "-": stack.append(a - b)
                case "*": stack.append(a * b)
                case "/": stack.append(b == 0 ? 0 : a / b)
                case ">": stack.append(a > b ? 1 : 0)
                case "<": stack.append(a < b ? 1 : 0)
                case "=": stack.append(a == b ? 1 : 0)
                default: stack.append(0)
                }
            }
        }
        return stack.last ?? 0
    }

    private func texture(_ key: String, _ device: MTLDevice, _ w: Int, _ h: Int, _ format: MTLPixelFormat) -> MTLTexture {
        if let t = scratch[key], t.width == w, t.height == h, t.pixelFormat == format { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        let t = device.makeTexture(descriptor: d)!
        scratch[key] = t
        return t
    }

    /// The passes on `luma` for a picture shown at `output`; the result is the luma after the last pass (twice the size), or `luma`
    /// itself when the shader's own condition says not to run (the output is too close to the picture's size).
    func encode(_ buffer: MTLCommandBuffer, luma input: MTLTexture, output: (Int, Int)) -> MTLTexture {
        var luma = input
        var saved: [String: MTLTexture] = [:]
        for (i, pass) in passes.enumerated() {
            var sizes: [String: (Int, Int)] = ["HOOKED": (luma.width, luma.height), "LUMA": (luma.width, luma.height), "OUTPUT": output]
            for (k, t) in saved { sizes[k] = (t.width, t.height) }
            if let when = pass.when, Self.evaluate(when, sizes: sizes) == 0 { continue }
            let w = pass.width.map { Int(Self.evaluate($0, sizes: sizes).rounded()) } ?? luma.width
            let h = pass.height.map { Int(Self.evaluate($0, sizes: sizes).rounded()) } ?? luma.height
            let out = texture(pass.save ?? "HOOKED\(i)", buffer.device, w, h, pass.format)
            guard let encoder = buffer.makeComputeCommandEncoder() else { return luma }
            encoder.setComputePipelineState(pass.pipeline)
            encoder.setTexture(out, index: 0)
            for (slot, bind) in pass.binds.enumerated() {
                let t: MTLTexture?
                if bind == "HOOKED" || bind == "LUMA" { t = luma } else if let s = saved[bind] { t = s } else { t = own[bind] }
                encoder.setTexture(t, index: slot + 1)
            }
            if let c = pass.compute {
                encoder.dispatchThreadgroups(
                    MTLSize(width: (w + c[0] - 1) / c[0], height: (h + c[1] - 1) / c[1], depth: 1),
                    threadsPerThreadgroup: MTLSize(width: c[2], height: c[3], depth: 1))
            } else {
                let tw = pass.pipeline.threadExecutionWidth
                let th = max(1, pass.pipeline.maxTotalThreadsPerThreadgroup / tw)
                encoder.dispatchThreads(
                    MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: min(th, 16), depth: 1))
            }
            encoder.endEncoding()
            if let save = pass.save { saved[save] = out } else { luma = out }
        }
        return luma
    }
}

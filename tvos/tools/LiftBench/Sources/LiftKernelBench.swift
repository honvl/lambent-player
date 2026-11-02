import CoreVideo
import Foundation
import Metal

// The HDR lift alone at 3840 x 2160, the work the last pass does per pixel after its scaling: today's table lift (LambentLiftProcessor's
// `expand`: BT.1886, Lambent's 65-point TrueHDR-fitted curve, PQ) against TrueHDR's own formula (Lambent's truehdr-formula work in
// InverseToneMap.swift, copied here for timing: 2.2 power, T(Y) = Y^c / (A Y^1.3c + B), Oklab chroma with a gamut search). One thread a
// pixel, the 1080p picture read at half the coordinates; median GPU ms of 60 runs after 10.
enum LiftKernelBench {
    static func run(_ picture: CVPixelBuffer) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: source, options: nil) } catch { print("BENCH lift kernels: \(error)"); return }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        var ty: CVMetalTexture?, tc: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache!, picture, nil, .r8Unorm, CVPixelBufferGetWidthOfPlane(picture, 0),
                                                  CVPixelBufferGetHeightOfPlane(picture, 0), 0, &ty)
        CVMetalTextureCacheCreateTextureFromImage(nil, cache!, picture, nil, .rg8Unorm, CVPixelBufferGetWidthOfPlane(picture, 1),
                                                  CVPixelBufferGetHeightOfPlane(picture, 1), 1, &tc)
        guard let ty, let tc, let inY = CVMetalTextureGetTexture(ty), let inC = CVMetalTextureGetTexture(tc) else { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Unorm, width: 3840, height: 2160, mipmapped: false)
        d.usage = [.shaderWrite]
        d.storageMode = .private
        guard let out = device.makeTexture(descriptor: d) else { return }
        let curve = LambentToneParams(peak: 1000).table
        // TrueHDR's parameters at Lambent's defaults (contrast 100, middle grey 50, peak 1000, saturation 1), as ToneParams.kernel makes them.
        let c = 0.45 + 0.004 * 100.0, m = 50.0 / 1000, p = min(max((1000.0 * (50 / 0.18) / 203).rounded(), 400), 2000) / 1000
        let t = pow(0.214, c), u = pow(0.214, 1.3 * c), den = p * m * (u - 1)
        var tone: [Float] = [Float(c), Float((p * t - m) / den), Float((m * u - p * t) / den), Float(0.85 + 0.2), Float(1000 * 203 / (50 / 0.18)), 0]
        for name in ["lift_table", "lift_formula", "plain"] {
            guard let f = library.makeFunction(name: name), let pipe = try? device.makeComputePipelineState(function: f) else { continue }
            var times: [Double] = []
            for i in 0..<70 {
                guard let b = queue.makeCommandBuffer(), let e = b.makeComputeCommandEncoder() else { return }
                e.setComputePipelineState(pipe)
                e.setTextures([inY, inC, out], range: 0..<3)
                curve.withUnsafeBytes { e.setBytes($0.baseAddress!, length: $0.count, index: 0) }
                tone.withUnsafeMutableBytes { e.setBytes($0.baseAddress!, length: $0.count, index: 1) }
                e.dispatchThreads(MTLSize(width: 3840, height: 2160, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                e.endEncoding()
                b.commit()
                b.waitUntilCompleted()
                if i >= 10 { times.append((b.gpuEndTime - b.gpuStartTime) * 1000) }
            }
            times.sort()
            print(String(format: "BENCH lift kernel %@ at 3840x2160: %.2f ms (min %.2f)", name, times[times.count / 2], times[0]))
        }
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    #include <metal_stdlib>
    using namespace metal;

    struct Tone { float c; float a; float b; float s; float scale; uint bt601; };

    inline float3 rows(float3 r0, float3 r1, float3 r2, float3 v) { return float3(dot(r0, v), dot(r1, v), dot(r2, v)); }

    // Lightness, chroma, hue back to TrueHDR's wide working RGB.
    inline float3 wide_rgb(float l, float c, float h) {
    float3 lms = rows(float3(1.0, 0.3963377773761749, 0.21580375730991364), float3(1.0, -0.10556135326623917, -0.0638541728258133),
                      float3(1.0, -0.08948417752981186, -1.2914855480194092), float3(l, c * cos(h), c * sin(h)));
    lms = lms * lms * lms;
    return rows(float3(2.1401402950286865, -1.2463560104370117, 0.10643172264099121), float3(-0.8848324418067932, 2.163172721862793, -0.27836158871650696),
                float3(-0.04857905954122543, -0.45449090003967285, 1.5023562908172607), lms);
    }

    inline bool inside(float3 v) { return all(v >= -0.001) && all(v <= 1.001); }

    // Non-linear BT.709 R'G'B' (0..1) to linear BT.709 in TrueHDR's units (1 = 1000 nits of its scale); wide colours stay negative.
    inline float3 truehdr(float3 rgb, constant Tone& t) {
    float3 lin = pow(max(rgb, 0.0), 2.2);
    float y = dot(lin, float3(0.2126, 0.7152, 0.0722));
    lin *= (pow(y, t.c) / (t.a * pow(y, 1.3 * t.c) + t.b)) / (y + 1e-5);
    float3 lms = rows(float3(0.4120832681655884, 0.5356993079185486, 0.046857498586177826), float3(0.2118612825870514, 0.6804224252700806, 0.1050436869263649),
                      float3(0.08832483738660812, 0.2817308008670807, 0.6292985677719116), lin);
    float3 lab = rows(float3(0.21045425534248352, 0.7936177849769592, -0.0040720500983297825), float3(1.9779984951019287, -2.4285922050476074, 0.4505937099456787),
                      float3(0.025904040783643723, 0.7827717661857605, -0.8086757659912109), pow(max(lms, 0.0), 0.3333));
    float h = atan2(lab.z, lab.y), c = clamp(length(lab.yz) * t.s, 0.0, 1.0);
    float3 w = wide_rgb(lab.x, c, h);
    if (!inside(w) && c > 0.01) {
        // TrueHDR keeps the last trial, inside or not.
        float lo = 0.0, hi = c;
        while (hi - lo > 0.01) {
            float mid = (lo + hi) * 0.5;
            w = wide_rgb(lab.x, mid, h);
            if (inside(w)) lo = mid; else hi = mid;
        }
    }
    return rows(float3(1.6604909896850586, -0.5873100161552429, -0.060430001467466354), float3(-0.124549999833107, 1.1328990459442139, -0.008340000174939632),
                float3(-0.018149999901652336, -0.10057000070810318, 1.1187289953231812), clamp(w, 0.0, 1.0));
    }

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

    constant float3x3 to2020 = float3x3(float3(0.6274, 0.0691, 0.0164), float3(0.3293, 0.9195, 0.0880), float3(0.0433, 0.0114, 0.8956));

    inline float3 rgb_at(texture2d<float> inY, texture2d<float> inC, uint2 g) {
        float y = (inY.read(g / 2).r * 1020.0 - 64.0) / 876.0;
        float2 c = (inC.read(g / 4).rg * 1020.0 - 512.0) / 896.0;
        return clamp(float3(y + 1.5748 * c.y, y - 0.187324 * c.x - 0.468124 * c.y, y + 1.8556 * c.x), 0.0, 1.0);
    }

    inline void store(texture2d<float, access::write> o, float3 e, uint2 g) {
        o.write(float4((dot(e, float3(0.2627, 0.6780, 0.0593)) * 876.0 + 64.0) * 64.0 / 65535.0), g);
    }

    // Today's: LambentLiftProcessor's `expand`, saturation 1.
    kernel void lift_table(texture2d<float> inY [[texture(0)]], texture2d<float> inC [[texture(1)]], texture2d<float, access::write> o [[texture(2)]],
                           constant float* curve [[buffer(0)]], constant Tone& t [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {
        float3 rgb = rgb_at(inY, inC, g);
        float3 lin = pow(rgb, 2.4);
        float y = dot(lin, float3(0.2126, 0.7152, 0.0722));
        float x = pow(y, 1.0 / 2.4) * 64.0;
        uint i = min(uint(x), 63u);
        float nits = pq_nits(mix(curve[i], curve[i + 1], x - float(i)));
        float3 out = lin * (y > 1e-7 ? nits / y : 0.0);
        float yo = dot(out, float3(0.2126, 0.7152, 0.0722));
        out = max(yo + (out - yo) * 0.985, 0.0);
        store(o, pq(to2020 * out), g);
    }

    // TrueHDR's formula, as the truehdr-formula work's `expand`.
    kernel void lift_formula(texture2d<float> inY [[texture(0)]], texture2d<float> inC [[texture(1)]], texture2d<float, access::write> o [[texture(2)]],
                             constant float* curve [[buffer(0)]], constant Tone& t [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {
        float3 out = truehdr(rgb_at(inY, inC, g), t) * t.scale;
        store(o, pq(max(to2020 * out, 0.0)), g);
    }

    // No lift: the read and the write alone.
    kernel void plain(texture2d<float> inY [[texture(0)]], texture2d<float> inC [[texture(1)]], texture2d<float, access::write> o [[texture(2)]],
                      constant float* curve [[buffer(0)]], constant Tone& t [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {
        store(o, rgb_at(inY, inC, g), g);
    }
    """
}

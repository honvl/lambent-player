import Foundation
import Metal

/// Lambent Auto HDR on this device: the lightest of Lambent Auto HDR's networks, the bank of sixteen colour tables mixed per picture
/// (Lambent's docs/HDR_FALLBACK.md, companion/shaders/lutg; the Vision Pro's HDRLift.swift, the Mac enhancer's Agcm.swift and the Windows
/// one's agcm.cpp run the same weights). It is the least HDR Lambent makes (2026-11-16): the formula lift it replaced (TrueHDR's fitted
/// curve and Deepen blacks) scored 69.2 HDR VMAF v1 against HDRMovieformer on held-out film frames, the tables 97.5. Nothing is debanded:
/// the networks were trained on SDR as it is.
///
/// Per picture (`encodeTable`, before the lift reads it, in the same command buffer): the picture as the thumbnail the network was
/// trained on (its 8 x 8 means, stretched to 240 x 135), HDRTVNet's condition CNN over it (five blocks of 1x1 convolution, 3x3 average at
/// stride 2, leaky ReLU, four instance norms; 32 numbers), a linear layer to the sixteen tables' weights, the tables (33^3, a correction in
/// PQ) mixed by them, and from that a 65^3 table of BT.2408 plus the correction, BT.2020 PQ over the picture's R'G'B', whose points fall on
/// the tables' own and half way between, so the hardware's trilinear read of it is the tables' own. About 16 M multiply-adds a picture.
/// The lift (`LambentLiftProcessor`, and the AI upscaler's fused finish) reads that table as it read the formula's.
///
/// The weights are in the bundle's `Shaders/autohdr` (tvos/scripts/copy_autohdr_weights.sh); without them there is no Auto HDR here.
final class LambentAutoHDR: @unchecked Sendable {
    private static let channels = [3, 16, 32, 64, 128, 128]
    private static let thumbW = 240, thumbH = 135
    private static let bank = 16, tableSize = 33, grid = 65

    /// The bank's folder in the app's bundle.
    static var directory: URL? { LambentPrescaler.bundleDirectory?.appendingPathComponent("autohdr", isDirectory: true) }

    /// The weights are in the bundle: this device can make Auto HDR.
    static var available: Bool {
        guard let directory else { return false }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("agcm.bin").path)
            && FileManager.default.fileExists(atPath: directory.appendingPathComponent("agcm.json").path)
    }

    private let device: MTLDevice
    private let meansPipeline, thumbPipeline, pool9Pipeline, blockPipeline, statsPipeline, foldPipeline, mixPipeline, fillPipeline:
        MTLComputePipelineState
    private let weights: MTLBuffer
    private let offsets: [String: UInt32]
    private let acts: [MTLBuffer]
    private let statsBuffer, folded, mixed: MTLBuffer
    private var scratch: MTLBuffer
    /// The pictures' tables, in turn: a picture's lift may still be reading one while the next picture's is made.
    private var tables: [MTLTexture] = []
    private var nextTable = 0

    init?(device: MTLDevice, directory: URL? = LambentAutoHDR.directory) {
        guard let directory,
            let manifestData = try? Data(contentsOf: directory.appendingPathComponent("agcm.json")),
            let manifest = (try? JSONSerialization.jsonObject(with: manifestData)) as? [String: Any],
            let blob = try? Data(contentsOf: directory.appendingPathComponent("agcm.bin")),
            manifest["format"] as? String == "lambent-agcm-1", manifest["network"] as? String == "lutg",
            let arrays = manifest["arrays"] as? [String: [String: Any]]
        else {
            NSLog("[LambentHDR] Auto HDR: no bank of tables in the bundle")
            return nil
        }
        var offsets: [String: UInt32] = [:]
        var defines = ""
        for (name, entry) in arrays {
            guard let offset = entry["offset"] as? Int, let shape = entry["shape"] as? [Int],
                (offset + shape.reduce(1, *)) * 4 <= blob.count
            else { return nil }
            offsets[name] = UInt32(offset)
            defines += "#define OFF_\(name.replacingOccurrences(of: ".", with: "_")) \(offset)u\n"
        }
        guard (arrays["tables"]?["shape"] as? [Int]) == [Self.bank, 3, Self.tableSize, Self.tableSize, Self.tableSize],
            (arrays["mix.weight"]?["shape"] as? [Int]) == [Self.bank, 32], (arrays["cond5.weight"]?["shape"] as? [Int]) == [32, 128]
        else {
            NSLog("[LambentHDR] Auto HDR: agcm.json is not the bank of sixteen tables")
            return nil
        }
        self.device = device
        self.offsets = offsets
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: defines + bankSource, options: nil) } catch {
            NSLog("[LambentHDR] Auto HDR: %@", "\(error)")
            return nil
        }
        func pipeline(_ name: String) -> MTLComputePipelineState? {
            library.makeFunction(name: name).flatMap { try? device.makeComputePipelineState(function: $0) }
        }
        guard let means = pipeline("bank_means"), let thumb = pipeline("bank_thumb"), let pool9 = pipeline("bank_pool9"),
            let block = pipeline("bank_block"), let stats = pipeline("bank_stats"), let fold = pipeline("bank_fold"),
            let mix = pipeline("bank_mix"), let fill = pipeline("bank_table")
        else { return nil }
        (meansPipeline, thumbPipeline, pool9Pipeline, blockPipeline) = (means, thumb, pool9, block)
        (statsPipeline, foldPipeline, mixPipeline, fillPipeline) = (stats, fold, mix, fill)

        var most = 3 * Self.thumbW * Self.thumbH, ih = Self.thumbH, iw = Self.thumbW
        for b in 0..<5 {
            ih = (ih - 1) / 2 + 1
            iw = (iw - 1) / 2 + 1
            most = max(most, Self.channels[b + 1] * ih * iw)
        }
        let cube = Self.tableSize * Self.tableSize * Self.tableSize
        guard
            let weightBuffer = blob.withUnsafeBytes({
                device.makeBuffer(bytes: $0.baseAddress!, length: blob.count, options: .storageModeShared)
            }),
            let a0 = device.makeBuffer(length: most * 4, options: .storageModePrivate),
            let a1 = device.makeBuffer(length: most * 4, options: .storageModePrivate),
            let statsBuffer = device.makeBuffer(length: 128 * 8, options: .storageModePrivate),
            let folded = device.makeBuffer(length: 4 * 16, options: .storageModePrivate),
            let mixed = device.makeBuffer(length: cube * 16, options: .storageModePrivate),
            let scratch = device.makeBuffer(length: most * 4, options: .storageModePrivate)
        else { return nil }
        weights = weightBuffer
        acts = [a0, a1]
        self.statsBuffer = statsBuffer
        self.folded = folded
        self.mixed = mixed
        self.scratch = scratch
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Float
        (descriptor.width, descriptor.height, descriptor.depth) = (Self.grid, Self.grid, Self.grid)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        for _ in 0..<2 {
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            tables.append(texture)
        }
    }

    /// This picture's table (BT.2020 PQ over its R'G'B', 65 points a side), encoded into `buffer` ahead of the lift that reads it. `luma`
    /// and `chroma`: the picture's video-range planes (8-bit r8/rg8, or P010 r16/rg16, `tenBit`), in `matrix`. Nil when nothing could be
    /// encoded.
    func encodeTable(_ buffer: MTLCommandBuffer, luma: MTLTexture, chroma: MTLTexture, tenBit: Bool, matrix: LambentYCbCr) -> MTLTexture? {
        let w = luma.width & ~1, h = luma.height & ~1
        guard w >= 2, h >= 2, let encoder = buffer.makeComputeCommandEncoder() else { return nil }
        encoder.label = "Auto HDR table"
        let table = tables[nextTable]
        nextTable = (nextTable + 1) % tables.count
        let (tw, th) = (Self.thumbW, Self.thumbH)
        var p = BankParams(
            w: UInt32(w), h: UInt32(h), tw: UInt32(tw), th: UInt32(th), kr: matrix.kr, kb: matrix.kb,
            codeScale: tenBit ? 65535.0 / 64.0 : 1020)
        p.iw = UInt32((w + 7) / 8)
        p.ih = UInt32((h + 7) / 8)
        let means = 3 * Int(p.iw) * Int(p.ih) * 4
        if scratch.length < means, let larger = device.makeBuffer(length: means, options: .storageModePrivate) { scratch = larger }
        guard scratch.length >= means else {
            encoder.endEncoding()
            return nil
        }
        func grid(_ pipeline: MTLComputePipelineState, _ w: Int, _ h: Int, _ depth: Int = 1,
                  _ group: MTLSize = MTLSize(width: 8, height: 8, depth: 1)) {
            encoder.setComputePipelineState(pipeline)
            encoder.setBytes(&p, length: MemoryLayout<BankParams>.stride, index: 0)
            encoder.dispatchThreads(MTLSize(width: w, height: h, depth: depth), threadsPerThreadgroup: group)
        }
        encoder.setTextures([luma, chroma], range: 0..<2)
        encoder.setBuffer(weights, offset: 0, index: 4)
        encoder.setBuffer(statsBuffer, offset: 0, index: 3)
        encoder.setBuffer(folded, offset: 0, index: 5)
        encoder.setBuffer(mixed, offset: 0, index: 6)
        encoder.setBuffer(scratch, offset: 0, index: 1)
        encoder.setBuffer(acts[0], offset: 0, index: 2)
        grid(meansPipeline, Int(p.iw), Int(p.ih))
        grid(thumbPipeline, tw, th, 1, MTLSize(width: 16, height: 16, depth: 1))
        var ih = th, iw = tw, at = 0
        for block in 0..<5 {
            p.ci = UInt32(Self.channels[block])
            p.co = UInt32(Self.channels[block + 1])
            p.ih = UInt32(ih)
            p.iw = UInt32(iw)
            p.oh = UInt32((ih - 1) / 2 + 1)
            p.ow = UInt32((iw - 1) / 2 + 1)
            p.offW = offsets["cond\(block).weight"] ?? 0
            p.offB = offsets["cond\(block).bias"] ?? 0
            p.normIn = block > 0 ? 1 : 0
            p.offG = block > 0 ? offsets["norm\(block - 1).weight"] ?? 0 : 0
            p.offBeta = block > 0 ? offsets["norm\(block - 1).bias"] ?? 0 : 0
            encoder.setBuffer(acts[at], offset: 0, index: 1)
            encoder.setBuffer(scratch, offset: 0, index: 2)
            grid(pool9Pipeline, Int(p.ow), Int(p.oh), Int(p.ci))
            encoder.setBuffer(scratch, offset: 0, index: 1)
            encoder.setBuffer(acts[1 - at], offset: 0, index: 2)
            grid(blockPipeline, Int(p.ow), Int(p.oh), Int(p.co))
            if block < 4 {
                encoder.setComputePipelineState(statsPipeline)
                encoder.setBytes(&p, length: MemoryLayout<BankParams>.stride, index: 0)
                encoder.dispatchThreadgroups(
                    MTLSize(width: Int(p.co), height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            }
            ih = Int(p.oh)
            iw = Int(p.ow)
            at = 1 - at
        }
        encoder.setBuffer(acts[at], offset: 0, index: 1)
        let wide = MTLSize(width: 256, height: 1, depth: 1)
        encoder.setComputePipelineState(foldPipeline)
        encoder.setBytes(&p, length: MemoryLayout<BankParams>.stride, index: 0)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: wide)
        let cube = Self.tableSize * Self.tableSize * Self.tableSize
        encoder.setComputePipelineState(mixPipeline)
        encoder.dispatchThreadgroups(MTLSize(width: (cube + 255) / 256, height: 1, depth: 1), threadsPerThreadgroup: wide)
        encoder.setComputePipelineState(fillPipeline)
        encoder.setTexture(table, index: 2)
        encoder.dispatchThreads(
            MTLSize(width: Self.grid, height: Self.grid, depth: Self.grid), threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 4))
        encoder.endEncoding()
        return table
    }
}

private struct BankParams {
    var ox: UInt32 = 0, oy: UInt32 = 0, w: UInt32, h: UInt32
    var tw: UInt32, th: UInt32
    var ci: UInt32 = 0, co: UInt32 = 0
    var ih: UInt32 = 0, iw: UInt32 = 0, oh: UInt32 = 0, ow: UInt32 = 0
    var offW: UInt32 = 0, offB: UInt32 = 0, offG: UInt32 = 0, offBeta: UInt32 = 0
    var normIn: UInt32 = 0
    var kr: Float, kb: Float
    var codeScale: Float

    init(w: UInt32, h: UInt32, tw: UInt32, th: UInt32, kr: Float, kb: Float, codeScale: Float) {
        (self.w, self.h, self.tw, self.th, self.kr, self.kb, self.codeScale) = (w, h, tw, th, kr, kb, codeScale)
    }
}

// The Vision Pro's (ViewerRender HDRLift.swift) bank kernels, reading the whole picture's planes. The weight arrays' offsets in floats
// (agcm.json) are prepended as OFF_<array> defines.
private let bankSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Bank {
        uint ox, oy, w, h;
        uint tw, th;
        uint ci, co;
        uint ih, iw, oh, ow;
        uint off_w, off_b, off_g, off_beta;
        uint norm_in;
        float kr, kb;
        float codeScale;
    };

    inline float3 pq(float3 nits) {
        const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
        float3 l = pow(clamp(nits / 10000.0, 0.0, 1.0), m1);
        return pow((c1 + c2 * l) / (1.0 + c3 * l), m2);
    }

    // SDR R'G'B' as an HDR TV shows it: BT.1886 light, BT.709 in BT.2020, white at 203 nits, PQ.
    inline float3 bt2408(float3 rgb) {
        const float3x3 to2020 = float3x3(float3(0.6274, 0.0691, 0.0164), float3(0.3293, 0.9195, 0.0880), float3(0.0433, 0.0114, 0.8956));
        return pq(to2020 * pow(rgb, 2.4) * 203.0);
    }

    inline float3 to_rgb(float y, float2 c, float kr, float kb, float codeScale) {
        float Y = (y * codeScale - 64.0) / 876.0;
        float2 C = (c * codeScale - 512.0) / 896.0;
        float r = Y + 2.0 * (1.0 - kr) * C.y;
        float b = Y + 2.0 * (1.0 - kb) * C.x;
        float g = (Y - kr * r - kb * b) / (1.0 - kr - kb);
        return clamp(float3(r, g, b), 0.0, 1.0);
    }

    kernel void bank_means(texture2d<float> inY [[texture(0)]], texture2d<float> inC [[texture(1)]], device float* src [[buffer(1)]],
                           constant Bank& p [[buffer(0)]], uint2 id [[thread_position_in_grid]]) {
        if (id.x >= p.iw || id.y >= p.ih) return;
        float3 sum = 0;
        for (uint y = 0; y < 8; y++)
            for (uint x = 0; x < 8; x++) {
                uint2 at = uint2(p.ox + min(id.x * 8 + x, p.w - 1), p.oy + min(id.y * 8 + y, p.h - 1));
                sum += to_rgb(inY.read(at).r, inC.read(at / 2).rg, p.kr, p.kb, p.codeScale);
            }
        uint plane = p.iw * p.ih, i = id.y * p.iw + id.x;
        src[i] = sum.r / 64.0;
        src[plane + i] = sum.g / 64.0;
        src[2 * plane + i] = sum.b / 64.0;
    }

    kernel void bank_thumb(device const float* src [[buffer(1)]], device float* dst [[buffer(2)]], constant Bank& p [[buffer(0)]],
                           uint2 id [[thread_position_in_grid]]) {
        if (id.x >= p.tw || id.y >= p.th) return;
        float sx = max((id.x + 0.5) * float(p.iw) / float(p.tw) - 0.5, 0.0), sy = max((id.y + 0.5) * float(p.ih) / float(p.th) - 0.5, 0.0);
        uint x0 = min(uint(sx), p.iw - 1), y0 = min(uint(sy), p.ih - 1), x1 = min(x0 + 1, p.iw - 1), y1 = min(y0 + 1, p.ih - 1);
        float fx = sx - float(x0), fy = sy - float(y0);
        uint plane = p.iw * p.ih;
        float3 m[4];
        uint at[4] = {y0 * p.iw + x0, y0 * p.iw + x1, y1 * p.iw + x0, y1 * p.iw + x1};
        for (uint k = 0; k < 4; k++) m[k] = float3(src[at[k]], src[plane + at[k]], src[2 * plane + at[k]]);
        float3 mean = mix(mix(m[0], m[1], fx), mix(m[2], m[3], fx), fy);
        plane = p.tw * p.th;
        uint i = id.y * p.tw + id.x;
        dst[i] = mean.r;
        dst[plane + i] = mean.g;
        dst[2 * plane + i] = mean.b;
    }

    kernel void bank_pool9(device const float* src [[buffer(1)]], device float* dst [[buffer(2)]], device const float2* stats [[buffer(3)]],
                           device const float* wts [[buffer(4)]], constant Bank& p [[buffer(0)]], uint3 id [[thread_position_in_grid]]) {
        if (id.x >= p.ow || id.y >= p.oh || id.z >= p.ci) return;
        uint c = id.z, plane = p.ih * p.iw;
        float2 s = p.norm_in != 0 ? stats[c] : float2(0, 1);
        float g = p.norm_in != 0 ? wts[p.off_g + c] * s.y : 1.0, beta = p.norm_in != 0 ? wts[p.off_beta + c] - s.x * g : 0.0;
        float sum = 0;
        for (int dy = 0; dy < 3; dy++)
            for (int dx = 0; dx < 3; dx++) {
                int y = int(id.y) * 2 - 1 + dy, x = int(id.x) * 2 - 1 + dx;
                if (y >= 0 && x >= 0 && y < int(p.ih) && x < int(p.iw)) sum += src[c * plane + uint(y) * p.iw + uint(x)] * g + beta;
            }
        dst[c * p.oh * p.ow + id.y * p.ow + id.x] = sum / 9.0;
    }

    kernel void bank_block(device const float* src [[buffer(1)]], device float* dst [[buffer(2)]], device const float* wts [[buffer(4)]],
                           constant Bank& p [[buffer(0)]], uint3 id [[thread_position_in_grid]]) {
        if (id.x >= p.ow || id.y >= p.oh || id.z >= p.co) return;
        uint o = id.z, n = p.oh * p.ow, here = id.y * p.ow + id.x;
        int y0 = int(id.y) * 2 - 1, x0 = int(id.x) * 2 - 1;
        float inside = float((min(y0 + 3, int(p.ih)) - max(y0, 0)) * (min(x0 + 3, int(p.iw)) - max(x0, 0)));
        float acc = wts[p.off_b + o] * inside / 9.0;
        for (uint c = 0; c < p.ci; c++) acc += wts[p.off_w + o * p.ci + c] * src[c * n + here];
        dst[o * n + here] = acc > 0 ? acc : 0.2 * acc;
    }

    kernel void bank_stats(device const float* dst [[buffer(2)]], device float2* stats [[buffer(3)]], constant Bank& p [[buffer(0)]],
                           uint c [[threadgroup_position_in_grid]], uint t [[thread_position_in_threadgroup]]) {
        threadgroup float red[256];
        uint n = p.oh * p.ow;
        float sum = 0;
        for (uint i = t; i < n; i += 256) sum += dst[c * n + i];
        red[t] = sum;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint s = 128; s > 0; s >>= 1) {
            if (t < s) red[t] += red[t + s];
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        float mean = red[0] / float(n), sq = 0;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint i = t; i < n; i += 256) {
            float d = dst[c * n + i] - mean;
            sq += d * d;
        }
        red[t] = sq;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint s = 128; s > 0; s >>= 1) {
            if (t < s) red[t] += red[t + s];
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (t == 0) stats[c] = float2(mean, rsqrt(red[0] / float(n) + 1e-5));
    }

    kernel void bank_fold(device const float* src [[buffer(1)]], device const float* wts [[buffer(4)]], device float4* folded [[buffer(5)]],
                          constant Bank& p [[buffer(0)]], uint t [[thread_position_in_threadgroup]]) {
        threadgroup float cond[32], mixed[16];
        uint n = p.oh * p.ow;
        if (t < 32) {
            float sum = 0;
            for (uint q = 0; q < n; q++) {
                float z = wts[OFF_cond5_bias + t];
                for (uint c = 0; c < 128; c++) z += wts[OFF_cond5_weight + t * 128 + c] * src[c * n + q];
                sum += z;
            }
            cond[t] = sum / float(n);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (t < 16) {
            float a = wts[OFF_mix_bias + t];
            for (uint k = 0; k < 32; k++) a += wts[OFF_mix_weight + t * 32 + k] * cond[k];
            mixed[t] = a;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (t < 4) folded[t] = float4(mixed[t * 4], mixed[t * 4 + 1], mixed[t * 4 + 2], mixed[t * 4 + 3]);
    }

    kernel void bank_mix(device const float4* folded [[buffer(5)]], device float4* mixed [[buffer(6)]], device const float* wts [[buffer(4)]],
                         uint gid [[thread_position_in_grid]]) {
        const uint cube = 33 * 33 * 33;
        if (gid >= cube) return;
        float3 sum = 0;
        for (uint k = 0; k < 16; k++) {
            uint base = OFF_tables + k * 3 * cube + gid;
            sum += folded[k / 4][k % 4] * float3(wts[base], wts[base + cube], wts[base + 2 * cube]);
        }
        mixed[gid] = float4(sum, 0);
    }

    kernel void bank_table(device const float4* mixed [[buffer(6)]], texture3d<float, access::write> table [[texture(2)]],
                           uint3 gid [[thread_position_in_grid]]) {
        if (any(gid >= 65)) return;
        float3 x = float3(gid) / 64.0;
        const uint S = 33;
        float3 g = x * float(S - 1);
        uint3 i0 = uint3(min(floor(g), float3(S - 2)));
        float3 f = g - float3(i0), o = 0;
        for (uint d = 0; d < 8; d++) {
            uint3 off = uint3(d >> 2, (d >> 1) & 1, d & 1), at = i0 + off;
            float w = (off.x ? f.x : 1.0 - f.x) * (off.y ? f.y : 1.0 - f.y) * (off.z ? f.z : 1.0 - f.z);
            o += w * mixed[(at.z * S + at.y) * S + at.x].xyz;
        }
        table.write(float4(clamp(bt2408(x) + o, 0.0, 1.0), 1.0), gid);
    }
    """

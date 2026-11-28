import CoreVideo
import Metal
import XCTest

@testable import Runner

/// The iPad's upscale itself (LambentLiftProcessor with `hdr` off, as the iPad runs it): a smooth 960 x 540 picture through each
/// scaler to 1920 x 1080, checked against the same picture drawn at that size. Correctness only: the simulator's GPU and Neural
/// Engine say nothing of a device's timing.
final class LambentUpscalePictureTests: XCTestCase {
  private static let src = (960, 540), dst = (1920, 1080)

  /// 8-bit luma code at (u, v) in [0, 1]: low-frequency waves, well inside video range.
  private static func luma(_ u: Double, _ v: Double) -> Double {
    16 + 219 * (0.5 + 0.35 * sin(2 * .pi * 3 * u) * cos(2 * .pi * 2 * v))
  }

  private func picture() throws -> CVPixelBuffer {
    var made: CVPixelBuffer?
    let attrs: [String: Any] = [
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    CVPixelBufferCreate(
      nil, Self.src.0, Self.src.1, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &made)
    let buffer = try XCTUnwrap(made)
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let (w, h) = Self.src
    let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    let yRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    for row in 0..<h {
      for col in 0..<w {
        let value = Self.luma((Double(col) + 0.5) / Double(w), (Double(row) + 0.5) / Double(h))
        y[row * yRow + col] = UInt8(value.rounded())
      }
    }
    let c = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
    let cRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    for row in 0..<(h / 2) { for col in 0..<w { c[row * cRow + col] = 128 } }
    return buffer
  }

  /// Mean and largest difference of the output's luma from the picture drawn at its size, in 8-bit codes, away from the edges.
  private func error(_ out: CVPixelBuffer) -> (mean: Double, max: Double) {
    CVPixelBufferLockBaseAddress(out, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
    let (w, h) = (CVPixelBufferGetWidth(out), CVPixelBufferGetHeight(out))
    let y = CVPixelBufferGetBaseAddressOfPlane(out, 0)!.assumingMemoryBound(to: UInt16.self)
    let row = CVPixelBufferGetBytesPerRowOfPlane(out, 0) / 2
    var sum = 0.0, most = 0.0, n = 0.0
    for r in stride(from: 16, to: h - 16, by: 3) {
      for c in stride(from: 16, to: w - 16, by: 3) {
        // P010: the 10-bit code in the top bits.
        let got = Double(y[r * row + c] >> 6) / 4
        let want = Self.luma((Double(c) + 0.5) / Double(w), (Double(r) + 0.5) / Double(h))
        sum += abs(got - want)
        most = max(most, abs(got - want))
        n += 1
      }
    }
    return (sum / n, most)
  }

  private func upscale(with scaler: LambentLiftProcessor.Scaler) throws -> CVPixelBuffer? {
    let processor = try XCTUnwrap(LambentLiftProcessor())
    processor.reset()
    processor.hdr = false
    processor.frameRate = 24
    processor.outputSize = Self.dst
    processor.force(scaler)
    guard processor.ladder.first == scaler else { return nil }
    return processor.process(try picture(), deadline: .infinity)
  }

  private func check(_ scaler: LambentLiftProcessor.Scaler, mean: Double, file: StaticString = #filePath, line: UInt = #line) throws {
    guard let out = try upscale(with: scaler) else {
      throw XCTSkip("\(scaler) is not available here")
    }
    XCTAssertEqual(CVPixelBufferGetWidth(out), Self.dst.0, file: file, line: line)
    XCTAssertEqual(CVPixelBufferGetHeight(out), Self.dst.1, file: file, line: line)
    // Upscaling only: the picture keeps its own colours (BT.709 SDR), never HDR10.
    let transfer = CVBufferCopyAttachment(out, kCVImageBufferTransferFunctionKey, nil) as? String
    XCTAssertEqual(transfer, kCVImageBufferTransferFunction_ITU_R_709_2 as String, file: file, line: line)
    let e = error(out)
    print("[LambentUpscalePictureTests] \(scaler): mean \(e.mean) max \(e.max) (8-bit codes)")
    XCTAssertLessThan(e.mean, mean, "\(scaler)", file: file, line: line)
  }

  func testCatmullRom() throws { try check(.catmullRom, mean: 1.5) }

  func testRavuLite() throws { try check(.prescaler("ravu-lite-ar-r3"), mean: 1.5) }

  /// What a title without a plan's step gets: RAVU-lite off the free ladder, whatever else the device could run.
  func testTheFreeLadderUpscalesWithRavuLite() throws {
    let processor = try XCTUnwrap(LambentLiftProcessor())
    let whole = processor.ladder
    processor.reset()
    processor.useLadder(free: true)
    XCTAssertEqual(processor.scaler, .prescaler("ravu-lite-ar-r3"))
    XCTAssertFalse(processor.ladder.contains { $0.isNeural })
    processor.hdr = false
    processor.frameRate = 24
    processor.outputSize = Self.dst
    let out = try XCTUnwrap(processor.process(try picture(), deadline: .infinity))
    XCTAssertEqual(CVPixelBufferGetWidth(out), Self.dst.0)
    XCTAssertLessThan(error(out).mean, 1.5)
    // A later title with a plan's step gets the device's whole ladder back.
    processor.useLadder(free: false)
    XCTAssertEqual(processor.ladder, whole)
  }

  func testFSRCNNX() throws { try check(.prescaler("FSRCNNX_x2_8-0-4-1"), mean: 2) }

  /// Loads the network's model for the test picture's size and waits for it (while one loads the shaders take the picture).
  private func loadNetwork(student: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let size = try XCTUnwrap(LambentNeuralScaler.size(for: Self.src.0, Self.src.1, network: "neural-low", student: student))
    XCTAssertNotNil(
      LambentNeuralScaler.loadNow("neural-low", student: student, size: size, device: device),
      LambentNeuralScaler.failures["neural-low"] ?? "", file: file, line: line)
  }

  /// The output is the network's, not a shader's standing in for it.
  private func checkNeural(fast: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    try loadNetwork(student: fast)
    let processor = try XCTUnwrap(LambentLiftProcessor())
    processor.force(.neural(fast: fast))
    processor.reset()
    processor.hdr = false
    processor.outputSize = Self.dst
    let source = try picture()
    let prepared = try XCTUnwrap(processor.prepare(source), "the network did not take the picture", file: file, line: line)
    XCTAssertEqual(prepared.scaler.f, fast ? 4 : 2, file: file, line: line)
    let out = try XCTUnwrap(processor.process(source, deadline: .infinity, prepared: prepared))
    let e = error(out)
    print("[LambentUpscalePictureTests] \(processor.scaler) at \(prepared.scaler.size): mean \(e.mean) max \(e.max) (8-bit codes)")
    XCTAssertLessThan(e.mean, 3, file: file, line: line)
  }

  func testAIUpscaler() throws {
    guard LambentNeuralScaler.available(student: false) else { throw XCTSkip("no AI upscaler models in the bundle") }
    try checkNeural(fast: false)
  }

  func testAIUpscalerStudent() throws {
    guard LambentNeuralScaler.available(student: true) else { throw XCTSkip("no Neural Engine student in the bundle") }
    try checkNeural(fast: true)
  }

  /// A picture runs on the smallest model that takes it: the Neural Engine's time follows the model's area.
  func testAPictureRunsOnTheSmallestModelThatTakesIt() throws {
    guard LambentNeuralScaler.sizes.allSatisfy({ LambentNeuralScaler.modelURL("neural-low", size: $0, int8: false) != nil }) else {
      throw XCTSkip("not every size of the AI upscaler's models is in the bundle")
    }
    func size(_ w: Int, _ h: Int) -> [Int]? {
      LambentNeuralScaler.size(for: w, h, network: "neural-low", student: false).map { [$0.0, $0.1] }
    }
    XCTAssertEqual(size(1920, 1080), [1920, 1088])
    XCTAssertEqual(size(1920, 800), [1920, 832])
    XCTAssertEqual(size(1920, 816), [1920, 832])
    XCTAssertEqual(size(1440, 1080), [1920, 1088])
    XCTAssertEqual(size(1280, 720), [1280, 736])
    XCTAssertEqual(size(960, 540), [1280, 736])
    XCTAssertEqual(size(720, 576), [768, 576])
    XCTAssertEqual(size(720, 480), [768, 576])
    XCTAssertNil(size(2560, 1440))
    XCTAssertEqual(LambentNeuralScaler.area(1280, 720, network: "neural-low", student: false), 0.451, accuracy: 0.001)
    XCTAssertEqual(LambentNeuralScaler.area(1920, 1080, network: "neural-low", student: false), 1)
  }

  /// The network follows the title's bits a pixel by its codec, as Lambent Server's rule has it.
  func testTheNetworkFollowsTheCodecsBitsAPixel() {
    func network(_ megabits: Double, _ codec: String) -> String {
      LambentNeuralScaler.network(bitrate: Int64(megabits * 1e6), width: 1920, height: 1080, frameRate: 24, codec: codec)
    }
    // 1080p at 24 fps: 0.20 bits a pixel is 9.95 Mbit/s, 0.15 is 7.46, 0.40 is 19.9.
    XCTAssertEqual(network(9, "h264"), "neural-low")
    XCTAssertEqual(network(11, "h264"), "neural-hb")
    XCTAssertEqual(network(7, "hevc"), "neural-low")
    XCTAssertEqual(network(8, "hevc"), "neural-hb")
    XCTAssertEqual(network(8, "av1"), "neural-hb")
    XCTAssertEqual(network(15, "mpeg2video"), "neural-low")
    XCTAssertEqual(network(21, "mpeg2video"), "neural-hb")
    XCTAssertEqual(network(11, ""), "neural-hb")
    XCTAssertEqual(network(0, "h264"), "neural-low")
  }

  /// While the network's model loads (nothing was packed for the picture), the first shader below it shows the picture, not the
  /// network's student (nothing was packed for that either).
  func testWhileTheNetworkLoadsAShaderTakesThePicture() throws {
    guard LambentNeuralScaler.available(student: false), LambentNeuralScaler.available(student: true) else {
      throw XCTSkip("no AI upscaler models in the bundle")
    }
    let processor = try XCTUnwrap(LambentLiftProcessor())
    processor.force(ladder: [.neural(fast: false), .neural(fast: true), .catmullRom, .none])
    processor.reset()
    processor.hdr = false
    processor.pipelined = true
    processor.outputSize = Self.dst
    let out = try XCTUnwrap(processor.process(try picture(), deadline: .infinity, prepared: nil))
    XCTAssertLessThan(error(out).mean, 1.5)
    XCTAssertTrue(processor.scaler.isNeural, "still the network's title: \(processor.scaler)")
  }

  /// Under 1.4x the AI upscaler steps aside for the shaders (to Catmull-Rom); at 2x it stays.
  func testTheAIUpscalerStepsAsideUnder1_4x() throws {
    guard let device = MTLCreateSystemDefaultDevice(), LambentNeuralScaler.available(student: false) else {
      throw XCTSkip("no AI upscaler models in the bundle")
    }
    _ = device
    try loadNetwork(student: false)
    let processor = try XCTUnwrap(LambentLiftProcessor())
    processor.force(ladder: [.neural(fast: false), .catmullRom, .none])
    processor.reset()
    processor.hdr = false
    processor.outputSize = (1194, 671)  // 1.24x: a 1080p title full screen on an 11-inch iPad Pro
    let source = try picture()
    XCTAssertNil(processor.pack(source))
    let out = try XCTUnwrap(processor.process(source, deadline: .infinity))
    XCTAssertEqual(CVPixelBufferGetWidth(out), 1194)
    XCTAssertFalse(processor.scaler.isNeural, "\(processor.scaler)")
    XCTAssertEqual(LambentClientUpscale.label(processor.scaler), "Shader upscale")

    let twice = try XCTUnwrap(LambentLiftProcessor())
    twice.force(ladder: [.neural(fast: false), .catmullRom, .none])
    twice.reset()
    twice.hdr = false
    twice.outputSize = Self.dst
    XCTAssertNotNil(twice.pack(source))
    _ = twice.process(source, deadline: .infinity)
    XCTAssertTrue(twice.scaler.isNeural, "\(twice.scaler)")
  }

  /// Nothing to upscale (the picture already fills its place): the picture comes back as it is.
  func testAPictureAtItsSizeIsLeftAlone() throws {
    let processor = try XCTUnwrap(LambentLiftProcessor())
    processor.reset()
    processor.hdr = false
    processor.outputSize = Self.src
    let source = try picture()
    XCTAssertTrue(processor.process(source, deadline: .infinity) === source)
  }

  // MARK: The picture's own Y'CbCr (matrix and chroma siting)

  /// A 640 x 360 colour picture (smooth, so chroma's 2 x 2 blocks cost nothing): R'G'B' at (u, v) in [0, 1].
  private static func colour(_ u: Double, _ v: Double) -> (Double, Double, Double) {
    (0.15 + 0.7 * u, 0.15 + 0.7 * v, 0.5 + 0.35 * sin(2 * .pi * (u + v)))
  }

  /// `rgb` as 8-bit 4:2:0 video range in the matrix (kr, kb), each chroma sample taken where MPEG-2's siting has it (beside the left
  /// pixels of its block, half way down); tagged `matrix` when given.
  private func encoded(
    _ w: Int, _ h: Int, kr: Double, kb: Double, matrix: CFString?, rgb: (Double, Double) -> (Double, Double, Double)
  ) throws -> CVPixelBuffer {
    var made: CVPixelBuffer?
    let attrs: [String: Any] = [
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &made)
    let buffer = try XCTUnwrap(made)
    if let matrix { CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate) }
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    func ycc(_ u: Double, _ v: Double) -> (Double, Double, Double) {
      let (r, g, b) = rgb(u, v)
      let y = kr * r + (1 - kr - kb) * g + kb * b
      return (16 + 219 * y, 128 + 224 * (b - y) / (2 * (1 - kb)), 128 + 224 * (r - y) / (2 * (1 - kr)))
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    let yRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    for row in 0..<h {
      for col in 0..<w { y[row * yRow + col] = UInt8(ycc((Double(col) + 0.5) / Double(w), (Double(row) + 0.5) / Double(h)).0.rounded()) }
    }
    let c = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
    let cRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    for row in 0..<(h / 2) {
      for col in 0..<(w / 2) {
        // The middle of luma column 2 col, between luma rows 2 row and 2 row + 1.
        let (_, cb, cr) = ycc((Double(2 * col) + 0.5) / Double(w), Double(2 * row + 1) / Double(h))
        (c[row * cRow + 2 * col], c[row * cRow + 2 * col + 1]) = (UInt8(cb.rounded()), UInt8(cr.rounded()))
      }
    }
    return buffer
  }

  /// A picture that names BT.601 is lifted as the same picture in BT.709 is: the lift reads Y'CbCr by the picture's own matrix.
  func testABT601PictureIsLiftedByItsOwnMatrix() throws {
    let processor = try XCTUnwrap(LambentLiftProcessor())
    guard processor.canLift else { throw XCTSkip("Auto HDR's tables are not in this bundle") }
    func lifted(_ picture: CVPixelBuffer, to size: (Int, Int)?) throws -> [Double] {
      processor.force(.catmullRom)
      processor.reset()
      processor.hdr = true
      processor.outputSize = size
      let out = try XCTUnwrap(processor.process(picture, deadline: .infinity))
      CVPixelBufferLockBaseAddress(out, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
      let y = CVPixelBufferGetBaseAddressOfPlane(out, 0)!.assumingMemoryBound(to: UInt16.self)
      let row = CVPixelBufferGetBytesPerRowOfPlane(out, 0) / 2
      let (w, h) = (CVPixelBufferGetWidth(out), CVPixelBufferGetHeight(out))
      return stride(from: h / 8, to: h, by: h / 8).flatMap { r in stride(from: w / 8, to: w, by: w / 8).map { Double(y[r * row + $0] >> 6) } }
    }
    let bt709 = try encoded(640, 360, kr: 0.2126, kb: 0.0722, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2, rgb: Self.colour)
    let bt601 = try encoded(640, 360, kr: 0.299, kb: 0.114, matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4, rgb: Self.colour)
    for size in [nil, (1280, 720)] as [(Int, Int)?] {
      let (a, b) = (try lifted(bt709, to: size), try lifted(bt601, to: size))
      let worst = zip(a, b).map { abs($0 - $1) }.max() ?? 0
      print("[LambentUpscalePictureTests] BT.601 against BT.709, lifted\(size == nil ? "" : " and upscaled"): worst \(worst) of 1023")
      XCTAssertLessThan(worst, 6, "10-bit PQ luma codes, the same picture in the two matrices")
    }
  }

  /// A picture that names no matrix is read by its size's convention (BT.601 for SD), and the upscaled picture says which: at its new
  /// size the system would guess BT.709.
  func testAPictureWithoutAMatrixIsReadByItsSize() throws {
    let sd = try encoded(640, 360, kr: 0.299, kb: 0.114, matrix: nil, rgb: Self.colour)
    XCTAssertEqual(LambentYCbCr(picture: sd), .bt601)
    XCTAssertEqual(LambentYCbCr(picture: try picture()), .bt709)
    XCTAssertEqual(LambentYCbCr(picture: try encoded(1280, 720, kr: 0.2126, kb: 0.0722, matrix: nil, rgb: Self.colour)), .bt709)
    let processor = try XCTUnwrap(LambentLiftProcessor())
    processor.force(.catmullRom)
    processor.reset()
    processor.hdr = false
    processor.outputSize = (1280, 720)
    let out = try XCTUnwrap(processor.process(sd, deadline: .infinity))
    XCTAssertEqual(CVBufferCopyAttachment(out, kCVImageBufferYCbCrMatrixKey, nil) as? String, kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
  }

  /// Chroma is read where it sits. A picture whose Cb is a wave across (and whose samples sit beside the left pixels, as H.264's do)
  /// comes out with each chroma sample holding the wave at its own place, not half a picture pixel to its right: the wave fitted to
  /// the output's chroma is within a third of an output pixel of where it was drawn. `mean`: and the samples within that many 8-bit
  /// codes of it (the shaders; the network redraws a wave like no film's by a code or so).
  private func checkSiting(
    _ scaler: LambentLiftProcessor.Scaler, to dst: (Int, Int), mean: Double? = nil, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let (w, h) = (640, 360)
    // 20 waves across: 32 picture pixels a wave, well inside what 4:2:0 carries, and small enough to stay inside R'G'B' (the network
    // works there). Read half an output pixel off its place at 2x, the mean error is 1.4 codes.
    func wave(_ u: Double) -> Double { 0.2 * sin(2 * .pi * 20 * u) }
    let source = try encoded(w, h, kr: 0.2126, kb: 0.0722, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2) { u, _ in
      // Y' 0.5 and Cb the wave (Cr none), as R'G'B'.
      let cb = wave(u)
      return (0.5, 0.5 - 0.0722 * 1.8556 / 0.7152 * cb, 0.5 + 1.8556 * cb)
    }
    let processor = try XCTUnwrap(LambentLiftProcessor())
    processor.force(scaler)
    processor.reset()
    processor.hdr = false
    processor.outputSize = dst
    guard processor.ladder.first == scaler else { throw XCTSkip("\(scaler) is not available here") }
    var prepared: LambentLiftProcessor.NeuralPrepared?
    if case .neural(let fast) = scaler {
      let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
      let size = try XCTUnwrap(LambentNeuralScaler.size(for: w, h, network: "neural-low", student: fast))
      XCTAssertNotNil(LambentNeuralScaler.loadNow("neural-low", student: fast, size: size, device: device))
      prepared = try XCTUnwrap(processor.prepare(source))
    }
    let out = try XCTUnwrap(processor.process(source, deadline: .infinity, prepared: prepared))
    CVPixelBufferLockBaseAddress(out, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
    let c = CVPixelBufferGetBaseAddressOfPlane(out, 1)!.assumingMemoryBound(to: UInt16.self)
    let row = CVPixelBufferGetBytesPerRowOfPlane(out, 1) / 2
    var sum = 0.0, n = 0.0, inPhase = 0.0, quadrature = 0.0
    for r in stride(from: 8, to: dst.1 / 2 - 8, by: 5) {
      for col in 8..<(dst.0 / 2 - 8) {
        // The output's chroma sample: beside the left pixel of its pair, as the picture's.
        let u = (Double(2 * col) + 0.5) / Double(dst.0)
        let got = Double(c[r * row + 2 * col]) / 256
        sum += abs(got - (128 + 224 * wave(u)))
        inPhase += (got - 128) * sin(2 * .pi * 20 * u)
        quadrature += (got - 128) * cos(2 * .pi * 20 * u)
        n += 1
      }
    }
    // The wave in the output: its size against the one drawn, and how far to the right of it, in output pixels.
    let size = 2 * (inPhase * inPhase + quadrature * quadrature).squareRoot() / n / (224 * 0.2)
    let right = -atan2(quadrature, inPhase) / (2 * .pi * 20) * Double(dst.0)
    print(
      "[LambentUpscalePictureTests] chroma siting, \(scaler) to \(dst.0)x\(dst.1): mean \(sum / n) (8-bit codes), the wave "
        + "\(size) of its size, \(right) output pixels to the right")
    XCTAssertEqual(right, 0, accuracy: 0.33, "\(scaler)", file: file, line: line)
    XCTAssertEqual(size, 1, accuracy: 0.03, "\(scaler)", file: file, line: line)
    if let mean { XCTAssertLessThan(sum / n, mean, "\(scaler)", file: file, line: line) }
  }

  func testChromaIsReadWhereItSitsByTheShaders() throws {
    try checkSiting(.catmullRom, to: (1280, 720), mean: 1)
    try checkSiting(.catmullRom, to: (1920, 1080), mean: 1)
    try checkSiting(.prescaler("ravu-lite-ar-r3"), to: (1280, 720), mean: 1)
  }

  func testChromaIsReadWhereItSitsByTheAIUpscaler() throws {
    guard LambentNeuralScaler.available(student: false) else { throw XCTSkip("no AI upscaler models in the bundle") }
    try checkSiting(.neural(fast: false), to: (1280, 720))
    // Not twice the picture: the network's finish, then the last pass.
    try checkSiting(.neural(fast: false), to: (1920, 1080))
  }

  // MARK: Auto HDR (the bank of sixteen tables)

  /// The picture Lambent's companion/shaders/lutg/reference.py has numbers for (the Vision Pro's HDRLiftTests use it too): a luma ramp
  /// across, Cb down and Cr across on the left half, neutral on the right (8-bit, video range, 640 x 360).
  private func referencePicture() throws -> CVPixelBuffer {
    let (w, h) = (640, 360)
    var made: CVPixelBuffer?
    let attrs: [String: Any] = [
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &made)
    let buffer = try XCTUnwrap(made)
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    CVPixelBufferLockBaseAddress(buffer, [])
    let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    let yRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    for r in 0..<h { for x in 0..<w { y[r * yRow + x] = UInt8(16 + (219 * Double(x) / Double(w - 1) + 0.5).rounded(.down)) } }
    let c = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
    let cRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    for r in 0..<(h / 2) {
      for x in 0..<(w / 2) {
        let cb: UInt8 = x >= w / 2 ? 128 : UInt8(128 + (96 * Double(r) / Double(h / 2 - 1) - 48 + 0.5).rounded(.down))
        let cr: UInt8 = x >= w / 2 ? 128 : UInt8(128 + (96 * Double(x) / Double(w / 2 - 1) - 48 + 0.5).rounded(.down))
        (c[r * cRow + 2 * x], c[r * cRow + 2 * x + 1]) = (cb, cr)
      }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
  }

  private static let referencePoints = [(40, 30), (160, 90), (320, 180), (480, 270), (600, 330), (100, 300), (540, 40), (320, 20)]
  /// reference.py's 10-bit luma codes at those points (its chroma filtered; the lift here reads each 2 x 2 block's chroma, so a code
  /// may differ by a little more than the headset's).
  private static let referenceCodes = [227.1, 328.18, 468.37, 577.18, 616.65, 264.79, 598.32, 470.36]

  /// Auto HDR on this device is the bank of sixteen tables, as reference.py makes the picture: HDR10 out, and the codes within a few.
  func testAutoHDRIsTheBankOfTables() throws {
    let processor = try XCTUnwrap(LambentLiftProcessor())
    guard processor.canLift else { throw XCTSkip("Auto HDR's tables are not in this bundle (tvos/scripts/copy_autohdr_weights.sh)") }
    processor.reset()
    processor.hdr = true
    processor.frameRate = 24
    processor.outputSize = nil
    let out = try XCTUnwrap(processor.process(try referencePicture(), deadline: .infinity))
    let transfer = CVBufferCopyAttachment(out, kCVImageBufferTransferFunctionKey, nil) as? String
    XCTAssertEqual(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
    CVPixelBufferLockBaseAddress(out, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
    let y = CVPixelBufferGetBaseAddressOfPlane(out, 0)!.assumingMemoryBound(to: UInt16.self)
    let row = CVPixelBufferGetBytesPerRowOfPlane(out, 0) / 2
    for ((px, py), expected) in zip(Self.referencePoints, Self.referenceCodes) {
      let code = Double(y[py * row + px] >> 6)
      print("[LambentUpscalePictureTests] Auto HDR at (\(px), \(py)): \(code), reference \(expected)")
      XCTAssertEqual(code, expected, accuracy: 4, "the bank of tables' picture at (\(px), \(py))")
    }
  }

  /// Upscaled and lifted in one: the 4K output is HDR10 through the same table.
  func testAutoHDRUpscaled() throws {
    let processor = try XCTUnwrap(LambentLiftProcessor())
    guard processor.canLift else { throw XCTSkip("Auto HDR's tables are not in this bundle") }
    processor.reset()
    processor.hdr = true
    processor.frameRate = 24
    processor.outputSize = (1280, 720)
    processor.force(.catmullRom)
    let out = try XCTUnwrap(processor.process(try referencePicture(), deadline: .infinity))
    XCTAssertEqual(CVPixelBufferGetWidth(out), 1280)
    let transfer = CVBufferCopyAttachment(out, kCVImageBufferTransferFunctionKey, nil) as? String
    XCTAssertEqual(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
  }
}

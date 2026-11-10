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
    processor.reset(deepen: false)
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
    processor.reset(deepen: false)
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

  func testAIUpscaler() throws {
    guard let device = MTLCreateSystemDefaultDevice(), LambentNeuralScaler.available(student: false) else {
      throw XCTSkip("no AI upscaler models in the bundle")
    }
    XCTAssertNotNil(LambentNeuralScaler.loadNow("neural-low", device: device), LambentNeuralScaler.failures["neural-low"] ?? "")
    try check(.neural(fast: false), mean: 3)
  }

  func testAIUpscalerStudent() throws {
    guard let device = MTLCreateSystemDefaultDevice(), LambentNeuralScaler.available(student: true) else {
      throw XCTSkip("no Neural Engine student in the bundle")
    }
    XCTAssertNotNil(LambentNeuralScaler.loadNow("neural-low", student: true, device: device))
    try check(.neural(fast: true), mean: 3)
  }

  /// Under 1.4x the AI upscaler steps aside for the shaders (to Catmull-Rom); at 2x it stays.
  func testTheAIUpscalerStepsAsideUnder1_4x() throws {
    guard let device = MTLCreateSystemDefaultDevice(), LambentNeuralScaler.available(student: false) else {
      throw XCTSkip("no AI upscaler models in the bundle")
    }
    XCTAssertNotNil(LambentNeuralScaler.loadNow("neural-low", device: device))
    let processor = try XCTUnwrap(LambentLiftProcessor())
    processor.force(ladder: [.neural(fast: false), .catmullRom, .none])
    processor.reset(deepen: false)
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
    twice.reset(deepen: false)
    twice.hdr = false
    twice.outputSize = Self.dst
    XCTAssertNotNil(twice.pack(source))
    _ = twice.process(source, deadline: .infinity)
    XCTAssertTrue(twice.scaler.isNeural, "\(twice.scaler)")
  }

  /// Nothing to upscale (the picture already fills its place): the picture comes back as it is.
  func testAPictureAtItsSizeIsLeftAlone() throws {
    let processor = try XCTUnwrap(LambentLiftProcessor())
    processor.reset(deepen: false)
    processor.hdr = false
    processor.outputSize = Self.src
    let source = try picture()
    XCTAssertTrue(processor.process(source, deadline: .infinity) === source)
  }
}

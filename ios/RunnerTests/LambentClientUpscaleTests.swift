import Metal
import XCTest

@testable import Runner

/// The client's upscale is a step of Lambent Server's plan (LambentClientUpscale.swift), and its scaler follows the device's GPU.
final class LambentClientUpscaleTests: XCTestCase {
  private let enhanced = "http://192.168.1.20:47800/v1/enhanced/i_42/index.m3u8?tv=1&q=4&hdr=1&dv=0&blacks=0&maxh=1080&audio=0"

  // MARK: - The plan's step

  func testThePlanAsksWithCup() {
    XCTAssertEqual(LambentClientUpscale.planHeight(URL(string: enhanced + "&cup=2160&t=abc")), 2160)
    XCTAssertEqual(LambentClientUpscale.planHeight(URL(string: enhanced + "&CUP=1440")), 1440)
  }

  func testWithoutCupNothingUpscalesHere() {
    // Without Lambent Enhance or a trial the plan does not ask, whatever the stream is.
    XCTAssertNil(LambentClientUpscale.planHeight(URL(string: enhanced)))
    XCTAssertNil(LambentClientUpscale.planHeight(URL(string: enhanced + "&cmp=1")))
    XCTAssertNil(LambentClientUpscale.planHeight(nil))
  }

  func testACupThatIsNotALineCountDoesNotAsk() {
    XCTAssertNil(LambentClientUpscale.planHeight(URL(string: enhanced + "&cup=0")))
    XCTAssertNil(LambentClientUpscale.planHeight(URL(string: enhanced + "&cup=-2160")))
    XCTAssertNil(LambentClientUpscale.planHeight(URL(string: enhanced + "&cup=on")))
    XCTAssertNil(LambentClientUpscale.planHeight(URL(string: enhanced + "&cup=")))
  }

  func testOnlyLambentsEnhancedStreamCarriesThePlan() {
    // A direct play or Jellyfin's own transcode has no plan step, even with a `cup` in its query.
    XCTAssertNil(LambentClientUpscale.planHeight(URL(string: "http://192.168.1.20:47800/Videos/i_42/stream?static=true&cup=2160")))
    XCTAssertNil(LambentClientUpscale.planHeight(URL(string: "file:///var/mobile/Downloads/film.mkv?cup=2160")))
  }

  func testThePlanGivesTheLiftWithChdr() {
    XCTAssertTrue(LambentClientUpscale.planLift(URL(string: enhanced + "&chdr=1")))
    XCTAssertTrue(LambentClientUpscale.planLift(URL(string: enhanced + "&CHDR=1&cup=2160")))
    XCTAssertFalse(LambentClientUpscale.planLift(URL(string: enhanced)))
    XCTAssertFalse(LambentClientUpscale.planLift(URL(string: enhanced + "&chdr=0")))
    XCTAssertFalse(LambentClientUpscale.planLift(URL(string: "http://192.168.1.20:47800/Videos/i_42/stream?static=true&chdr=1")))
  }

  // MARK: - Only what is worth the iPad's power

  private func work(
    lift: Bool = false, hdrSource: Bool = false, headroom: CGFloat = 2, lowPower: Bool = false, cup: Bool = true,
    picture: (Int, Int) = (1920, 1080), fitted: (Int, Int) = (2388, 1343)
  ) -> LambentClientUpscale.Work? {
    LambentClientUpscale.iPadWork(
      liftAsked: lift, sourceHDR: hdrSource, headroom: headroom, lowPower: lowPower, upscaleAsked: cup, picture: picture,
      fitted: fitted)
  }

  func testA1080pTitleFullScreenIsLeftToAVPlayer() {
    // 1.24x on an 11-inch iPad Pro: nothing worth the Metal path.
    XCTAssertNil(work())
    // A 720p title there is 1.86x: upscaled.
    XCTAssertEqual(work(picture: (1280, 720)), .init(hdr: false, size: (2388, 1343)))
  }

  func testTheLiftRunsWhenThePlanAsksAndTheScreenHasTheHeadroom() {
    // With the lift running anyway, its last pass scales too.
    XCTAssertEqual(work(lift: true), .init(hdr: true, size: (2388, 1343)))
    // Without `cup` the lifted picture keeps its size.
    XCTAssertEqual(work(lift: true, cup: false), .init(hdr: true, size: nil))
  }

  func testNoLiftWithoutHeadroomInLowPowerModeOrForAnHDRPicture() {
    XCTAssertNil(work(lift: true, headroom: 1, cup: false))
    XCTAssertNil(work(lift: true, lowPower: true, cup: false))
    XCTAssertNil(work(lift: true, hdrSource: true, cup: false))
    // The PC's HDR10 is still upscaled where that pays.
    XCTAssertEqual(work(lift: true, hdrSource: true, picture: (1280, 720)), .init(hdr: false, size: (2388, 1343)))
  }

  func testWorkLabels() {
    XCTAssertEqual(LambentClientUpscale.label(hdr: true, scaler: nil), "Auto HDR")
    XCTAssertEqual(LambentClientUpscale.label(hdr: true, scaler: .catmullRom), "Auto HDR · Shader upscale")
    XCTAssertEqual(LambentClientUpscale.label(hdr: false, scaler: .neural(fast: false)), "AI upscale")
    XCTAssertNil(LambentClientUpscale.label(hdr: false, scaler: LambentLiftProcessor.Scaler.none))
  }

  // MARK: - Device selection

  /// A GPU of Apple family `family` (7: A14, M1; 8: A15, A16, M2; 9: A17 Pro, M3, M4; 10: A19, M5).
  private func ladder(family: Int, models: Bool = true) -> [LambentLiftProcessor.Scaler] {
    LambentClientUpscale.ladder(
      supports: { $0.rawValue >= MTLGPUFamily.apple1.rawValue && $0.rawValue <= MTLGPUFamily.apple1.rawValue + family - 1 },
      neuralModels: { _ in models })
  }

  private let shaders: [LambentLiftProcessor.Scaler] = [.prescaler("ravu-lite-ar-r3"), .catmullRom, .none]

  func testAnA14OrM1IPadUpscalesWithTheShaders() {
    XCTAssertEqual(ladder(family: 7), shaders)
    XCTAssertEqual(ladder(family: 5), shaders)  // A12: iPad 8th generation, iPad mini 5
  }

  func testFromTheA15TheAIUpscalerLeads() {
    // A15 (iPad mini 6), A16 (iPad 11th generation), M2 (iPad Air, iPad Pro): the network, then its student for 50 / 60 fps.
    XCTAssertEqual(ladder(family: 8), [.neural(fast: false), .neural(fast: true)] + shaders)
    // A17 Pro (iPad mini 7), M3 (iPad Air), M4 (iPad Pro): the same; FSRCNNX still waits for an A19-class GPU.
    XCTAssertEqual(ladder(family: 9), [.neural(fast: false), .neural(fast: true)] + shaders)
  }

  func testAnA19OrM5AddsFSRCNNX() {
    XCTAssertEqual(
      ladder(family: 10), [.neural(fast: false), .neural(fast: true), .prescaler("FSRCNNX_x2_8-0-4-1")] + shaders)
  }

  func testWithoutTheModelsTheShadersLead() {
    XCTAssertEqual(ladder(family: 9, models: false), shaders)
  }

  func testThisDevicesLadderEndsAtNone() {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let mine = LambentClientUpscale.ladder(
      supports: { device.supportsFamily($0) }, neuralModels: { LambentNeuralScaler.available(student: $0) })
    XCTAssertEqual(mine.last, LambentLiftProcessor.Scaler.none)
  }

  func testTheAIUpscalerRunsFrom1_4x() {
    // A 1080p title full screen: 11-inch iPad Pro 1.24x, iPad mini 1.18x: the shaders.
    XCTAssertFalse(LambentClientUpscale.neuralPays(picture: (1920, 1080), output: (2388, 1343)))
    XCTAssertFalse(LambentClientUpscale.neuralPays(picture: (1920, 1080), output: (2266, 1274)))
    // 13-inch iPad Pro 1.43x, a 720p title on the 11-inch 1.86x, a 1080p title on a 4K TV 2x: the network.
    XCTAssertTrue(LambentClientUpscale.neuralPays(picture: (1920, 1080), output: (2752, 1548)))
    XCTAssertTrue(LambentClientUpscale.neuralPays(picture: (1280, 720), output: (2388, 1343)))
    XCTAssertTrue(LambentClientUpscale.neuralPays(picture: (1920, 1080), output: (3840, 2160)))
    // The smaller of the two scales decides (a wide title fit to the width).
    XCTAssertFalse(LambentClientUpscale.neuralPays(picture: (1920, 800), output: (3840, 1100)))
  }

  // MARK: - Where it is shown

  func testAnIPadPro11ShowsA1080pTitleAtItsWidth() {
    // 1210 x 834 points at 2 pixels a point: the picture fits the width, 2420 pixels.
    let size = LambentClientUpscale.outputSize(
      picture: (1920, 1080), bounds: CGSize(width: 1210, height: 834), scale: 2, maxHeight: 2160)
    XCTAssertEqual(size.0, 2420)
    XCTAssertEqual(size.1, 1361)
  }

  func testThePlansLinesCapTheUpscale() {
    let size = LambentClientUpscale.outputSize(
      picture: (1280, 720), bounds: CGSize(width: 1366, height: 1024), scale: 2, maxHeight: 1080)
    XCTAssertEqual(size.0, 1920)
    XCTAssertEqual(size.1, 1080)
  }

  func testAPictureBiggerThanItsPlaceIsNeverShrunkHere() {
    let size = LambentClientUpscale.outputSize(
      picture: (3840, 2160), bounds: CGSize(width: 1210, height: 834), scale: 2, maxHeight: 2160)
    XCTAssertEqual(size.0, 3840)
    XCTAssertEqual(size.1, 2160)
  }

  func testLabels() {
    XCTAssertEqual(LambentClientUpscale.label(.neural(fast: true)), "AI upscale")
    XCTAssertEqual(LambentClientUpscale.label(.prescaler("ravu-lite-ar-r3")), "Shader upscale")
    XCTAssertEqual(LambentClientUpscale.label(.catmullRom), "Shader upscale")
    XCTAssertNil(LambentClientUpscale.label(.none))
  }
}

import CoreGraphics
import Foundation
import Metal
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Lambent Enhance's upscale on the device (docs/MONETIZATION.md 5.1 in Lambent): a step of Lambent Server's plan, not a setting.
///
/// The plan says where each step runs ("PC: RTX HDR, 1080p out; client: upscale to 4K"). The client's step travels in the plan's
/// enhanced stream URL as `cup=<lines>`: upscale here, to at most that many lines. The query is the plan's own (the server signs it,
/// docs/ENTITLEMENTS.md 6.1), so without Lambent Enhance or a trial the plan has no `cup` and nothing is upscaled on the device. A
/// direct play has no plan URL: for a paid screen Flutter writes PlaybackInfo's `LambentDevice` onto the URL it opens, in the same
/// keys (docs/ENTITLEMENTS.md 6.6). The client keeps no paywall of its own.
///
/// RAVU-lite is free (`freeUpscale`): without a plan's step, a title from any server is scaled by it. It costs what a good bicubic costs
/// and needs no network or server. The plan's `cup` buys the rest of the ladder.
///
/// The plan has two steps for `LambentHDRLift`: `cup` upscales (the picture keeps the colours the PC sent, SDR or HDR10) and `chdr=1`
/// lifts an SDR picture to HDR10 here. The Apple TV does what the plan asks (`appleTVWork`); the iPad only what is worth its power
/// (`iPadWork`).
enum LambentClientUpscale {
    /// The query member that carries the client's step.
    static let planKey = "cup"

    /// The plan's client step for the stream at `url`: the most lines this device may upscale to; nil when the plan does not ask (no
    /// `cup`, a `cup` that is not a positive number, or a stream that is not Lambent's).
    static func planHeight(_ url: URL?) -> Int? {
        guard let url, carriesSteps(url),
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let value = items.last(where: { $0.name.lowercased() == planKey })?.value,
            let lines = Int(value.trimmingCharacters(in: .whitespaces)), lines > 0
        else { return nil }
        return lines
    }

    /// Lambent's enhanced stream, or a direct play of the file (`/Videos/<id>/stream[.ext]`).
    private static func carriesSteps(_ url: URL) -> Bool {
        url.path.contains("/v1/enhanced/") || url.path.range(of: #"/Videos/[^/]+/stream(\.\w+)?$"#, options: .regularExpression) != nil
    }

    /// Without a plan's step, RAVU-lite takes the picture: everything but a Lambent enhanced stream, which is the PC's picture (a compare
    /// among them, whose left half must stay the original).
    static func freeUpscale(_ url: URL?) -> Bool {
        guard let url, planHeight(url) == nil else { return false }
        return !url.path.contains("/v1/enhanced/")
    }

    /// The free ladder: RAVU-lite, then as the paid ladder ends.
    static let freeLadder: [LambentLiftProcessor.Scaler] = [.prescaler("ravu-lite-ar-r3"), .catmullRom, .none]

    /// The query member that carries the client's HDR step: `chdr=1`, "client: Auto HDR here" (the PC sends the picture SDR).
    static let liftKey = "chdr"

    /// The plan gives this device the HDR lift for the stream at `url` (`chdr=1`).
    static func planLift(_ url: URL?) -> Bool {
        guard let url, carriesSteps(url),
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return false }
        return items.last(where: { $0.name.lowercased() == liftKey })?.value?.trimmingCharacters(in: .whitespaces) == "1"
    }

    /// The least EDR headroom (the screen's brightest white over SDR white) the iPad lifts for: an 11-inch iPad Pro's LCD has 2, the
    /// mini-LED and OLED iPad Pros more; an iPad with less shows HDR10 squeezed back into SDR, so the lift would only cost power.
    static let liftHeadroom: CGFloat = 2

    /// What the device does with the picture.
    struct Work: Equatable {
        /// Lifted to HDR10 here.
        var hdr: Bool
        /// Scaled here to this size, in pixels; nil: at its own size (AVPlayer's display scales it).
        var size: (Int, Int)?

        static func == (a: Work, b: Work) -> Bool { a.hdr == b.hdr && a.size?.0 == b.size?.0 && a.size?.1 == b.size?.1 }
    }

    /// The iPad's work for a `picture`-sized picture whose place on the screen is `fitted` pixels (`outputSize`); nil when there is
    /// none worth its power and AVPlayer shows the picture itself. The lift when the plan asks (`liftAsked`), the picture is SDR and
    /// the screen has the headroom, never in Low Power Mode; the upscale when the plan asks (`upscaleAsked`) and the scale reaches
    /// `neuralMinimumScale` (a 720p title full screen; a 1080p one is 1.24x on an 11-inch iPad Pro, where Catmull-Rom would gain
    /// next to nothing on AVPlayer's own scaling and the copy through the Metal path costs power of its own). With the lift running
    /// anyway, its last pass scales too (Catmull-Rom: 0.5 ms against 0.1 ms on an M2).
    static func iPadWork(
        liftAsked: Bool, sourceHDR: Bool, headroom: CGFloat, lowPower: Bool, upscaleAsked: Bool, picture: (Int, Int), fitted: (Int, Int)
    ) -> Work? {
        let hdr = liftAsked && !sourceHDR && !lowPower && headroom >= liftHeadroom
        let pays = upscaleAsked && neuralPays(picture: picture, output: fitted)
        guard hdr || pays else { return nil }
        let larger = fitted.0 > picture.0 && fitted.1 > picture.1
        return Work(hdr: hdr, size: upscaleAsked && larger ? fitted : nil)
    }

    /// A Mac's work for a `picture`-sized picture shown at `fitted` pixels in a window that can grow to `wholeScreen` pixels; nil when
    /// neither step could ever run and AVPlayer shows the picture itself. The power rule is the iPad's (the lift needs the headroom, an
    /// external SDR display has none). The upscale stays ready while the window is small: it starts when the window grows.
    static func macWork(
        liftAsked: Bool, sourceHDR: Bool, headroom: CGFloat, lowPower: Bool, upscaleAsked: Bool, picture: (Int, Int), fitted: (Int, Int),
        wholeScreen: (Int, Int)
    ) -> Work? {
        let hdr = liftAsked && !sourceHDR && !lowPower && headroom >= liftHeadroom
        let grows = upscaleAsked && wholeScreen.0 > picture.0 * 6 / 5 && wholeScreen.1 > picture.1 * 6 / 5
        guard hdr || grows else { return nil }
        return Work(hdr: hdr, size: upscaleAsked && fitted.0 > picture.0 && fitted.1 > picture.1 ? fitted : nil)
    }

    /// The Apple TV's work for a `picture`-sized picture whose place on the screen is `fitted` pixels (`outputSize`); nil when there is
    /// none and AVPlayer shows the picture itself. It is plugged in, so no power rule: the lift when the plan asks and the picture is
    /// SDR, the upscale when the plan asks and the screen is larger.
    static func appleTVWork(liftAsked: Bool, sourceHDR: Bool, upscaleAsked: Bool, picture: (Int, Int), fitted: (Int, Int)) -> Work? {
        let hdr = liftAsked && !sourceHDR
        let larger = upscaleAsked && fitted.0 > picture.0 && fitted.1 > picture.1
        guard hdr || larger else { return nil }
        return Work(hdr: hdr, size: larger ? fitted : nil)
    }

    /// What the panel says when the plan asked but nothing was worth doing here (AVPlayer shows the picture); the chip leaves it
    /// out. Flutter's `lambentDeviceNotNeeded` is the same text.
    static let notNeeded = "Not needed"

    /// What the player's chip and panel call the work on this device: "Auto HDR", "AI upscale", "Auto HDR · Shader upscale"; nil
    /// for none.
    static func label(hdr: Bool, scaler: LambentLiftProcessor.Scaler?) -> String? {
        let parts = [hdr ? "Auto HDR" : nil, scaler.flatMap { label($0) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The scalers this device tries, best first (`LambentLiftProcessor.ladder`). The same rule on the Apple TV and the iPad, by the
    /// GPU's Apple family:
    /// - the AI upscaler (NVIDIA's VSR low network on the Neural Engine) from family 8 (A15, A16, M2): 15-17 ms a 1080p picture on an
    ///   A16, so up to 30 fps there; its Neural Engine student (13 ms with the lift on an A16) for 50 / 60 fps titles. Before an A19
    ///   (family 10) the full network steps aside above 30 fps (`LambentLiftProcessor.scale`);
    /// - FSRCNNX from family 10 (A19, M5): 29 ms a picture on an A16, too slow before it;
    /// - RAVU-lite, then Catmull-Rom, then none (the system scales), everywhere.
    /// The AI upscaler steps aside for a title shown at less than `neuralMinimumScale` (`LambentLiftProcessor.scale`).
    /// `neuralModels(student)`: the network's models are in the bundle (`LambentNeuralScaler.available`).
    static func ladder(supports: (MTLGPUFamily) -> Bool, neuralModels: (Bool) -> Bool) -> [LambentLiftProcessor.Scaler] {
        var ladder: [LambentLiftProcessor.Scaler] = []
        if supports(.apple8), neuralModels(false) { ladder.append(.neural(fast: false)) }
        if supports(.apple8), neuralModels(true) { ladder.append(.neural(fast: true)) }
        if supports(.apple10) { ladder.append(.prescaler("FSRCNNX_x2_8-0-4-1")) }
        return ladder + [.prescaler("ravu-lite-ar-r3"), .catmullRom, .none]
    }

    /// What this device can run by itself (docs/ENTITLEMENTS.md 8.4 in Lambent), for the purchase screen: `ai` the AI upscaler, `shader` a
    /// shader upscaler (the fallbacks ship with the app), `hdr` the lift, on this screen. A TV's own HDR mode decides there.
    @MainActor
    static func capabilities() -> [String: Bool] {
        guard let device = MTLCreateSystemDefaultDevice() else { return ["ai": false, "shader": false, "hdr": false] }
        let steps = ladder(supports: { device.supportsFamily($0) }, neuralModels: { LambentNeuralScaler.available(student: $0) })
        #if os(tvOS)
            let headroom = liftHeadroom
        #elseif os(macOS)
            let headroom = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
        #else
            let headroom = UIScreen.main.potentialEDRHeadroom
        #endif
        return [
            "ai": steps.contains { $0.isNeural },
            "shader": LambentPrescaler.bundleDirectory != nil,
            "hdr": headroom >= liftHeadroom,
        ]
    }

    /// The least scale at which the AI upscaler runs. The network always doubles the picture and the last pass scales that to the
    /// screen, so at a small scale most of what it adds is scaled away while its Neural Engine time stays (an M2 iPad: 11 ms a picture
    /// for a 1080p title full screen, 1.24x). Below it Catmull-Rom (0.4 ms) takes the picture, as the prescalers' own conditions
    /// already have them (FSRCNNX from 1.3x, RAVU-lite from 1.41x). 720p and 1080p titles reach 2x on a 4K TV and 1.86x on an iPad.
    static let neuralMinimumScale = 1.4

    /// The AI upscaler is worth its time for a `picture`-sized picture shown at `output` pixels.
    static func neuralPays(picture: (Int, Int), output: (Int, Int)) -> Bool {
        let k = min(Double(output.0) / Double(max(picture.0, 1)), Double(output.1) / Double(max(picture.1, 1)))
        return k >= neuralMinimumScale
    }

    /// Where a `picture`-sized picture is shown in a `bounds`-point view at `scale` pixels a point, fit inside it, in pixels, and no
    /// taller than the plan's `maxHeight` lines (never smaller than the picture: then it is not upscaled).
    static func outputSize(picture: (Int, Int), bounds: CGSize, scale: CGFloat, maxHeight: Int?) -> (Int, Int) {
        let (w, h) = (CGFloat(max(picture.0, 1)), CGFloat(max(picture.1, 1)))
        var k = min(bounds.width * scale / w, bounds.height * scale / h)
        if let maxHeight { k = min(k, CGFloat(maxHeight) / h) }
        k = max(k, 1)
        return (Int(w * k), Int(h * k))
    }

    /// What the player's chip and panel call the scaler: nil for none.
    static func label(_ scaler: LambentLiftProcessor.Scaler) -> String? {
        switch scaler {
        case .neural: return "AI upscale"
        case .prescaler, .catmullRom: return "Shader upscale"
        case .none: return nil
        }
    }
}

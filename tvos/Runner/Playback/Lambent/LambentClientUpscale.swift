import CoreGraphics
import Foundation
import Metal

/// Lambent Enhance's upscale on the device (docs/MONETIZATION.md 5.1 in Lambent): a step of Lambent Server's plan, not a setting.
///
/// The plan says where each step runs ("PC: RTX HDR, 1080p out; client: upscale to 4K"). The client's step travels in the plan's
/// enhanced stream URL as `cup=<lines>`: upscale here, to at most that many lines. The query is the plan's own (the server signs it,
/// docs/ENTITLEMENTS.md 6.1), so without Lambent Enhance or a trial the plan has no `cup` and nothing is upscaled on the device. A
/// direct play has no plan step at all. The client keeps no paywall of its own.
///
/// On the iPad (`LambentHDRLift` on iOS) the step only upscales: the picture keeps the colours the PC sent, SDR or HDR10, and the
/// Apple TV's own HDR lift stays an Apple TV setting.
enum LambentClientUpscale {
    /// The query member that carries the client's step.
    static let planKey = "cup"

    /// The plan's client step for the stream at `url`: the most lines this device may upscale to; nil when the plan does not ask (no
    /// `cup`, a `cup` that is not a positive number, or a stream that is not Lambent's enhanced one).
    static func planHeight(_ url: URL?) -> Int? {
        guard let url, url.path.contains("/v1/enhanced/"),
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let value = items.last(where: { $0.name.lowercased() == planKey })?.value,
            let lines = Int(value.trimmingCharacters(in: .whitespaces)), lines > 0
        else { return nil }
        return lines
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

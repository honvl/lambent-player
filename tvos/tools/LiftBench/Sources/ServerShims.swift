import CoreVideo
import Foundation

// Stand-ins for the little of the Mac server's Log.swift and Bench.swift that its network code (Server/, copied by
// copy_server_networks.sh) uses, so it builds for tvOS unchanged.

struct EnhanceError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The server's log lines go to the bench's output.
func logf(_ message: String) {
    if message.contains("U-Net does not run") { ServerBench.unetFailed = true }
    BenchLog.line("server: \(message)")
}

func fmt(_ value: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", value) }

/// What the Mac's bench times (Bench.swift); NeuralScaler conforms to it there.
protocol BenchScaler: AnyObject, CustomStringConvertible {
    func scale(_ picture: CVPixelBuffer) throws -> CVPixelBuffer
    func drain()
    func takeBoth() -> (gpu: Double, wall: Double)
}

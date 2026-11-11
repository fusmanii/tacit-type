import Observation
import TacitKit

/// Owns discovery, pairing and the connection to the iPhone app. Networking lands in M1.
@MainActor
@Observable
final class DeviceManager {
    enum ConnectionState: Equatable {
        case notPaired
        case searching(deviceName: String)
        case connected(deviceName: String)
    }

    private(set) var connectionState: ConnectionState = .notPaired

    var statusLine: String {
        switch connectionState {
        case .notPaired: "No iPhone paired"
        case let .searching(name): "\(name) · Open Tacit Type on your iPhone"
        case let .connected(name): "● \(name) connected"
        }
    }
}

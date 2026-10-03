import Foundation

enum LinkState: Equatable {
    case off
    case searching
    case connecting
    case connected
    case unavailable(String)

    var label: String {
        switch self {
        case .off: "Off"
        case .searching: "Looking for Dug…"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .unavailable(let why): why
        }
    }
}

/// Moves protocol bytes between the app and a collar. `Collar` speaks the protocol;
/// transports just carry it (real BLE, or a simulated collar living inside the app).
///
/// Transports call their delegate on the main thread.
protocol CollarTransport: AnyObject {
    var delegate: CollarTransportDelegate? { get set }
    /// Largest payload for a single `sendData` call.
    var maxDataChunk: Int { get }
    /// False when the link's outgoing queue is full; wait for `transportReadyToSend`.
    var canSendData: Bool { get }

    func start()
    func stop()
    func sendControl(_ data: Data)
    func sendData(_ data: Data)
}

@MainActor
protocol CollarTransportDelegate: AnyObject {
    func transport(didChange state: LinkState)
    func transport(didReceive status: Data)
    func transportReadyToSend()
}

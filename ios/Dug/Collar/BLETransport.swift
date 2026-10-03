import CoreBluetooth
import Foundation

/// Talks to the real collar over Bluetooth LE. Auto-reconnects when the collar wanders off.
final class BLETransport: NSObject, CollarTransport {
    weak var delegate: CollarTransportDelegate?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var controlChr: CBCharacteristic?
    private var dataChr: CBCharacteristic?
    private var statusChr: CBCharacteristic?
    private var wantsRunning = false

    var maxDataChunk: Int {
        min(peripheral?.maximumWriteValueLength(for: .withoutResponse) ?? 20, 244)
    }

    var canSendData: Bool {
        guard let peripheral, dataChr != nil else { return false }
        return peripheral.canSendWriteWithoutResponse
    }

    func start() {
        wantsRunning = true
        if let central {
            connectOrScan(central)
        } else {
            // Callbacks arrive on the main queue.
            central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    func stop() {
        wantsRunning = false
        guard let central else { return }
        central.stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        forgetPeripheral()
        report(.off)
    }

    func sendControl(_ data: Data) {
        guard let peripheral, let controlChr else { return }
        peripheral.writeValue(data, for: controlChr, type: .withResponse)
    }

    func sendData(_ data: Data) {
        guard let peripheral, let dataChr else { return }
        peripheral.writeValue(data, for: dataChr, type: .withoutResponse)
    }

    // MARK: - Private

    private func connectOrScan(_ central: CBCentralManager) {
        guard wantsRunning, central.state == .poweredOn else { return }
        // Already connected at the system level (e.g. by the app before a mode switch)?
        if let known = central.retrieveConnectedPeripherals(withServices: [DugProtocol.serviceUUID]).first {
            connect(known)
            return
        }
        report(.searching)
        central.scanForPeripherals(withServices: [DugProtocol.serviceUUID])
    }

    private func connect(_ p: CBPeripheral) {
        guard let central else { return }
        central.stopScan()
        peripheral = p
        p.delegate = self
        report(.connecting)
        // Pending connections never time out, so this also works as "reconnect when back in range".
        central.connect(p)
    }

    private func forgetPeripheral() {
        peripheral = nil
        controlChr = nil
        dataChr = nil
        statusChr = nil
    }

    private func report(_ state: LinkState) {
        MainActor.assumeIsolated { delegate?.transport(didChange: state) }
    }
}

extension BLETransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: connectOrScan(central)
        case .poweredOff: report(.unavailable("Bluetooth is off"))
        case .unauthorized: report(.unavailable("Bluetooth permission needed (Settings → Dug)"))
        case .unsupported: report(.unavailable("This device has no Bluetooth LE"))
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        connect(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([DugProtocol.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        forgetPeripheral()
        connectOrScan(central)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        controlChr = nil
        dataChr = nil
        statusChr = nil
        guard wantsRunning else { return }
        connect(p)
    }
}

extension BLETransport: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = p.services?.first(where: { $0.uuid == DugProtocol.serviceUUID }) else { return }
        p.discoverCharacteristics([DugProtocol.controlUUID, DugProtocol.dataUUID, DugProtocol.statusUUID],
                                  for: service)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for chr in service.characteristics ?? [] {
            switch chr.uuid {
            case DugProtocol.controlUUID: controlChr = chr
            case DugProtocol.dataUUID: dataChr = chr
            case DugProtocol.statusUUID: statusChr = chr
            default: break
            }
        }
        if let statusChr { p.setNotifyValue(true, for: statusChr) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor chr: CBCharacteristic, error: Error?) {
        if chr.uuid == DugProtocol.statusUUID, chr.isNotifying, controlChr != nil, dataChr != nil {
            report(.connected)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor chr: CBCharacteristic, error: Error?) {
        guard chr.uuid == DugProtocol.statusUUID, let value = chr.value else { return }
        MainActor.assumeIsolated { delegate?.transport(didReceive: value) }
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        MainActor.assumeIsolated { delegate?.transportReadyToSend() }
    }
}

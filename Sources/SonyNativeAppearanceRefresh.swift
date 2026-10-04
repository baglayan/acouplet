#if !ACOUPLET_PUBLIC_APIS_ONLY
import CoreBluetooth
import Foundation

@MainActor
final class SonyNativeAppearanceRefresh: NSObject, @preconcurrency CBCentralManagerDelegate {
    enum Match: Equatable {
        case canonical
        case related
        case conflictingHash
    }

    private var manager: CBCentralManager?
    private var timeout: Task<Void, Never>?
    private var identity: SonyBLEIdentity.VerifiedDevice?
    private var attemptedIdentifiers: Set<UUID> = []
    private var observations: [UUID: String] = [:]
    private var state = "Not requested"
    private var startedAt: Date?

    var diagnosticDescription: String {
        let target = identity.map { "\($0.classicAddress), canonical UUID \($0.peripheralIdentifier!.uuidString)" } ?? "No verified target"
        let started = startedAt.map { "; started \($0.ISO8601Format())" } ?? ""
        let seen = observations.keys.sorted { $0.uuidString < $1.uuidString }.map { "\($0.uuidString): \(observations[$0]!)" }
        return "\(state); \(target)\(started); \(seen.isEmpty ? "No matching advertisement observed" : seen.joined(separator: "; ")); native artwork not verified"
    }

    func start(identity: SonyBLEIdentity.VerifiedDevice, canonicalIdentifier: UUID) {
        guard manager == nil, identity.model == .wfXM5,
              identity.peripheralIdentifier == canonicalIdentifier,
              !attemptedIdentifiers.contains(canonicalIdentifier) else { return }
        guard CBManager.authorization == .allowedAlways else {
            state = "Skipped: existing Bluetooth permission is unavailable"
            return
        }
        attemptedIdentifiers.insert(canonicalIdentifier)
        self.identity = identity
        observations.removeAll()
        startedAt = Date()
        state = "Waiting for Bluetooth; scan limited to 8 seconds"
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.finish("Completed bounded discovery")
        }
        manager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func stop() {
        guard manager != nil else { return }
        finish("Stopped with control session")
    }

    private func finish(_ message: String) {
        timeout?.cancel()
        timeout = nil
        if manager?.isScanning == true { manager?.stopScan() }
        manager?.delegate = nil
        manager = nil
        state = message
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === manager else { return }
        switch central.state {
        case .poweredOn:
            guard !central.isScanning else { return }
            state = "Scanning genuine advertisements for up to 8 seconds"
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        case .poweredOff:
            finish("Stopped: Bluetooth is off")
        case .unauthorized:
            finish("Stopped: Bluetooth permission is unavailable")
        case .unsupported:
            finish("Stopped: Bluetooth LE is unavailable")
        case .resetting:
            finish("Stopped: Bluetooth is resetting")
        case .unknown:
            break
        @unknown default:
            finish("Stopped: Bluetooth state is unavailable")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === manager, let identity,
              let match = Self.match(peripheralIdentifier: peripheral.identifier,
                                     manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
                                     identity: identity) else { return }
        if match == .conflictingHash {
            observations[peripheral.identifier] = "Canonical UUID reported a different Sony hash"
            finish("Stopped: advertisement identity conflict")
            return
        }
        let association = match == .canonical ? "Canonical UUID observed" : "Matching Sony hash on a different UUID; native row association unproved"
        if let appearance = Self.appearance(advertisementData["kCBAdvDataAppearance"]) {
            observations[peripheral.identifier] = "\(association); advertised appearance \(String(format: "0x%04X", appearance))"
        } else if observations[peripheral.identifier] == nil {
            observations[peripheral.identifier] = "\(association); appearance not exposed in callback"
        }
    }

    nonisolated static func match(peripheralIdentifier: UUID, manufacturerData: Data?,
                                 identity: SonyBLEIdentity.VerifiedDevice) -> Match? {
        guard identity.model == .wfXM5, let canonicalIdentifier = identity.peripheralIdentifier else { return nil }
        let advertisement = manufacturerData.flatMap(SonyBLEIdentity.advertisement)
        if peripheralIdentifier == canonicalIdentifier {
            return advertisement.map { $0.hash == identity.hash ? .canonical : .conflictingHash } ?? .canonical
        }
        return advertisement?.hash == identity.hash ? .related : nil
    }

    nonisolated static func appearance(_ value: Any?) -> UInt16? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value <= Double(UInt16.max), value.rounded() == value else { return nil }
        return UInt16(value)
    }
}
#endif

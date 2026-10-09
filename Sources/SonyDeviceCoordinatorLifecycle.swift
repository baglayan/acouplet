import CoreBluetooth
import Foundation
@preconcurrency import IOBluetooth

extension SonyDeviceCoordinator {
    func start() {
        guard !isRunning else { return }
        isRunning = true
        isSystemSleeping = false
        reportBluetoothAuthorization(CBManager.authorization)
        bluetoothAuthorizationManager = CBCentralManager(delegate: self, queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func stop() {
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        nativeBatteryPublisher?.stop()
        #endif
        isRunning = false
        bluetoothAuthorizationManager?.delegate = nil
        bluetoothAuthorizationManager = nil
        discoveryGeneration += 1
        isDiscovering = false
        discoveryTimer?.invalidate()
        discoveryTimer = nil
        for controller in controllers { controller.stop() }
    }

    func setReconnectAutomatically(_ enabled: Bool, suppressing address: String? = nil) {
        let previousEnabled = reconnectAutomatically
        let previousAddress = reconnectSuppressedAddress
        reconnectAutomatically = enabled
        reconnectSuppressedAddress = address
        if let address, let controller = controller(for: address), previousEnabled && previousAddress != address {
            controller.setReconnectAutomatically(false)
        }
        for controller in controllers where controller.address != address
            && (previousEnabled && controller.address != previousAddress) != enabled {
            controller.setReconnectAutomatically(enabled)
        }
    }

    func systemWillSleep() {
        guard !isSystemSleeping else { return }
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        nativeBatteryPublisher?.revoke()
        #endif
        isSystemSleeping = true
        discoveryGeneration += 1
        isDiscovering = false
        discoveryTimer?.invalidate()
        discoveryTimer = nil
        for controller in controllers { controller.systemWillSleep() }
    }

    func systemDidWake() {
        guard isSystemSleeping, isRunning else { return }
        isSystemSleeping = false
        for controller in controllers where !retiredControllerAddresses.contains(controller.address) {
            controller.systemDidWake()
        }
        refreshDiscovery()
    }

    func refreshDiscovery() {
        guard isRunning, !isSystemSleeping, !isDiscovering else { return }
        let authorization = CBManager.authorization
        reportBluetoothAuthorization(authorization)
        guard authorization == .allowedAlways else { return }
        isDiscovering = true
        discoveryGeneration += 1
        let generation = discoveryGeneration
        SonyHeadphonesController.initializeBluetooth(authorization: { CBManager.authorization },
            initialize: { _ = IOBluetoothDevice.pairedDevices() }) { [weak self] authorization in
                guard let self, self.isRunning, !self.isSystemSleeping,
                      self.discoveryGeneration == generation else { return }
                self.isDiscovering = false
                self.reportBluetoothAuthorization(authorization)
                guard authorization == .allowedAlways else { return }
                self.refreshPairedInventory()
                self.discoveryTimer?.invalidate()
                self.discoveryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.refreshPairedInventory() }
                }
            }
    }

    func reconcileDiscoveredDevices(_ paired: [SonyConnectedDevice], connectedAddresses: Set<String>,
                                    pairedDeviceInventory: [IOBluetoothDevice]? = nil) {
        guard isRunning, !isSystemSleeping else { return }
        var devices = paired
        var connected = connectedAddresses
        for controller in controllers where controller.hasOpenControlTransport || (controller.usesBluetoothLE && controller.isDeviceConnected) {
            connected.insert(controller.address)
            if !devices.contains(where: { $0.address == controller.address }),
               let retained = retainedDevices.first(where: { $0.address == controller.address }) {
                devices.append(retained)
            }
        }
        let previousControllers = Set(controllers.map(ObjectIdentifier.init))
        reconcilePairedDevices(devices, connectedAddresses: connected)
        let pairedAddresses = Set(devices.map(\.address))
        for controller in controllers {
            controller.pairedDeviceInventory = pairedDeviceInventory
            if pairedAddresses.contains(controller.address) || controller.needsDeviceContext {
                retiredControllerAddresses.remove(controller.address)
                if !previousControllers.contains(ObjectIdentifier(controller)) {
                    controller.setReconnectAutomatically(reconnectAutomatically && controller.address != reconnectSuppressedAddress)
                }
                controller.systemDidWake()
                controller.start()
            } else if retiredControllerAddresses.insert(controller.address).inserted {
                controller.stop()
            }
        }
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        reconcileNativeBatteries()
        #endif
    }

    func refreshPairedInventory(authorization: CBManagerAuthorization = CBManager.authorization) {
        guard isRunning, !isSystemSleeping else { return }
        guard authorization == .allowedAlways else {
            reportBluetoothAuthorization(authorization)
            return
        }
        let saved = SonyBLEIdentity.savedDevices(in: .standard)
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        var connected: Set<String> = []
        let devices = paired.compactMap { device -> SonyConnectedDevice? in
            guard let address = device.addressString.flatMap(SonyBLEIdentity.normalizedAddress) else { return nil }
            var model = SonyDeviceModel(name: device.name ?? "")
            #if ACOUPLET_PUBLIC_APIS_ONLY
            let peripheralIdentifier: UUID? = nil
            #else
            let peripheralIdentifier = model == .unknown && saved[address] != nil
                ? SonyBLEIdentity.classicPeripheralIdentifier(for: device) : nil
            #endif
            if model == .unknown, let identity = saved[address],
               identity.matches(classicAddress: address, model: identity.model,
                                peripheralIdentifier: peripheralIdentifier, isPaired: device.isPaired()) {
                model = identity.model
            }
            guard let descriptor = SonyConnectedDevice(address: address, name: device.name ?? model.name, model: model) else { return nil }
            if device.isClassicConnected() { connected.insert(address) }
            return descriptor
        }
        reconcileDiscoveredDevices(devices, connectedAddresses: connected, pairedDeviceInventory: paired)
    }
}

extension SonyDeviceCoordinator: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === bluetoothAuthorizationManager, isRunning, !isSystemSleeping else { return }
        if reportBluetoothAuthorization(CBManager.authorization) { refreshDiscovery() }
    }
}

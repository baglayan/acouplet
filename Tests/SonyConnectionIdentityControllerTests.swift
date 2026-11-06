import XCTest
@testable import Acouplet

final class SonyConnectionIdentityControllerTests: XCTestCase {
    private let host = "10:20:30:40:50:60"
    private let classic = "AA:BB:CC:DD:EE:01"
    private let left = "AA:BB:CC:DD:EE:02"
    private let right = "AA:BB:CC:DD:EE:03"

    @MainActor
    func testAppearanceSurvivesControlLossHandshakeAndRelaunchWithoutRestoringControlState() throws {
        let suite = "dev.baglayan.Acouplet.appearance-controller-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true, identityDefaults: defaults,
            pinnedAddress: classic, advertisedName: "WH-1000XM3")
        defer { controller.simulateControlLoss() }
        beginAppearanceDiscovery(controller, address: classic)
        reportAppearanceModel("WH-1000XM3", to: controller)
        controller.simulateProtocolMessage([0x05, 3, 0x30, 3])
        XCTAssertEqual(controller.displayColor?.rawValue, 3)
        XCTAssertNil(controller.bluetoothLEHash)
        XCTAssertNil(controller.simulatedSavedIdentity)
        let session = controller.simulatedControlSession
        controller.simulateSameTransportHandshake()
        XCTAssertEqual(controller.displayColor?.rawValue, 3)
        XCTAssertNil(controller.deviceInformation.color)
        XCTAssertNil(controller.deviceInformation.model)
        XCTAssertFalse(controller.isReady)
        XCTAssertNil(controller.protocolInformation)
        controller.simulateProtocolMessage([0x05, 3, 0x30, 1], session: session)
        XCTAssertEqual(controller.displayColor?.rawValue, 3)
        controller.simulateControlLoss()
        XCTAssertEqual(controller.displayColor?.rawValue, 3)
        let restored = SonyHeadphonesController(startAutomatically: false, identityDefaults: defaults,
            pinnedAddress: classic, advertisedName: "WH-1000XM3", displayOnly: true)
        XCTAssertEqual(restored.displayColor?.rawValue, 3)
        XCTAssertNil(restored.deviceInformation.color)
        XCTAssertNil(restored.deviceInformation.model)
        XCTAssertNil(restored.protocolInformation)
        XCTAssertTrue(restored.supportedFunctions.isEmpty)
        XCTAssertFalse(restored.isReady)
    }

    @MainActor
    func testAppearanceNeverCrossesAddressesOrContradictedModels() throws {
        let suite = "dev.baglayan.Acouplet.appearance-controller-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true, identityDefaults: defaults)
        defer { controller.simulateControlLoss() }
        beginAppearanceDiscovery(controller, address: classic)
        reportAppearanceModel("WH-1000XM3", to: controller)
        controller.simulateProtocolMessage([0x05, 3, 0x30, 3])
        beginAppearanceDiscovery(controller, address: left)
        XCTAssertNil(controller.displayColor)
        reportAppearanceModel("WH-1000XM3", to: controller)
        controller.simulateProtocolMessage([0x05, 3, 0x30, 1])
        beginAppearanceDiscovery(controller, address: classic)
        XCTAssertEqual(controller.displayColor?.rawValue, 3)
        reportAppearanceModel("WH-1000XM4", to: controller)
        XCTAssertNil(controller.displayColor)
        controller.simulateControlLoss()
        XCTAssertEqual(controller.deviceModel, .whXM3)
        XCTAssertNil(controller.displayColor)
        XCTAssertNil(SonyBLEIdentity.savedAppearances(in: defaults)[classic])
        XCTAssertEqual(SonyBLEIdentity.savedAppearances(in: defaults)[left]?.color.rawValue, 1)
        let differentModel = SonyHeadphonesController(startAutomatically: false, identityDefaults: defaults,
            pinnedAddress: left, advertisedName: "WH-1000XM4", displayOnly: true)
        XCTAssertNil(differentModel.displayColor)
    }

    @MainActor
    func testColorBeforeModelWaitsForFreshIdentityAndPreservesUnknownAndDefaultValues() throws {
        let suite = "dev.baglayan.Acouplet.appearance-controller-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true, identityDefaults: defaults)
        defer { controller.simulateControlLoss() }
        for color: UInt8 in [0xFE, 0] {
            beginAppearanceDiscovery(controller, address: classic)
            let previous = SonyBLEIdentity.savedAppearances(in: defaults)[classic]
            controller.simulateProtocolMessage([0x05, 3, 0x30, color])
            XCTAssertEqual(controller.displayColor?.rawValue, color)
            XCTAssertEqual(SonyBLEIdentity.savedAppearances(in: defaults)[classic], previous)
            reportAppearanceModel("WH-1000XM3", to: controller)
            XCTAssertEqual(SonyBLEIdentity.savedAppearances(in: defaults)[classic]?.color.rawValue, color)
            controller.simulateControlLoss()
            XCTAssertEqual(controller.displayColor?.rawValue, color)
            let restored = SonyHeadphonesController(startAutomatically: false, identityDefaults: defaults,
                pinnedAddress: classic, advertisedName: "WH-1000XM3", displayOnly: true)
            XCTAssertEqual(restored.displayColor?.rawValue, color)
        }
        beginAppearanceDiscovery(controller, address: classic)
        reportAppearanceModel("Unrecognized model", to: controller)
        controller.simulateControlLoss()
        XCTAssertNil(controller.displayColor)
        XCTAssertNil(SonyBLEIdentity.savedAppearances(in: defaults)[classic])
    }

    @MainActor
    func testUnsolicitedMalformedWrongTableAndDuplicateRepliesCannotReplaceRememberedColor() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WH-1000XM3", controlBusy: true, simulatedAddress: classic)
        reportAppearanceModel("WH-1000XM3", to: controller)
        controller.simulateProtocolMessage([0x05, 3, 0x30, 3])
        XCTAssertNil(controller.displayColor)
        beginAppearanceDiscovery(controller, address: classic)
        reportAppearanceModel("WH-1000XM3", to: controller)
        controller.simulateProtocolMessage([0x05, 3, 0x30])
        controller.simulateProtocolMessage([0x05, 3, 0x30, 3], type: 0x0E)
        XCTAssertNil(controller.displayColor)
        controller.simulateProtocolMessage([0x05, 3, 0x30, 3])
        controller.simulateProtocolMessage([0x05, 3, 0x30, 1])
        XCTAssertEqual(controller.displayColor?.rawValue, 3)
        controller.simulateControlLoss()
        controller.simulateProtocolMessage([0x05, 3, 0x30, 1])
        XCTAssertEqual(controller.displayColor?.rawValue, 3)
        XCTAssertNil(controller.deviceInformation.color)
    }

    @MainActor
    func testAppearanceUsesRecognizedRegionalModelWhenReportedNameIsASeries() throws {
        let suite = "dev.baglayan.Acouplet.appearance-controller-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for (model, reportedName): (SonyDeviceModel, String) in [(.whCH535, "WH-CH530 series"), (.whCH735N, "WH-CH730N series")] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true, identityDefaults: defaults,
                pinnedAddress: classic, advertisedName: model.name)
            defer { controller.simulateControlLoss() }
            controller.simulateDeviceConnection(named: model.name, controlBusy: true)
            controller.simulateProtocolMessage([1, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
            acknowledgeAll(controller)
            reportAppearanceModel(reportedName, to: controller)
            controller.simulateProtocolMessage([0x05, 3, 0x30, 5])
            XCTAssertEqual(SonyBLEIdentity.savedAppearances(in: defaults)[classic]?.model, model)
            controller.simulateControlLoss()
            XCTAssertEqual(controller.displayColor?.rawValue, 5)
            let restored = SonyHeadphonesController(startAutomatically: false, identityDefaults: defaults,
                pinnedAddress: classic, advertisedName: model.name, displayOnly: true)
            XCTAssertEqual(restored.displayColor?.rawValue, 5)
        }
    }

    @MainActor
    func testAdvertisedIdentityReadsUnionAliasesWithoutBlockingReadiness() {
        let controller = connectedController(functions: [0x19, 0x40, 0x41], functions2: [0x64])
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.isReady)
        XCTAssertTrue(controller.simulatedControlAddresses.isEmpty)
        let queries = controller.simulatedTransmittedFrames.filter { $0.type == 0x0C && [[0x10, 7], [0x40, 0], [0x40, 1]].contains($0.payload) }
        XCTAssertEqual(queries.map(\.payload), [[0x10, 7], [0x40, 0], [0x40, 1]])
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == [0x60, 4] })
        controller.simulateProtocolMessage([0x11, 7] + bytes(host, classic))
        XCTAssertEqual(controller.simulatedControlAddresses, [classic])
        controller.simulateProtocolMessage([0x41, 1] + bytes(classic, left))
        controller.simulateProtocolMessage([0x41, 0] + bytes(classic, left, right))
        let speaker = "AA:BB:CC:DD:EE:04"
        controller.simulateProtocolMessage([0x61, 4] + bytes(speaker, left), type: 0x0E)
        XCTAssertEqual(controller.simulatedControlAddresses, [classic, left, right, speaker])
        XCTAssertFalse(controller.simulatedControlAddresses.contains(host))
        XCTAssertTrue(controller.isReady)
    }

    @MainActor
    func testUnsolicitedWrongTableMalformedAndRepeatedRepliesCannotAdmitAddresses() {
        let controller = connectedController(functions: [0x19, 0x41], functions2: [])
        defer { controller.simulateControlLoss() }
        let reply: [UInt8] = [0x41, 1] + bytes(classic, left)
        controller.simulateProtocolMessage(reply, type: 0x0E)
        controller.simulateProtocolMessage([0x41, 0] + bytes(classic, left, right))
        controller.simulateProtocolMessage([0x61, 4] + bytes(classic, left), type: 0x0E)
        var malformed: [UInt8] = [0x11, 7] + bytes(host, classic)
        malformed[2] = 0x47
        controller.simulateProtocolMessage(malformed)
        XCTAssertTrue(controller.simulatedControlAddresses.isEmpty)
        controller.simulateProtocolMessage(reply)
        XCTAssertEqual(controller.simulatedControlAddresses, [classic, left])
        controller.simulateProtocolMessage([0x41, 1] + bytes(host, right))
        XCTAssertEqual(controller.simulatedControlAddresses, [classic, left])
        controller.simulateControlLoss()
        controller.simulateProtocolMessage(reply)
        XCTAssertTrue(controller.simulatedControlAddresses.isEmpty)
    }

    @MainActor
    func testQueuedIdentityReadDoesNotOwnReplyUntilTransmissionCompletes() {
        let controller = beginController()
        defer { controller.simulateControlLoss() }
        controller.defersSimulatedWrites = true
        controller.simulateProtocolMessage(capabilities([0x41]))
        let reply: [UInt8] = [0x41, 1] + bytes(classic, left)
        controller.simulateProtocolMessage(reply)
        XCTAssertTrue(controller.simulatedControlAddresses.isEmpty)
        controller.completeSimulatedWrite()
        controller.completeSimulatedWrite()
        controller.defersSimulatedWrites = false
        controller.simulateProtocolMessage(reply)
        XCTAssertEqual(controller.simulatedControlAddresses, [classic, left])
    }

    @MainActor
    func testTable2IdentityReadIsRetryableOnlyWhenAdvertised() {
        let frame = SonyFrame(type: 0x0E, sequence: 0, payload: [0x60, 4])
        let controller = connectedController(functions: [], functions2: [0x64])
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.canRetryRead(frame))
        XCTAssertNotNil(controller.simulatedDiscoveryReadTimeoutID(frame.payload, type: frame.type))
        let unsupported = connectedController(functions: [0x64], functions2: [])
        defer { unsupported.simulateControlLoss() }
        XCTAssertFalse(unsupported.canRetryRead(frame))
        XCTAssertFalse(unsupported.simulatedTransmittedFrames.contains { $0.type == frame.type && $0.payload == frame.payload })
    }

    @MainActor
    func testNewHandshakeClearsAliasesAndRetiredSessionCannotSupplyIdentity() {
        let controller = connectedController(functions: [0x41], functions2: [])
        defer { controller.simulateControlLoss() }
        let reply: [UInt8] = [0x41, 1] + bytes(classic, left)
        controller.simulateProtocolMessage(reply)
        let name = Array("WH-1000XM5".utf8)
        controller.simulateProtocolMessage([0x05, 1, UInt8(name.count)] + name)
        controller.simulateProtocolMessage([0x05, 3, 0x30, 0])
        let session = controller.simulatedControlSession
        XCTAssertEqual(controller.simulatedControlAddresses, [classic, left])
        controller.simulateSameTransportHandshake()
        XCTAssertEqual(controller.linkState, .handshaking)
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
        XCTAssertTrue(controller.simulatedControlAddresses.isEmpty)
        controller.simulateProtocolMessage([1, 0, 3, 0, 0x30, 0x18, 0, 0])
        acknowledgeAll(controller)
        controller.simulateProtocolMessage(capabilities([0x41]))
        acknowledgeAll(controller)
        controller.simulateProtocolMessage(reply, session: session)
        XCTAssertTrue(controller.simulatedControlAddresses.isEmpty)
        controller.simulateProtocolMessage(reply)
        XCTAssertEqual(controller.simulatedControlAddresses, [classic, left])
    }

    @MainActor
    private func beginAppearanceDiscovery(_ controller: SonyHeadphonesController, address: String) {
        controller.simulateDeviceConnection(named: "WH-1000XM3", controlBusy: true, simulatedAddress: address)
        controller.simulateProtocolMessage([1, 0, 2, 0x10], beginConnection: true)
        acknowledgeAll(controller)
    }

    @MainActor
    private func reportAppearanceModel(_ model: String, to controller: SonyHeadphonesController) {
        let name = Array(model.utf8)
        controller.simulateProtocolMessage([0x05, 1, UInt8(name.count)] + name)
    }

    @MainActor
    private func beginController() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WH-1000XM5", controlBusy: true)
        controller.simulateProtocolMessage([1, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
        acknowledgeAll(controller)
        return controller
    }

    @MainActor
    private func connectedController(functions: [UInt8], functions2: [UInt8]) -> SonyHeadphonesController {
        let controller = beginController()
        controller.simulateProtocolMessage(capabilities(functions))
        acknowledgeAll(controller)
        controller.simulateProtocolMessage(capabilities(functions2), type: 0x0E)
        acknowledgeAll(controller)
        return controller
    }

    private func capabilities(_ functions: [UInt8]) -> [UInt8] {
        [7, 0, UInt8(functions.count)] + functions.flatMap { [$0, 1] }
    }

    private func bytes(_ addresses: String...) -> [UInt8] { Array(addresses.joined().utf8) }

    @MainActor
    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        for _ in 0..<100 {
            guard let frame = controller.simulatedPendingFrame else { return }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("The command queue did not drain.")
    }
}

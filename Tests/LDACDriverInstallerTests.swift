import Combine
import XCTest
@testable import Acouplet

#if !ACOUPLET_PUBLIC_APIS_ONLY
@MainActor
final class LDACDriverInstallerTests: XCTestCase {
    func testInstallationDoesNotClaimLoadedDriverIsUpdated() {
        XCTAssertEqual(LDACDriverInstaller.state(required: 1, installed: nil, loaded: nil), .missing)
        XCTAssertEqual(LDACDriverInstaller.state(required: 1, installed: nil, loaded: 1), .missing)
        XCTAssertEqual(LDACDriverInstaller.state(required: 1, installed: 0, loaded: 0), .outdated)
        XCTAssertEqual(LDACDriverInstaller.state(required: 1, installed: 1, loaded: nil), .restartRequired)
        XCTAssertEqual(LDACDriverInstaller.state(required: 1, installed: 1, loaded: 0), .restartRequired)
        XCTAssertEqual(LDACDriverInstaller.state(required: 1, installed: 1, loaded: 1), .current)
    }

    func testCompatibleDriverDoesNotRequireReinstallationForAppUpdates() {
        XCTAssertEqual(LDACDriverInstaller.state(required: 1, installed: 2, loaded: 2), .current)
        XCTAssertEqual(LDACDriverInstaller.state(required: 2, installed: 1, loaded: 1), .outdated)
        XCTAssertEqual(LDACDriverInstaller.state(required: 2, installed: 2, loaded: 1), .restartRequired)
    }

    func testRefreshDistinguishesInstallationFromRestart() {
        var installed: Int? = 2
        var loaded: Int? = 2
        var inspections = 0
        let controller = LDACController(inspectDriver: { _ in
            inspections += 1
            return LDACDriverInstaller.state(required: 3, installed: installed, loaded: loaded)
        })
        var changes = 0
        let observation = controller.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        XCTAssertEqual(controller.driverState, .outdated)
        XCTAssertTrue(controller.canStartOrInstallDriver)
        XCTAssertEqual(inspections, 1)

        controller.refreshDriverState()
        XCTAssertEqual(inspections, 2)
        XCTAssertEqual(changes, 0)

        installed = 3
        controller.refreshDriverState()
        XCTAssertEqual(controller.driverState, .restartRequired)
        XCTAssertFalse(controller.canStartOrInstallDriver)
        XCTAssertEqual(inspections, 3)
        XCTAssertEqual(changes, 1)

        loaded = nil
        controller.refreshDriverState()
        XCTAssertEqual(controller.driverState, .restartRequired)
        XCTAssertFalse(controller.canStartOrInstallDriver)
        XCTAssertEqual(inspections, 4)
        XCTAssertEqual(changes, 1)

        loaded = 3
        controller.refreshDriverState()
        XCTAssertEqual(controller.driverState, .current)
        XCTAssertTrue(controller.canStartOrInstallDriver)
        XCTAssertEqual(inspections, 5)
        XCTAssertEqual(changes, 2)

        installed = nil
        controller.refreshDriverState()
        XCTAssertEqual(controller.driverState, .missing)
        XCTAssertTrue(controller.canStartOrInstallDriver)
        XCTAssertEqual(inspections, 6)
        XCTAssertEqual(changes, 3)
    }

    func testRefreshAfterCancelledInstallationStillRequiresUpdate() {
        let controller = LDACController(inspectDriver: { _ in
            LDACDriverInstaller.state(required: 3, installed: 2, loaded: 2)
        })
        controller.refreshDriverState()
        XCTAssertEqual(controller.driverState, .outdated)
        XCTAssertTrue(controller.canStartOrInstallDriver)
    }

    func testUntrustedBundleCannotOpenAnInstaller() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = directory.appendingPathComponent("Untrusted.app/Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "example.untrusted", "CFBundlePackageType": "APPL", "AcoupletDistribution": "development"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("untrusted package".utf8).write(to: resources.appendingPathComponent("Acouplet LDAC Output.pkg"))
        let bundle = try XCTUnwrap(Bundle(url: contents.deletingLastPathComponent()))
        if case .unavailable = LDACDriverInstaller.inspect(bundle: bundle) {} else { XCTFail("Unsigned app must fail validation") }
        do {
            try await LDACDriverInstaller.openInstaller(bundle: bundle)
            XCTFail("Unsigned app must not open Installer")
        } catch {
            XCTAssertEqual((error as NSError).domain, "LDACDriverInstaller")
        }
    }
}

@MainActor
final class LDACConnectionPreferenceTests: XCTestCase {
    func testFinderDefersOwnedRestorationUntilStopIsConfirmed() async throws {
        for phase in [EarbudFindingSession.Phase.connecting, .starting, .ringing, .stopping, .unconfirmed] {
            let (coordinator, headphones, finder, request) = try preparedFinder()
            let ldac = LDACController(devices: coordinator, inspectDriver: { _ in .current })
            defer { finish(headphones) }
            finder.play(.left)
            if phase != .connecting { finder.simulateConnectionOpened() }
            if phase == .ringing {
                finder.simulateProtocolData(try XCTUnwrap(FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 2, 30]).encoded))
            } else if phase == .stopping { finder.stop() }
            else if phase == .unconfirmed { finder.simulateTransportFailure() }
            XCTAssertEqual(finder.session?.phase, phase)

            let error = await ldac.simulateConnectionPreferenceRestoration(headphones, request: request)
            XCTAssertNil(error)
            XCTAssertEqual(ldac.simulatedDeferredConnectionMode(forAddress: headphones.address), request)
            XCTAssertEqual(headphones.lastConnectionModeChangeID, request)
            XCTAssertEqual(headphones.connectionMode, .soundQuality)

            headphones.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x13, 1, 1, 1]))
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(headphones.lastConnectionModeChangeID, request)
            XCTAssertEqual(ldac.simulatedDeferredConnectionMode(forAddress: headphones.address), request)

            if phase == .unconfirmed {
                finder.retryStop()
                finder.simulateConnectionOpened()
            } else { finder.stop() }
            if finder.mayBeRinging {
                finder.simulateProtocolData(try XCTUnwrap(FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 0]).encoded))
            }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(finder.session?.phase, .finished)
            XCTAssertNil(ldac.simulatedDeferredConnectionMode(forAddress: headphones.address))
            XCTAssertNotEqual(headphones.lastConnectionModeChangeID, request)
            XCTAssertEqual(headphones.connectionTransition?.targetMode, .stableConnection)
            headphones.respondToConnectionAlert(try XCTUnwrap(headphones.connectionTransition?.alert), action: .positive)
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(headphones.connectionMode, .stableConnection)
            XCTAssertEqual(headphones.connectionTransition?.phase, .confirmed)
        }
    }

    func testFinderDoesNotRetainSupersededConnectionPreferenceOwnership() async throws {
        let (coordinator, headphones, finder, _) = try preparedFinder()
        let ldac = LDACController(devices: coordinator, inspectDriver: { _ in .current })
        defer { finish(headphones) }
        finder.play(.left)
        finder.simulateConnectionOpened()
        let currentRequest = headphones.lastConnectionModeChangeID

        let error = await ldac.simulateConnectionPreferenceRestoration(headphones, request: UUID())

        XCTAssertNil(error)
        XCTAssertNil(ldac.simulatedDeferredConnectionMode(forAddress: headphones.address))
        XCTAssertEqual(headphones.lastConnectionModeChangeID, currentRequest)
        XCTAssertEqual(finder.session?.phase, .starting)
    }

    func testStopWaitsForRunningPreferenceRestorationAndCompletesEveryHandlerOnce() async throws {
        for action in [SonyConnectionAlertAction.positive, .negative] {
            let (coordinator, headphones, finder, request) = try preparedFinder()
            let ldac = LDACController(devices: coordinator, inspectDriver: { _ in .current })
            defer { finish(headphones) }
            finder.play(.left)
            let error = await ldac.simulateConnectionPreferenceRestoration(headphones, request: request)
            XCTAssertNil(error)
            finder.stop()
            for _ in 0..<20 { await Task.yield() }
            let alert = try XCTUnwrap(headphones.connectionTransition?.alert)
            XCTAssertFalse(ldac.isSessionRunning)
            XCTAssertTrue(ldac.needsStopBeforeTermination)
            var firstCompletions = 0
            var secondCompletions = 0

            ldac.stop { firstCompletions += 1 }
            ldac.stop { secondCompletions += 1 }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(firstCompletions, 0)
            XCTAssertEqual(secondCompletions, 0)

            headphones.respondToConnectionAlert(alert, action: action)
            for _ in 0..<20 { await Task.yield() }
            XCTAssertFalse(ldac.needsStopBeforeTermination)
            XCTAssertEqual(firstCompletions, 1)
            XCTAssertEqual(secondCompletions, 1)
            var laterCompletions = 0
            ldac.stop { laterCompletions += 1 }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(firstCompletions, 1)
            XCTAssertEqual(secondCompletions, 1)
            XCTAssertEqual(laterCompletions, 1)
        }
    }

    func testStopDoesNotStartDeferredRestorationWhileFinderSoundIsUnconfirmed() async throws {
        let (coordinator, headphones, finder, request) = try preparedFinder()
        let ldac = LDACController(devices: coordinator, inspectDriver: { _ in .current })
        defer { finish(headphones) }
        finder.play(.left)
        finder.simulateConnectionOpened()
        finder.simulateTransportFailure()
        XCTAssertEqual(finder.session?.phase, .unconfirmed)
        let error = await ldac.simulateConnectionPreferenceRestoration(headphones, request: request)
        XCTAssertNil(error)
        var completions = 0

        ldac.stop { completions += 1 }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(completions, 1)
        XCTAssertFalse(ldac.needsStopBeforeTermination)
        XCTAssertEqual(ldac.simulatedDeferredConnectionMode(forAddress: headphones.address), request)
        XCTAssertEqual(headphones.lastConnectionModeChangeID, request)
        XCTAssertTrue(finder.mayBeRinging)
    }

    private func preparedFinder() throws -> (SonyDeviceCoordinator, SonyHeadphonesController, EarbudFinderController, UUID) {
        let address = "02:53:4F:4E:59:01"
        let coordinator = SonyDeviceCoordinator(fallbackController: SonyHeadphonesController(startAutomatically: false, simulated: true)) { device in
            let controller = SonyHeadphonesController(startAutomatically: false, simulatedReady: true,
                pinnedAddress: device.address, advertisedName: device.name)
            controller.simulateDeviceConnection(named: device.name, simulatedAddress: device.address, galleryModel: .wfXM5)
            return controller
        }
        coordinator.reconcileConnectedDevices([try XCTUnwrap(SonyConnectedDevice(address: address, name: "WF-1000XM5", model: .wfXM5))])
        let headphones = try XCTUnwrap(coordinator.controller(for: address))
        let firmware = Array("6.1.0".utf8)
        headphones.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0,
            payload: [0x05, 2, UInt8(firmware.count)] + firmware))
        headphones.setConnectionMode(.stableConnection)
        let request = try XCTUnwrap(headphones.lastConnectionModeChangeID)
        headphones.respondToConnectionAlert(try XCTUnwrap(headphones.connectionTransition?.alert), action: .negative)
        XCTAssertEqual(headphones.connectionMode, .soundQuality)
        XCTAssertTrue(headphones.beginEarbudFinder())
        return (coordinator, headphones, try XCTUnwrap(headphones.earbudFinder), request)
    }

    private func finish(_ headphones: SonyHeadphonesController) {
        headphones.earbudFinder?.dismiss()
        headphones.earbudFinder?.simulateTransportFailure()
        headphones.simulateControlLoss()
    }
}
#endif

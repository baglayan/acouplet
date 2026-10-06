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
        let controller = LDACController(inspectDriver: { _ in
            LDACDriverInstaller.state(required: 3, installed: installed, loaded: loaded)
        })
        XCTAssertEqual(controller.driverState, .outdated)
        XCTAssertTrue(controller.canStartOrInstallDriver)

        installed = 3
        controller.refreshDriverState()
        XCTAssertEqual(controller.driverState, .restartRequired)
        XCTAssertFalse(controller.canStartOrInstallDriver)

        loaded = nil
        controller.refreshDriverState()
        XCTAssertEqual(controller.driverState, .restartRequired)
        XCTAssertFalse(controller.canStartOrInstallDriver)

        loaded = 3
        controller.refreshDriverState()
        XCTAssertEqual(controller.driverState, .current)
        XCTAssertTrue(controller.canStartOrInstallDriver)

        installed = nil
        controller.refreshDriverState()
        XCTAssertEqual(controller.driverState, .missing)
        XCTAssertTrue(controller.canStartOrInstallDriver)
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
#endif

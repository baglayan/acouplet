#if !ACOUPLET_PUBLIC_APIS_ONLY
import AppKit
import Foundation
import Security

@MainActor
enum LDACDriverInstaller {
    enum State: Equatable {
        case missing
        case outdated
        case restartRequired
        case current
        case unavailable(String)
    }

    private static let identifier = "dev.baglayan.Acouplet.LDACOutput"
    private static let installedURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/AcoupletLDACOutput.driver", isDirectory: true)

    static func inspect(bundle: Bundle = .main) -> State {
        do {
            let bundled = bundle.bundleURL.appendingPathComponent("Contents/Helpers/AcoupletLDACOutput.driver", isDirectory: true)
            let team = try signingTeam(bundle: bundle)
            let development = isDevelopment(bundle: bundle)
            try validateCode(at: bundled, identifier: identifier, team: team, development: development)
            let required = try revision(at: bundled)
            guard required > 0 else { throw failure("The app’s LDAC driver is incomplete. Reinstall the app.") }
            guard FileManager.default.fileExists(atPath: installedURL.path) else { return .missing }
            do {
                try validateCode(at: installedURL, identifier: identifier, team: team, development: development)
            } catch {
                return .outdated
            }
            let installed = try revision(at: installedURL)
            guard installed >= required else { return .outdated }
            return state(required: required, installed: installed, loaded: try LDACNativeOutput.driverRevision())
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    static func state(required: Int, installed: Int?, loaded: Int?) -> State {
        guard let installed else { return .missing }
        guard installed >= required else { return .outdated }
        guard let loaded, loaded >= required else { return .restartRequired }
        return .current
    }

    static func openInstaller(bundle: Bundle = .main) async throws {
        let package = bundle.bundleURL.appendingPathComponent("Contents/Resources/Acouplet LDAC Output.pkg")
        let values = try package.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let expectedPackage = bundle.bundleURL.resolvingSymlinksInPath().appendingPathComponent("Contents/Resources/Acouplet LDAC Output.pkg")
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              package.resolvingSymlinksInPath() == expectedPackage else {
            throw failure("The LDAC installer is missing or has been changed. Reinstall the app.")
        }
        guard let identifier = bundle.bundleIdentifier else {
            throw failure("The app’s identity could not be verified. Reinstall the app.")
        }
        let development = isDevelopment(bundle: bundle)
        try validateCode(at: bundle.bundleURL, identifier: identifier, team: signingTeam(bundle: bundle),
                         development: development, resources: true)
        let installer = URL(fileURLWithPath: "/System/Library/CoreServices/Installer.app", isDirectory: true)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([package], withApplicationAt: installer, configuration: .init()) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private static func revision(at url: URL) throws -> Int {
        let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == identifier else {
            throw failure("The LDAC driver’s identity could not be verified. Reinstall the app.")
        }
        guard let value = info["AcoupletLDACDriverRevision"] else { return 0 }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID(),
              number.intValue > 0, number.doubleValue == Double(number.intValue) else {
            throw failure("The LDAC driver’s version could not be verified. Reinstall the app.")
        }
        return number.intValue
    }

    private static func signingTeam(bundle: Bundle) throws -> String {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any], let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            throw failure("The app’s signing identity could not be verified. Reinstall the app.")
        }
        return team
    }

    private static func isDevelopment(bundle: Bundle) -> Bool {
        #if DEBUG
        true
        #else
        bundle.object(forInfoDictionaryKey: "AcoupletDistribution") as? String == "development"
        #endif
    }

    private static func validateCode(at url: URL, identifier: String, team: String, development: Bool, resources: Bool = false) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let identity = "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        let certificate = development ? "" : " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        let flags = kSecCSStrictValidate | kSecCSCheckAllArchitectures | (resources ? kSecCSCheckNestedCode : kSecCSDoNotValidateResources)
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString((identity + certificate) as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: flags), requirement) == errSecSuccess else {
            throw failure("The LDAC installation’s signature could not be verified. Reinstall the app.")
        }
    }

    private static func failure(_ message: String.LocalizationValue) -> NSError {
        NSError(domain: "LDACDriverInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: message)])
    }
}
#endif

import Foundation

private struct ImplementationFeature: Decodable {
    let id: String
    let namespace: String
    let capability_table: Int?
    let byte: UInt8
}

private struct ImplementationRequest: Decodable {
    let features: [ImplementationFeature]
}

private func implementationValue<T>(_ value: T?) -> Any {
    value.map { $0 as Any } ?? NSNull()
}

@MainActor
private func implementationProbe(_ feature: ImplementationFeature) -> [String: Any] {
    let functions: Set<UInt8> = [feature.byte]
    var routes: [[String: Any]] = []
    var observations: [[String: Any]] = []
    func record(_ model: String, _ recognized: Bool, _ queries: [[UInt8]], frameType: UInt8 = 0x0C,
                source: String? = nil, symbol: String = "init(supportedFunctions:)",
                details: [String: Any] = [:], scope: String = "capability_queries") {
        let observation: [String: Any] = ["model": model, "source": source ?? "Sources/\(model).swift",
            "symbol": symbol, "recognized": recognized, "exposed": !queries.isEmpty, "scope": scope,
            "queries": queries.map { ["frame_type": Int(frameType), "payload": $0.map(Int.init)] },
            "details": details]
        observations.append(observation)
        if recognized || !queries.isEmpty { routes.append(observation) }
    }
    if feature.namespace == "mdr-v1" {
        let controls = SonyLegacyControls(supportPayload: [7, 0, 1, feature.byte])!
        record("SonyLegacyControls", !controls.batteryQueries.isEmpty || !controls.noiseQueries.isEmpty,
               controls.batteryQueries + controls.noiseQueries, symbol: "init(supportPayload:model:)",
               details: ["battery_queries": controls.batteryQueries, "noise_queries": controls.noiseQueries])
        record("SonyLegacyDSEE", controls.dsee.isSupported, controls.dsee.queryPayloads,
               source: "Sources/SonyLegacyControls.swift", symbol: "SonyLegacyControls.dsee")
        record("SonyLegacyConnectionQuality", controls.connectionQuality.isSupported, controls.connectionQuality.queryPayloads,
               source: "Sources/SonyLegacyControls.swift", symbol: "SonyLegacyControls.connectionQuality")
        record("SonyLegacyWearingControl", controls.wearingControl.isSupported, controls.wearingControl.queryPayloads,
               source: "Sources/SonyLegacyControls.swift", symbol: "SonyLegacyControls.wearingControl")
        record("SonyAutomaticPowerOffState", controls.automaticPowerOff != nil, controls.automaticPowerOff?.queryPayloads ?? [],
               source: "Sources/SonyLegacyControls.swift", symbol: "SonyLegacyControls.automaticPowerOff")
        let optimizer = SonyLegacyOptimizer(supportedFunctions: functions)
        record("SonyLegacyOptimizer", optimizer.isSupported, optimizer.queryPayloads)
        let indicators = SonyLegacyIndicators(supportedFunctions: functions)
        record("SonyLegacyIndicators", indicators.supportsCodecStatus || indicators.supportsUpscalingStatus || indicators.supportsConnectionStatus,
               indicators.queryPayloads, details: ["codec_status": indicators.supportsCodecStatus,
               "upscaling_status": indicators.supportsUpscalingStatus, "connection_status": indicators.supportsConnectionStatus])
        for kind in [SonyLegacySoundEffect.Kind.surround, .soundPosition] {
            let effect = SonyLegacySoundEffect(kind: kind, supportedFunctions: functions)
            record("SonyLegacySoundEffect", effect.isSupported, effect.queryPayloads,
                   symbol: "init(kind:supportedFunctions:)", details: ["kind": String(describing: kind)])
        }
        let equalizer = SonyEqualizer(supportedFunctions: functions, generation: .v1)
        record("SonyEqualizer", equalizer.isSupported, equalizer.queryPayloads,
               symbol: "init(supportedFunctions:generation:)",
               details: ["inquiry_type": implementationValue(equalizer.inquiryType)])
        let playback = SonyPlayback(supportedFunctions: functions, generation: .v1)
        record("SonyPlayback", playback.isSupported, playback.queryPayloads, symbol: "init(supportedFunctions:generation:)")
        let system = SonySystemFeatures(legacyGeneralSettings: functions)
        record("SonySystemFeatures", !system.queryPayloads.isEmpty, system.queryPayloads,
               symbol: "init(legacyGeneralSettings:)", scope: "general_setting_identification")
        let touch = SonyTouchAssignments(supportedFunctions: functions, generation: .v1)
        record("SonyTouchAssignments", touch.inquiryType != nil, touch.queryPayloads,
               symbol: "init(supportedFunctions:generation:)", details: ["inquiry_type": implementationValue(touch.inquiryType)])
        let voice = SonyVoiceGuidance(supportedFunctions: functions, generation: .v1)
        record("SonyVoiceGuidance", voice.supportsGuidance, voice.queryPayloads,
               symbol: "init(supportedFunctions:generation:)", details: ["supports_volume": voice.supportsVolume])
        let multipoint = SonyMultipoint(legacySupportedFunctions: functions)
        record("SonyMultipoint", multipoint.supportsLegacyInventory, multipoint.queryPayloads,
               symbol: "init(legacySupportedFunctions:)")
    } else if feature.namespace == "mdr-v2", feature.capability_table == 1 {
        let batteryTypes = SonyBatteries.queryTypes(supportedFunctions: functions)
        record("SonyBatteries", !batteryTypes.isEmpty, batteryTypes.map { [0x22, $0] },
               source: "Sources/SonyProtocol.swift", symbol: "queryTypes(supportedFunctions:)",
               details: ["query_types": batteryTypes])
        let equalizer = SonyEqualizer(supportedFunctions: functions)
        record("SonyEqualizer", equalizer.isSupported, equalizer.queryPayloads,
               details: ["inquiry_type": implementationValue(equalizer.inquiryType)])
        let audio = SonyAudioFeatures(supportedFunctions: functions)
        record("SonyAudioFeatures", audio.supportsConnectionStatus || audio.supportsCodecStatus || audio.supportsDSEE || audio.supportsConnectionMode,
               audio.queryPayloads, details: ["connection_status": audio.supportsConnectionStatus,
               "codec_status": audio.supportsCodecStatus, "dsee": audio.supportsDSEE,
               "connection_mode": audio.supportsConnectionMode, "inquiry_type": implementationValue(audio.connectionModeInquiryType)])
        let system = SonySystemFeatures(supportedFunctions: functions)
        record("SonySystemFeatures", !system.queryPayloads.isEmpty, system.queryPayloads,
               details: ["system_features": SonySystemFeature.allCases.filter { system[$0] != nil }.map { String(describing: $0) },
               "voice_assistant": system.voiceAssistant != nil, "automatic_power_off": system.automaticPowerOff != nil,
               "general_settings_identified": system.generalSettingsAreIdentified],
               scope: system.generalSettingsAreIdentified ? "capability_queries" : "general_setting_identification")
        let power = SonyPowerFeatures(supportedFunctions: functions)
        record("SonyPowerFeatures", power.batteryCare != nil || power.autoPowerSave != nil || power.stamina != nil || power.touchPanelBacklight != nil
               || power.powerSavingMode != nil || power.bluetoothStandby != nil,
               power.queryPayloads(frameType: 0x0C), symbol: "init(supportedFunctions:supportedFunctions2:)",
               details: ["battery_care": power.batteryCare != nil, "auto_power_save": power.autoPowerSave != nil,
               "stamina": power.stamina != nil, "touch_panel_backlight": power.touchPanelBacklight != nil,
               "power_saving_mode": power.powerSavingMode != nil, "bluetooth_standby": power.bluetoothStandby != nil])
        let playback = SonyPlayback(supportedFunctions: functions)
        record("SonyPlayback", playback.isSupported, playback.queryPayloads, symbol: "init(supportedFunctions:generation:)")
        let touch = SonyTouchAssignments(supportedFunctions: functions)
        record("SonyTouchAssignments", touch.inquiryType != nil, touch.queryPayloads,
               symbol: "init(supportedFunctions:generation:)", details: ["inquiry_type": implementationValue(touch.inquiryType)])
        let fit = SonyEarTipFit(supportedFunctions: functions)
        record("SonyEarTipFit", fit.isSupported || fit.supportsEarpieceSelection, fit.queryPayloads,
               details: ["measurement": fit.isSupported, "earpiece_selection": fit.supportsEarpieceSelection])
        if fit.supportsEarpieceSelection && !fit.isSupported {
            let prerequisite: Set<UInt8> = [0xF6]
            let baseline = SonyEarTipFit(supportedFunctions: prerequisite)
            let combined = SonyEarTipFit(supportedFunctions: functions.union(prerequisite))
            record("SonyEarTipFit", combined.supportsEarpieceSelection,
                   combined.queryPayloads.filter { !baseline.queryPayloads.contains($0) },
                   details: ["required_capabilities": prerequisite.sorted(), "baseline_queries": baseline.queryPayloads,
                   "combined_queries": combined.queryPayloads], scope: "dependent_capability_queries")
        }
        let gestures = SonyHeadGesturePractice(supportedFunctions: functions)
        record("SonyHeadGesturePractice", gestures.isSupported, gestures.isSupported ? [SonyHeadGesturePractice.queryPayload] : [])
        let firmware = SonyFirmwareUpdateIdentity.request(supportedFunctions: functions)
        record("SonyFirmwareUpdateIdentity", firmware != nil, firmware.map { [$0] } ?? [],
               source: "Sources/SonyFirmwareUpdate.swift", symbol: "request(supportedFunctions:)", scope: "firmware_update_identity")
        var noise = ImplementationNoiseDispatch()
        let noiseType = noise.collect(functions)
        record("SonyHeadphonesController.noiseControl", noiseType != nil, noise.queries,
               source: "Sources/SonyHeadphonesController.swift", symbol: "asmByFunction / requestNoiseControl(_:)",
               details: ["inquiry_type": implementationValue(noiseType), "model": noise.noiseControl != nil],
               scope: "compiled_controller_noise_dispatch")
        record("SonyNoiseToggle", noise.noiseToggle != nil, noise.noiseToggle?.queryPayloads ?? [],
               source: "Sources/SonyHeadphonesController.swift", symbol: "noiseToggle = functions.contains(_:)",
               scope: "compiled_controller_noise_dispatch")
        record("SonyNoiseTest", noise.noiseTest != nil, noise.noiseTest.map { [$0.queryPayload] } ?? [],
               source: "Sources/SonyHeadphonesController.swift", symbol: "noiseTest = supported?.type",
               scope: "compiled_controller_noise_dispatch")
    } else if feature.namespace == "mdr-v2", feature.capability_table == 2 {
        let multipoint = SonyMultipoint(supportedFunctions: functions)
        record("SonyMultipoint", multipoint.supportsInventory || multipoint.supportsSourceControl, multipoint.queryPayloads, frameType: 0x0E,
               details: ["inventory": multipoint.supportsInventory, "source_control": multipoint.supportsSourceControl,
               "inquiry_type": implementationValue(multipoint.inventoryInquiryType)])
        let voice = SonyVoiceGuidance(supportedFunctions: functions)
        record("SonyVoiceGuidance", voice.supportsGuidance, voice.queryPayloads, frameType: 0x0E,
               symbol: "init(supportedFunctions:generation:)", details: ["supports_volume": voice.supportsVolume])
        let sound = SonySoundPressure(supportedFunctions: functions)
        record("SonySoundPressure", sound.isSupported, sound.queryPayloads, frameType: 0x0E)
        let wearing = SonyWearingStatus(supportedFunctions: functions)
        record("SonyWearingStatus", wearing.isSupported, wearing.queryPayloads, frameType: 0x0E)
        let power = SonyPowerFeatures(supportedFunctions2: functions)
        record("SonyPowerFeatures", power.batteryCare != nil || power.autoStandby != nil || power.supportsChargeInUse,
               power.queryPayloads(frameType: 0x0E), frameType: 0x0E,
               symbol: "init(supportedFunctions:supportedFunctions2:)",
               details: ["battery_care": power.batteryCare != nil, "includes_threshold": implementationValue(power.batteryCare?.includesThreshold),
               "auto_standby": power.autoStandby != nil, "charge_in_use": power.supportsChargeInUse],
               scope: power.supportsChargeInUse ? "capability_advisory" : "capability_queries")
    }
    return ["id": feature.id, "recognized": routes.contains { $0["recognized"] as? Bool == true },
            "exposed": routes.contains { $0["exposed"] as? Bool == true }, "routes": routes,
            "observations": observations, "probed_models": observations.compactMap { $0["model"] },
            "evidence_kind": "compiled_capability_probe",
            "scope": feature.namespace == "ble-model" ? "no_production_model_feature_decoder" : "protocol_model_and_noise_dispatch"]
}

@main
private struct ImplementationAdapter {
    @MainActor
    static func main() throws {
        let request = try JSONDecoder().decode(ImplementationRequest.self, from: FileHandle.standardInput.readDataToEndOfFile())
        let result = request.features.map(implementationProbe)
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
    }
}

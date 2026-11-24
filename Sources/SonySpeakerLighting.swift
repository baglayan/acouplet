import Foundation

struct SonySpeakerLighting: Equatable, Sendable {
    static let frameType: UInt8 = 0x0E

    enum PartyItem: UInt8, Hashable, Sendable {
        case reset = 0, flash, customColor
    }

    enum Mode: UInt8, Hashable, Sendable {
        case off = 0, delightful, rave, chill, strobe, gradation
        case allFlashing = 7, random, circle, beat, wave, mellow, hot, cool, cute, fresh, calmDaylight
    }

    enum ColorType: UInt8, Hashable, Sendable {
        case multicolor = 0, white, customColor
    }

    struct RGB: Equatable, Sendable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8

        var bytes: [UInt8] { [red, green, blue] }
    }

    struct PartyOption: Equatable, Sendable {
        let item: PartyItem
        let colorElement: UInt8
        let palette: UInt8
    }

    enum Parameter: UInt8, Hashable, Sendable {
        case party = 0x01, mode = 0x0E, colorType = 0x10, customColor = 0x11

        var query: [UInt8] { [self == .party ? 0x76 : 0xF6, rawValue] }

        static func setting(_ payload: [UInt8]) -> Self? {
            guard payload.count >= 3, let parameter = Self(rawValue: payload[1]),
                  payload[0] == (parameter == .party ? 0x78 : 0xF8) else { return nil }
            return parameter
        }
    }

    let supportsParty: Bool
    let supportsMode: Bool
    let supportsDefaultColor: Bool
    private(set) var partyOptions: [PartyOption]?
    private(set) var partyAvailable: Bool?
    private(set) var partyItem: PartyItem?
    private(set) var modeOptions: [Mode]?
    private(set) var modeExclusiveFunctions: [UInt8] = []
    private(set) var modeAvailable: Bool?
    private(set) var mode: Mode?
    private(set) var colorOptions: [ColorType]?
    private(set) var colorType: ColorType?
    private(set) var customColor: RGB?

    init(supportedFunctions2: Set<UInt8> = []) {
        supportsParty = supportedFunctions2.contains(0x71)
        supportsMode = supportedFunctions2.contains(0xFC)
        supportsDefaultColor = supportedFunctions2.contains(0xFE)
    }

    var isSupported: Bool { supportsParty || supportsMode || supportsDefaultColor }

    var queryPayloads: [[UInt8]] {
        (supportsParty ? [[0x70, 1], [0x72, 1], Parameter.party.query] : [])
            + (supportsMode ? [[0xF0, 0x0E], [0xF2, 0x0E], Parameter.mode.query] : [])
            + (supportsDefaultColor ? [[0xF0, 0x10], Parameter.colorType.query, Parameter.customColor.query] : [])
    }

    var currentPartyPalette: UInt8? {
        guard partyAvailable == true, let partyItem, partyItem != .reset else { return nil }
        return partyOptions?.first(where: { $0.item == partyItem && $0.colorElement == 0 })?.palette
    }

    func value(_ parameter: Parameter) -> [UInt8]? {
        switch parameter {
        case .party: partyItem.map { [$0.rawValue] }
        case .mode: mode.map { [$0.rawValue] }
        case .colorType: colorType.map { [$0.rawValue] }
        case .customColor: customColor?.bytes
        }
    }

    func setPayload(_ parameter: Parameter, value: [UInt8], notify: Bool = true) -> [UInt8]? {
        guard self.value(parameter) != nil else { return nil }
        switch parameter {
        case .party:
            guard value.count == 1, partyAvailable == true, let partyOptions,
                  value[0] == PartyItem.reset.rawValue || partyOptions.contains(where: { $0.item.rawValue == value[0] }) else { return nil }
            return [0x78, parameter.rawValue] + value
        case .mode:
            guard value.count == 1, modeAvailable == true,
                  modeOptions?.contains(where: { $0.rawValue == value[0] }) == true else { return nil }
        case .colorType:
            guard value.count == 1, colorOptions?.contains(where: { $0.rawValue == value[0] }) == true else { return nil }
        case .customColor:
            guard value.count == 3, colorType == .customColor, colorOptions?.contains(.customColor) == true else { return nil }
            return [0xF8, parameter.rawValue, notify ? 0 : 1] + value
        }
        return [0xF8, parameter.rawValue] + value
    }

    func partyColorPayload(operation: UInt8, x: Int, y: Int, color: RGB) -> [UInt8]? {
        guard currentPartyPalette != nil, operation <= 2, (-100...100).contains(x), (-100...100).contains(y) else { return nil }
        return [0x7C, 1, operation, UInt8(bitPattern: Int8(x)), UInt8(bitPattern: Int8(y))] + color.bytes
    }

    static func readQuery(for payload: [UInt8]) -> (query: [UInt8], notification: Bool)? {
        guard payload.count >= 2 else { return nil }
        switch (payload[0], payload[1]) {
        case (0x71, 1), (0x73, 1), (0x77, 1),
             (0xF1, 0x0E), (0xF3, 0x0E), (0xF7, 0x0E),
             (0xF1, 0x10), (0xF7, 0x10), (0xF7, 0x11):
            return ([payload[0] - 1, payload[1]], false)
        case (0x75, 1), (0x79, 1), (0xF5, 0x0E), (0xF9, 0x0E), (0xF9, 0x10), (0xF9, 0x11):
            return ([payload[0] - 3, payload[1]], true)
        default: return nil
        }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8], frameType: UInt8) -> Bool {
        guard frameType == Self.frameType, payload.count >= 3, let read = Self.readQuery(for: payload),
              queryPayloads.contains(read.query) else { return false }
        switch read.query {
        case [0x70, 1]:
            let count = Int(payload[2])
            guard count > 0, payload.count == 3 + count * 3 else { return false }
            var options: [PartyOption] = []
            for index in stride(from: 3, to: payload.count, by: 3) {
                guard let item = PartyItem(rawValue: payload[index]), item != .reset, payload[index + 1] == 0,
                      payload[index + 2] <= 1 else { return false }
                options.append(PartyOption(item: item, colorElement: payload[index + 1], palette: payload[index + 2]))
            }
            partyOptions = options
        case [0xF0, 0x0E]:
            let endOfModes = 3 + Int(payload[2])
            guard endOfModes < payload.count, payload.count == endOfModes + 1 + Int(payload[endOfModes]) else { return false }
            let modes = payload[3..<endOfModes].compactMap(Mode.init(rawValue:))
            let exclusive = payload[(endOfModes + 1)...]
            guard modes.count == endOfModes - 3, exclusive.allSatisfy({ $0 == 0 }) else { return false }
            modeOptions = modes
            modeExclusiveFunctions = Array(exclusive)
        case [0xF0, 0x10]:
            guard payload.count == 3 + Int(payload[2]) else { return false }
            let options = payload.dropFirst(3).compactMap(ColorType.init(rawValue:))
            guard options.count == Int(payload[2]) else { return false }
            colorOptions = options
        case [0x72, 1], [0xF2, 0x0E]:
            guard payload.count == 3, payload[2] <= 1 else { return false }
            if payload[1] == 1 { partyAvailable = payload[2] == 0 }
            else { modeAvailable = payload[2] == 0 }
        case Parameter.party.query:
            guard payload.count == 3, let item = PartyItem(rawValue: payload[2]), item != .reset else { return false }
            partyItem = item
        case Parameter.mode.query:
            guard payload.count == 3, let mode = Mode(rawValue: payload[2]) else { return false }
            self.mode = mode
        case Parameter.colorType.query:
            guard payload.count == 3, let type = ColorType(rawValue: payload[2]) else { return false }
            colorType = type
        case Parameter.customColor.query:
            guard payload.count == 5 else { return false }
            customColor = RGB(red: payload[2], green: payload[3], blue: payload[4])
        default: return false
        }
        return true
    }
}

import itertools
import random
from copy import deepcopy


AUDIO = "com.sony.songpal.tandemfamily.message.mdr.v2.table1.audio.param."
PERIPHERAL = "com.sony.songpal.tandemfamily.message.mdr.v2.table2.peripheral.param."
GENERAL = "com.sony.songpal.tandemfamily.message.mdr.v2.table1.generalsetting.param."
MODES = ["SOUND_QUALITY_PRIOR", "CONNECTION_QUALITY_PRIOR", "LOW_LATENCY_PRIOR_BETA"]
MODE_MEANINGS = {"SOUND_QUALITY_PRIOR": "soundQuality", "CONNECTION_QUALITY_PRIOR": "stableConnection",
                 "LOW_LATENCY_PRIOR_BETA": "lowLatency"}


def call(identifier, owner, method, types=(), args=(), target=None):
    result = {"id": identifier, "class": owner, "method": method, "types": list(types), "args": list(args)}
    if target is not None:
        result["target"] = target
    return result


def enum(owner, name):
    return {"enum": owner, "name": name}


def parsed(identifier, operation, payload, owner, getters, method="f", builder_type="b", **arguments):
    builder = identifier + ".builder"
    instance = identifier + ".parsed"
    calls = [call(builder, owner + "$" + builder_type, "<init>"),
             call(instance, owner + "$" + builder_type, method, ["byte[]"], [{"bytes": bytes(payload).hex()}], builder)]
    oracle = {}
    for key, getter in getters.items():
        oracle[key] = identifier + "." + key
        calls.append(call(oracle[key], owner, getter, target=instance))
    if operation == "actionResult":
        payload_id = identifier + ".parsedPayload"
        action_id = identifier + ".actionByte"
        oracle["action"] = identifier + ".action"
        calls.append(call(payload_id, owner, "d", target=instance))
        calls.append(call(action_id, "java.lang.reflect.Array", "getByte",
                          ["java.lang.Object", "int"], [{"ref": payload_id}, 2]))
        calls.append(call(oracle["action"], PERIPHERAL + "ConnectivityActionType", "from", ["byte"], [{"ref": action_id}]))
    return {"id": identifier, "calls": calls, "swift": {"op": "modern." + operation,
            "payload": payload, **arguments}, "oracle": oracle}


def written(identifier, operation, owner, types, args, **arguments):
    builder = identifier + ".builder"
    instance = identifier + ".written"
    output = identifier + ".payload"
    return {"id": identifier, "calls": [call(builder, owner + "$b", "<init>"),
            call(instance, owner + "$b", "h", types, args, builder),
            call(output, owner, "d", target=instance)],
            "swift": {"op": "modern." + operation, **arguments}, "oracle": {"payload": output}}


def inventory_payload(command, devices, playback, inquiry=2):
    payload = [command, inquiry, len(devices)]
    for address, connection, device_class, name in devices:
        payload.extend(address.encode())
        payload.append(connection)
        if inquiry == 2:
            payload.extend(device_class.to_bytes(3, "big"))
        payload.append(len(name.encode()))
        payload.extend(name.encode())
    return payload + [playback]


def inventory_case(identifier, command, devices, playback, inquiry=2):
    owner = ("oo0.t" if command == 0x37 else "oo0.k") if inquiry == 2 else ("oo0.s" if command == 0x37 else "oo0.j")
    case = parsed(identifier, "inventory", inventory_payload(command, devices, playback, inquiry),
                  owner, {"playback": "g" if inquiry == 2 else "h"}, function=0x32 if inquiry == 2 else 0x30)
    listed = identifier + ".list"
    connected = identifier + ".connected"
    case["calls"].append(call(listed, owner, "e" if inquiry == 2 else "f", target=identifier + ".parsed"))
    case["calls"].append(call(connected, owner, "c" if inquiry == 2 else "e", target=identifier + ".parsed"))
    for index in range(len(devices)):
        device = identifier + ".device." + str(index)
        case["calls"].append(call(device, "java.util.List", "get", ["int"], [index], listed))
        for key, method in {"address": "b", "connection": "d", "class": "a", "name": "c"}.items():
            output = device + "." + key
            case["calls"].append(call(output, "oo0.a", method, target=device))
            case["oracle"][f"device.{index}.{key}"] = output
        output = device + ".connected"
        case["calls"].append(call(output, "java.util.List", "contains", ["java.lang.Object"], [{"ref": device}], connected))
        case["oracle"][f"device.{index}.connected"] = output
    case["device_count"] = len(devices)
    return case


def cases():
    result = []
    alert_param = "com.sony.songpal.tandemfamily.message.mdr.v2.table1.alert.param."
    for function, action in itertools.product((0xE1, 0xE3, 0xE7), range(2)):
        case = written(f"modern.connection.multipointAlertReply.{function}.{action}", "connectionAlertSet", "en0.n",
                       [alert_param + "AlertMessageType", alert_param + "AlertAction"],
                       [enum(alert_param + "AlertMessageType", "CAUTION_FOR_CHANGING_TO_QUALITY_PRIOR_CONNECTION_MODE_WITH_2_DEVICES_CONNECTION"),
                        enum(alert_param + "AlertAction", "POSITIVE" if action else "NEGATIVE")],
                       payload=[0x99, 0, 0x71, 1], action=action, function=function)
        result.append(case)
    for count in (2, 3):
        for modes in itertools.permutations(range(3), count):
            for exclusions in ([], [0]):
                identifier = "modern.connection.capability." + "".join(map(str, modes)) + "." + str(len(exclusions))
                result.append(parsed(identifier, "connectionCapability", [0xE1, 5, count, *modes, len(exclusions), *exclusions],
                                     "fn0.z", {"modes": "f", "exclusions": "e"}))
    for command, owner in ((0xE3, "fn0.u0"), (0xE5, "fn0.n")):
        for available, ldac in itertools.product(range(2), repeat=2):
            result.append(parsed(f"modern.connection.status.{command}.{available}.{ldac}", "connectionStatus",
                                 [command, 5, available, ldac], owner, {"available": "f", "ldac": "e"}))
    for mode in range(3):
        result.append(parsed(f"modern.connection.parameter.{mode}", "connectionParameter", [0xE7, 5, mode],
                             "fn0.i0", {"mode": "e"}))
        for stream in range(3):
            result.append(parsed(f"modern.connection.notification.{mode}.{stream}", "connectionNotification",
                                 [0xE9, 5, mode, stream], "fn0.u", {"mode": "c", "stream": "e"}))
        result.append(written(f"modern.connection.set.{mode}", "connectionSet", "fn0.c1",
                              [AUDIO + "PriorMode", "boolean"], [enum(AUDIO + "PriorMode", MODES[mode]), True], mode=MODE_MEANINGS[MODES[mode]]))
    for inquiry, function in ((0, 0xE1), (2, 0xE3)):
        for command in (0xE3, 0xE5):
            owner = ("fn0.t0" if command == 0xE3 else "fn0.m") if inquiry == 0 else ("fn0.v0" if command == 0xE3 else "fn0.o")
            for available, ldac in itertools.product(range(2), range(1 if inquiry == 0 else 2)):
                payload = [command, inquiry, available] + ([] if inquiry == 0 else [ldac])
                getters = {"available": "e"} if inquiry == 0 else {"available": "f", "ldac": "e"}
                result.append(parsed(f"modern.connection.classicStatus.{inquiry}.{command}.{available}.{ldac}", "connectionStatus",
                                     payload, owner, getters, builder_type="a" if inquiry == 0 else "b", function=function))
        for mode in range(3):
            result.append(parsed(f"modern.connection.classicParameter.{inquiry}.{mode}", "connectionParameter", [0xE7, inquiry, mode],
                                 "fn0.i0" if inquiry == 0 else "fn0.j0", {"mode": "e"}, function=function))
            result.append(parsed(f"modern.connection.classicNotification.{inquiry}.{mode}", "connectionNotification", [0xE9, inquiry, mode],
                                 "fn0.t" if inquiry == 0 else "fn0.v", {"mode": "c"}, function=function))
        for mode in range(2):
            result.append(written(f"modern.connection.classicSet.{inquiry}.{mode}", "connectionSet", "fn0.b1" if inquiry == 0 else "fn0.d1",
                                  [AUDIO + "PriorMode"], [enum(AUDIO + "PriorMode", MODES[mode])], mode=MODE_MEANINGS[MODES[mode]], function=function))
    for paired, connected, transfer in itertools.product((1, 2, 8, 255), (1, 2, 3), range(2)):
        if connected <= paired:
            result.append(parsed(f"modern.multipoint.capability.{paired}.{connected}.{transfer}", "multipointCapability",
                                 [0x31, 2, paired, connected, transfer], "oo0.p",
                                 {"paired": "g", "connected": "f", "transfer": "e"}))
    for command, owner in ((0x33, "oo0.w"), (0x35, "oo0.n")):
        for mode, available in itertools.product(range(2), repeat=2):
            result.append(parsed(f"modern.multipoint.status.{command}.{mode}.{available}", "multipointStatus",
                                 [command, 2, mode, available], owner, {"mode": "c", "available": "e"}))
    rng = random.Random(130305109)
    names = ["A", "é", "東京", "Phone", "MacBook", "N" * 127, "N" * 128]
    for index in range(28):
        count = (0, 1, 2, 4, 8)[index % 5]
        devices = []
        for device_index in range(count):
            address = ":".join(f"{rng.randrange(256):02X}" for _ in range(6))
            connection = device_index + 1 if device_index < 2 else 0
            devices.append((address, connection, rng.randrange(1 << 24), names[(index + device_index) % len(names)]))
        playback = 0 if not devices else index % (min(count, 2) + 1)
        for command in (0x37, 0x39):
            result.append(inventory_case(f"modern.multipoint.inventory.{command}.{index}", command, devices, playback))
            result.append(inventory_case(f"modern.multipoint.classicInventory.{command}.{index}", command, devices, playback, inquiry=0))
    address = "12:34:56:78:9A:BC"
    for enabled in (False, True):
        result.append(parsed(f"modern.multipoint.keeping.{enabled}", "keeping", [0x37, 1, 0 if enabled else 1],
                             "oo0.u", {"keeping": "c"}))
        result.append(written(f"modern.multipoint.keepingSet.{enabled}", "keepingSet", "oo0.c0",
                              ["boolean"], [enabled], enabled=enabled))
        for status in range(5):
            result.append(parsed(f"modern.multipoint.keepingResult.{enabled}.{status}", "keepingResult",
                                 [0x39, 1, 0 if enabled else 1, status], "oo0.l", {"keeping": "e", "result": "c"}))
    result.append(written("modern.multipoint.sourceSet", "sourceSet", "oo0.z", ["java.lang.String"], [address], address=address))
    for status in range(5):
        result.append(parsed(f"modern.multipoint.sourceResult.{status}", "sourceResult", [0x3D, 1, status, *address.encode()],
                             "oo0.g", {"result": "c", "address": "e"}))
    for action, name in enumerate(("DISCONNECT", "CONNECT", "UNPAIR")):
        result.append(written(f"modern.multipoint.actionSet.{action}", "actionSet", "oo0.y",
                              [PERIPHERAL + "PeripheralInquiredType", PERIPHERAL + "ConnectivityActionType", "java.lang.String"],
                              [enum(PERIPHERAL + "PeripheralInquiredType", "PAIRING_DEVICE_MANAGEMENT_WITH_BLUETOOTH_CLASS_OF_DEVICE"),
                               enum(PERIPHERAL + "ConnectivityActionType", name), address], action=name.lower(), address=address))
        for status in (0, 1, 2, 3, 16, 17, 18, 19, 32, 33, 34, 35, 48, 49, 50, 51):
            result.append(parsed(f"modern.multipoint.actionResult.{action}.{status}", "actionResult",
                                 [0x3D, 2, action, status, *address.encode()], "oo0.f", {"result": "e", "address": "c"}))
    result.extend(general_cases())
    for case in list(result):
        if case["swift"]["op"] in ("modern.multipointCapability", "modern.multipointStatus", "modern.inventory", "modern.actionSet", "modern.actionResult"):
            if case["swift"].get("function", 0x32) == 0x32:
                result.append(multipoint_variant(case, 0x33))
                if case["swift"]["op"] != "modern.inventory":
                    result.append(multipoint_variant(case, 0x30))
    for case in result:
        operation = case["swift"]["op"]
        phase = "serializer" if operation.endswith("Set") else "capability" if operation.endswith("Capability") else "parser"
        table = 1 if operation.startswith("modern.connection") or operation.startswith("modern.general") else 2
        if operation.startswith("modern.general"):
            function = case["swift"]["slot"]
        elif operation.startswith("modern.connection"):
            function = case["swift"].get("function", 0xE7)
        elif operation in ("modern.sourceSet", "modern.sourceResult", "modern.keeping", "modern.keepingSet", "modern.keepingResult"):
            function = 0x31
        else:
            function = case["swift"].get("function", 0x32)
        case["phase"] = phase
        case["coverage_ids"] = [f"mdr-v2-t{table}-{function:02x}.{phase}"]
        if operation == "modern.general":
            case["coverage_ids"].append(f"mdr-v2-t1-{function:02x}.capability")
    return result


def multipoint_variant(original, function):
    case = deepcopy(original)
    identifier = original["id"]
    replacement = identifier + f".function{function:02x}"
    case["id"] = replacement
    case["swift"]["function"] = function
    for entry in case["calls"]:
        entry["id"] = entry["id"].replace(identifier, replacement, 1)
        if "target" in entry:
            entry["target"] = entry["target"].replace(identifier, replacement, 1)
        for argument in entry["args"]:
            if isinstance(argument, dict) and "ref" in argument:
                argument["ref"] = argument["ref"].replace(identifier, replacement, 1)
        if function == 0x30:
            for argument in entry["args"]:
                if isinstance(argument, dict) and "bytes" in argument:
                    payload = bytearray.fromhex(argument["bytes"])
                    payload[1] = 0
                    argument["bytes"] = payload.hex()
                elif isinstance(argument, dict) and argument.get("enum") == PERIPHERAL + "PeripheralInquiredType":
                    argument["name"] = "PAIRING_DEVICE_MANAGEMENT_CLASSIC_BT"
    case["oracle"] = {key: value.replace(identifier, replacement, 1) for key, value in case["oracle"].items()}
    if function == 0x30 and "payload" in case["swift"]:
        case["swift"]["payload"][1] = 0
    return case


def general_cases():
    result = []
    for slot, setting, available, enabled, notification in itertools.product(range(0xD1, 0xD5),
            ("MULTIPOINT_SETTING", "SIDETONE_SETTING"), range(2), range(2), (False, True)):
        identifier = f"modern.general.{slot}.{setting}.{available}.{enabled}.{notification}"
        capability = [0xD1, slot, 0, 1, len(setting), *setting.encode(), 0]
        status = [0xD5 if notification else 0xD3, slot, available]
        parameter = [0xD9 if notification else 0xD7, slot, 0, enabled]
        case = parsed(identifier + ".capability", "unused", capability, "ln0.i", {})
        status_case = parsed(identifier + ".status", "unused", status, "ln0.g" if notification else "ln0.n", {"available": "c"}, method="e")
        parameter_case = parsed(identifier + ".parameter", "unused", parameter, "ln0.e" if notification else "ln0.l", {"enabled": "f"})
        case["id"] = identifier
        case["calls"] += status_case["calls"] + parameter_case["calls"]
        case["oracle"] = {**status_case["oracle"], **parameter_case["oracle"]}
        case["swift"] = {"op": "modern.general", "slot": slot, "setting": setting,
                         "payloads": [capability, status, parameter]}
        result.append(case)
    for slot, setting, enabled in itertools.product(range(0xD1, 0xD5), ("MULTIPOINT_SETTING", "SIDETONE_SETTING"), (False, True)):
        result.append(written(f"modern.general.set.{slot}.{setting}.{enabled}", "generalSet", "ln0.p",
                              [GENERAL + "GsInquiredType", GENERAL + "GsSettingValue"],
                              [enum(GENERAL + "GsInquiredType", f"GENERAL_SETTING{slot - 0xD0}"),
                               enum(GENERAL + "GsSettingValue", "ON" if enabled else "OFF")],
                              slot=slot, setting=setting, enabled=enabled))
    return result


def normalize(case, results):
    values = {}
    for key, identifier in case["oracle"].items():
        item = results[identifier]
        if isinstance(item, dict) and "ok" in item:
            if not item["ok"]:
                raise ValueError(f"{identifier}: {item['error']}")
            item = item["value"]
        values[key] = normalized_value(item)
    if "device_count" in case:
        devices = []
        for index in range(case["device_count"]):
            devices.append({key: values.pop(f"device.{index}.{key}") for key in ("address", "connection", "connected", "class", "name")})
        values["devices"] = devices
        values["selectedSource"] = next((device["address"] for device in devices
                                         if values["playback"] != 0 and device["connection"] == values["playback"]), "")
    return values


def normalized_value(value):
    if isinstance(value, list):
        return [normalized_value(item) for item in value]
    if not isinstance(value, dict):
        return value
    if "bytes" in value:
        return value["bytes"]
    name = value["name"]
    if name in ("ENABLE", "ON", "POSSIBLE"):
        return True
    if name in ("DISABLE", "OFF", "IMPOSSIBLE"):
        return False
    if name in MODES:
        return MODE_MEANINGS[name]
    if name == "GATT_CONNECTABLE":
        return "gattConnectable"
    if name in ("NONE", "LE_AUDIO", "CLASSIC_AUDIO"):
        return {"NONE": "none", "LE_AUDIO": "leAudio", "CLASSIC_AUDIO": "classicAudio"}[name]
    if name in ("NORMAL_MODE", "INQUIRY_SCAN_MODE"):
        return {"NORMAL_MODE": 0, "INQUIRY_SCAN_MODE": 1}[name]
    source_results = {"SUCCESS": "success", "FAIL": "failure", "FAIL_CALLING": "callInProgress",
                      "FAIL_A2DP_NOT_CONNECT": "a2dpNotConnected", "FAIL_GIVE_PRIORITY_TO_VOICE_ASSISTANT": "voiceAssistantPriority"}
    if name in source_results:
        return source_results[name]
    words = name.lower().replace("error", "failure").split("_")
    return words[0] + "".join(word.title() for word in words[1:])


def unsupported():
    return []


def mutations():
    connection_mapping = """    init(rawValue: UInt8) {
        self = switch rawValue {
        case 0x00: .soundQuality
        case 0x01: .stableConnection
        case 0x02: .lowLatency
        default: .unknown(rawValue)
        }
    }

    var title: String {
        switch self {
        case .soundQuality: String(localized: "Sound Quality")
        case .stableConnection: String(localized: "Stable Connection")
        case .lowLatency: String(localized: "Low Latency")
        case .unknown: String(localized: "Unknown")
        }
    }

    var sonyValue: UInt8? {
        switch self {
        case .soundQuality: 0x00
        case .stableConnection: 0x01
        case .lowLatency: 0x02
        case .unknown: nil
        }
    }"""
    swapped_connection_mapping = connection_mapping.replace(
        "case 0x00: .soundQuality\n        case 0x01: .stableConnection",
        "case 0x00: .stableConnection\n        case 0x01: .soundQuality").replace(
        "case .soundQuality: 0x00\n        case .stableConnection: 0x01",
        "case .soundQuality: 0x01\n        case .stableConnection: 0x00")
    return [
        {"name": "multipoint sound quality confirmation ignored",
         "replacement": ("SonyConnectionAlerts.swift", "case (.fixed, 0x71), (.fixed, 0x74), (.fixed, 0x76): .soundQuality",
                         "case (.fixed, 0x74), (.fixed, 0x76): .soundQuality"),
         "case_ids": [f"modern.connection.multipointAlertReply.{function}.{action}"
                      for function, action in itertools.product((0xE1, 0xE3, 0xE7), range(2))]},
        {"name": "connection quality and stability meaning swap",
         "replacement": ("SonyAudioFeatures.swift", connection_mapping, swapped_connection_mapping),
         "case_ids": [f"modern.connection.{phase}.{mode}" for phase in ("parameter", "set") for mode in range(2)]},
        {"name": "connect and disconnect meaning swap",
         "replacement": ("SonyMultipoint.swift", "case disconnect = 0x00\n    case connect = 0x01",
                         "case disconnect = 0x01\n    case connect = 0x00"),
         "case_ids": ["modern.multipoint.actionSet.0", "modern.multipoint.actionSet.1",
                      "modern.multipoint.actionResult.0.0", "modern.multipoint.actionResult.1.16"]},
        {"name": "source selection sent as connection action",
         "replacement": ("SonyMultipoint.swift", "return [0x3C, 0x01] + Array(address.utf8)",
                         "return [0x3C, inventoryInquiryType!, SonyPeripheralAction.connect.rawValue] + Array(address.utf8)"),
         "case_ids": ["modern.multipoint.sourceSet"]},
        {"name": "connected inventory interpreted as disconnected",
         "replacement": ("SonyMultipoint.swift", "var isConnected: Bool { connectionID != 0 }",
                         "var isConnected: Bool { connectionID == 0 }"),
         "case_ids": ["modern.multipoint.inventory.55.2"]},
        {"name": "selected source ignores playback connection",
         "replacement": ("SonyMultipoint.swift", "return devices.first { $0.connectionID == playbackRightID }",
                         "return devices.first { $0.isConnected }"),
         "case_ids": ["modern.multipoint.inventory.55.2"]},
    ]

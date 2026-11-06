import random


PARAM = "com.sony.songpal.tandemfamily.message.mdr.v1.table1.param."
GS = PARAM + "generalsetting."


def _call(calls, name, cls, method, types=(), args=(), target=None):
    identifier = calls[0]["id"].rsplit(":", 1)[0] + ":" + name if calls else name
    call = {"id": identifier, "class": cls, "method": method, "types": list(types), "args": list(args)}
    if target is not None:
        call["target"] = target
    calls.append(call)
    return identifier


def _case(identifier, operation, **inputs):
    return {"id": "legacy." + identifier, "swift": {"op": "legacy." + operation, **inputs}, "calls": [], "oracle": {}}


def _parse(case, cls, payload):
    calls = case["calls"]
    obj = _call(calls, case["id"] + ":object", cls, "<init>")
    _call(calls, "parse", cls, "g", ["byte[]"], [{"bytes": payload.hex()}], obj)
    return obj


def _get(case, key, cls, method, target):
    case["oracle"][key] = _call(case["calls"], key, cls, method, target=target)
    return case["oracle"][key]


def _metadata(slot, title="MULTIPOINT_SETTING", summary="", fmt=2, setting=1):
    title = title.encode("utf-8")
    summary = summary.encode("utf-8")
    return bytes([0xD1, slot, fmt, len(title)]) + title + bytes([len(summary)]) + summary + bytes([setting])


def _metadata_case(identifier, payload, kotlin=False):
    case = _case(identifier, "metadata", payload=payload.hex())
    if kotlin:
        parser = _call(case["calls"], case["id"] + ":parser", "ui0.n0", "<init>")
        obj = _call(case["calls"], "object", "ui0.n0", "a", ["byte[]"], [{"bytes": payload.hex()}], parser)
        _get(case, "setting", "ui0.m0", "a", obj)
        metadata = _get(case, "metadata", "ui0.m0", "b", obj)
        _get(case, "format", "ui0.a2", "a", metadata)
        _get(case, "title", "ui0.a2", "b", metadata)
        _get(case, "summary", "ui0.a2", "c", metadata)
        return case
    obj = _parse(case, "um0.f", payload)
    _get(case, "setting", "um0.f", "i", obj)
    metadata = _get(case, "metadata", "um0.f", "k", obj)
    _get(case, "format", "xm0.d", "a", metadata)
    _get(case, "title", "xm0.d", "c", metadata)
    _get(case, "summary", "xm0.d", "d", metadata)
    _get(case, "serialized", "um0.f", "d", obj)
    return case


def _inventory_payload(devices, playback=0, command=0x37):
    payload = bytes([command, 1, len(devices)])
    for index, connection, name in devices:
        address = f"02:53:4F:4E:{index // 256:02X}:{index % 256:02X}".encode()
        name = name.encode("utf-8")
        payload += address + bytes([connection, len(name)]) + name
    return payload + bytes([playback])


def _inventory_case(identifier, devices, playback=0, command=0x37):
    payload = _inventory_payload(devices, playback, command)
    case = _case(identifier, "inventory", payload=payload.hex())
    calls = case["calls"]
    cls = "an0.o" if command == 0x37 else "an0.h"
    builder = _call(calls, case["id"] + ":builder", cls + "$b", "<init>")
    obj = _call(calls, "object", cls + "$b", "e", ["byte[]"], [{"bytes": payload.hex()}], builder)
    items = _get(case, "items", cls, "f", obj)
    _get(case, "count", "java.util.List", "size", items)
    for index in range(len(devices)):
        item = _call(calls, f"item{index}", "java.util.List", "get", ["int"], [index], items)
        for key, method in [("address", "a"), ("name", "b"), ("connectionID", "c")]:
            _get(case, f"{key}{index}", "an0.k", method, item)
    return case


def cases():
    result = []
    for slot in range(0xD1, 0xD4):
        for title in ["MULTIPOINT_SETTING", "SIDETONE_SETTING", "TOUCH_PANEL_SETTING"]:
            for length in [0, 1, 127, 128]:
                result.append(_metadata_case(f"metadata.{slot}.{title}.{length}", _metadata(slot, title, "s" * length)))
        for fmt in [0, 1]:
            result.append(_metadata_case(f"metadata.format.{slot}.{fmt}", _metadata(slot, fmt=fmt)))
        result.append(_metadata_case(f"metadata.list.{slot}", _metadata(slot, setting=2) + bytes([0])))
        result.append(_metadata_case(f"metadata.padding.{slot}", _metadata(slot) + bytes([0])))
        for title in ["MULTIPOINT_SETTING", "SIDETONE_SETTING"]:
            identity = _metadata(slot, title).hex()
            for command, cls in [(0xD7, "um0.g"), (0xD9, "um0.d")]:
                for value in [0, 1]:
                    payload = bytes([command, slot, 1, value])
                    case = _case(f"boolean.{slot}.{title}.{command}.{value}", "boolean", identity=identity, payload=payload.hex())
                    obj = _parse(case, cls, payload)
                    setting = _get(case, "setting", cls, "h", obj)
                    _get(case, "enabled", "xm0.a", "e", setting)
                    result.append(case)
            for command, cls in [(0xD3, "um0.h"), (0xD5, "um0.e")]:
                for value in [0, 1]:
                    payload = bytes([command, slot, value])
                    case = _case(f"available.{slot}.{title}.{command}.{value}", "available", identity=identity, payload=payload.hex())
                    obj = _parse(case, cls, payload)
                    _get(case, "available", cls, "h", obj)
                    result.append(case)
            for enabled in [False, True]:
                case = _case(f"set.{slot}.{title}.{enabled}", "set", identity=identity, enabled=enabled)
                calls = case["calls"]
                value = _call(calls, case["id"] + ":value", "xm0.a", "<init>", [PARAM + "CommonOnOffSettingValue"],
                              [{"enum": PARAM + "CommonOnOffSettingValue", "name": "ON" if enabled else "OFF"}])
                obj = _call(calls, "object", "um0.i", "<init>", [GS + "GsInquiredType", "xm0.a"],
                            [{"enum": GS + "GsInquiredType", "name": f"GENERAL_SETTING{slot - 0xD0}"}, {"ref": value}])
                _get(case, "payload", "um0.i", "d", obj)
                result.append(case)
    for length in [0, 1, 127, 128]:
        result.append(_metadata_case(f"metadata.titlelength.{length}", _metadata(0xD2, "t" * length)))
    for text in ["Türkçe", "日本語", "🎧"]:
        result.append(_metadata_case(f"metadata.unicode.{text}", _metadata(0xD2, summary=text)))
    for length in [129, 255]:
        for fmt in [1, 2]:
            result.append(_metadata_case(f"metadata.kotlin.title.{fmt}.{length}",
                                        _metadata(0xD2, "t" * length, fmt=fmt), kotlin=True))
            for title in ["MULTIPOINT_SETTING", "SIDETONE_SETTING"]:
                result.append(_metadata_case(f"metadata.kotlin.summary.{title}.{fmt}.{length}",
                                            _metadata(0xD2, title, "s" * length, fmt=fmt), kotlin=True))

    for value in range(256):
        payload = bytes([0xA1, 1, value, value % 2, (value // 2) % 2])
        case = _case(f"playback.capability.{value}", "playbackCapability", payload=payload.hex())
        obj = _parse(case, "tm0.j2", payload)
        _get(case, "steps", "tm0.j2", "k", obj)
        result.append(case)
        for command, cls in [(0xA7, "tm0.k2"), (0xA9, "tm0.c1")]:
            payload = bytes([command, 1, 0x20, value])
            case = _case(f"playback.volume.{command}.{value}", "playbackVolume", payload=payload.hex())
            obj = _parse(case, cls, payload)
            volume = _get(case, "detail", cls, "h", obj)
            _get(case, "volume", "vm0.g0", "e", volume)
            result.append(case)
        if value < 255:
            case = _case(f"playback.set.{value}", "playbackSet", value=value)
            calls = case["calls"]
            volume = _call(calls, case["id"] + ":volume", "vm0.g0", "<init>", ["int"], [value])
            obj = _call(calls, "object", "tm0.k3", "<init>", [PARAM + "PlayInquiredType", "vm0.d0"],
                        [{"enum": PARAM + "PlayInquiredType", "name": "PLAYBACK_CONTROLLER"}, {"ref": volume}])
            _get(case, "payload", "tm0.k3", "d", obj)
            result.append(case)

    for command, cls in [(0xA3, "tm0.l2"), (0xA5, "tm0.d1")]:
        for available in [0, 1]:
            for state in range(4):
                payload = bytes([command, 1, available, state])
                case = _case(f"playback.status.{command}.{available}.{state}", "playbackStatus", payload=payload.hex())
                obj = _parse(case, cls, payload)
                _get(case, "available", cls, "j", obj)
                status = _get(case, "state", cls, "i", obj)
                _get(case, "stateCode", PARAM + "PlaybackStatus", "byteCode", status)
                result.append(case)

    for connection in range(256):
        result.append(_inventory_case(f"inventory.connection.{connection}", [(1, connection, "Device")]))
    for length in range(1, 129):
        result.append(_inventory_case(f"inventory.name.{length}", [(1, 1, "n" * length)]))
    for count in [0, 2, 8, 127]:
        result.append(_inventory_case(f"inventory.count.{count}", [(index, index % 3, f"Device {index}") for index in range(count)]))
    for name in ["Telefon İstanbul", "日本の電話", "🎧 Device"]:
        result.append(_inventory_case(f"inventory.unicode.{name}", [(1, 1, name)]))
    result.append(_inventory_case("inventory.duplicateConnection", [(1, 1, "Phone"), (2, 1, "Computer")]))
    for count in [0, 1, 2, 8]:
        result.append(_inventory_case(f"inventory.notification.{count}", [(index, index % 3, f"Device {index}") for index in range(count)], command=0x39))

    functions = [0, 0x11, 0x12, 0x13, 0x14, 0x15, 0x17, 0x18, 0x21, 0x22, 0x23, 0x30, 0x38, 0x39,
                 0x41, 0x42, 0x51, 0x52, 0x53, 0x61, 0x62, 0x63, 0x71, 0x81, 0x92, 0xA1, 0xB1, 0xC1,
                 0xD1, 0xD2, 0xD3, 0xE1, 0xE2, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6]
    randomizer = random.Random(133)
    sets = [[], functions, functions * 6] + [[function] for function in functions]
    sets += [randomizer.choices(functions, k=length) for length in [2, 8, 16, 64, 127, 128, 255]]
    for index, values in enumerate(sets):
        payload = bytes([7, 0, len(values)] + values)
        case = _case(f"functions.{index}", "functions", payload=payload.hex())
        obj = _parse(case, "tm0.s2", payload)
        items = _get(case, "items", "tm0.s2", "h", obj)
        for item_index in range(len(values)):
            item = _call(case["calls"], f"item{item_index}", "java.util.List", "get", ["int"], [item_index], items)
            _get(case, f"function{item_index}", PARAM + "FunctionType", "byteCode", item)
        result.append(case)

    metadata = _metadata(0xD2)
    inventory = _inventory_payload([(1, 1, "Device")])
    for operation, payload, cls in [("metadata", metadata, "um0.f"), ("inventory", inventory, "an0.o$b"),
                                    ("playbackCapability", bytes([0xA1, 1, 31, 1, 1]), "tm0.j2"),
                                    ("playbackVolume", bytes([0xA7, 1, 0x20, 10]), "tm0.k2")]:
        for length in range(len(payload)):
            truncated = payload[:length]
            case = _case(f"malformed.{operation}.prefix.{length}", operation, payload=truncated.hex())
            case["category"] = "malformed"
            case["expected"] = {"accepted": False}
            if operation == "inventory":
                builder = _call(case["calls"], case["id"] + ":builder", cls, "<init>")
                _call(case["calls"], "parse", cls, "e", ["byte[]"], [{"bytes": truncated.hex()}], builder)
            else:
                _parse(case, cls, truncated)
            result.append(case)
    for value in range(2, 256):
        payload = bytes([0xD7, 0xD2, 1, value])
        case = _case(f"malformed.boolean.{value}", "boolean", identity=metadata.hex(), payload=payload.hex())
        case["category"] = "malformed"
        case["expected"] = {"accepted": True, "enabled": None}
        obj = _parse(case, "um0.g", payload)
        setting = _get(case, "setting", "um0.g", "h", obj)
        _get(case, "enabled", "xm0.a", "e", setting)
        result.append(case)
    metadata_boundaries = [("invalidUTF8", metadata[:4] + bytes([255]) + metadata[5:]),
                           ("format3", _metadata(0xD2, fmt=3)),
                           ("format255", _metadata(0xD2, fmt=255)),
                           ("setting0", _metadata(0xD2, setting=0)),
                           ("setting3", _metadata(0xD2, setting=3)),
                           ("setting255", _metadata(0xD2, setting=255)),
                           ("listMissingCount", _metadata(0xD2, setting=2)),
                           ("listMissingEntry", _metadata(0xD2, setting=2) + bytes([1])),
                           ("trailingGarbage", metadata + bytes([1]))]
    for name, payload in metadata_boundaries:
        case = _metadata_case("malformed.metadata." + name, payload)
        case["category"] = "malformed"
        case["expected"] = {"accepted": False}
        result.append(case)
    inventory_boundaries = [("emptyName", _inventory_payload([(1, 1, "")])),
                            ("name129", _inventory_payload([(1, 1, "n" * 129)])),
                            ("name255", _inventory_payload([(1, 1, "n" * 255)])),
                            ("duplicateAddress", _inventory_payload([(1, 1, "A"), (1, 2, "B")])),
                            ("invalidUTF8", inventory[:22] + bytes([255]) + inventory[23:]),
                            ("trailingGarbage", inventory + bytes([0]))]
    for name, payload in inventory_boundaries:
        case = _case("malformed.inventory." + name, "inventory", payload=payload.hex())
        case["category"] = "malformed"
        case["expected"] = {"accepted": False}
        builder = _call(case["calls"], case["id"] + ":builder", "an0.o$b", "<init>")
        _call(case["calls"], "parse", "an0.o$b", "e", ["byte[]"], [{"bytes": payload.hex()}], builder)
        result.append(case)
    for case in result:
        operation = case["swift"]["op"].split(".", 1)[1]
        function = None
        phase = "parser"
        if operation in ["metadata", "boolean", "available", "set"]:
            payload = bytes.fromhex(case["swift"].get("identity", case["swift"].get("payload", "")))
            if len(payload) > 1:
                function = payload[1]
            if operation == "metadata":
                phase = "capability"
            elif operation == "set":
                phase = "serializer"
        elif operation == "inventory":
            function = 0x38
        elif operation.startswith("playback"):
            function = 0xA1
            if operation == "playbackCapability":
                phase = "capability"
            elif operation == "playbackSet":
                phase = "serializer"
        case["coverage_ids"] = [f"mdr-v1-t1-{function:02x}.{phase}"] if function is not None else []
    return result


def normalize(case, results):
    if case.get("category") == "malformed":
        return case["expected"]

    def value(key):
        return results[case["oracle"][key]]

    operation = case["swift"]["op"].split(".", 1)[1]
    if operation == "metadata":
        recognized = value("setting")["name"] == "BOOLEAN_TYPE" and value("format")["name"] == "ENUM_NAME"
        return {"accepted": True, "multipoint": recognized and value("title") == "MULTIPOINT_SETTING",
                "sidetone": recognized and value("title") == "SIDETONE_SETTING"}
    if operation == "boolean":
        return {"accepted": True, "enabled": value("enabled")["name"] == "ON"}
    if operation == "available":
        return {"accepted": True, "available": value("available")["name"] == "ENABLE"}
    if operation in ["set", "playbackSet"]:
        return {"payload": value("payload")["bytes"]}
    if operation == "playbackCapability":
        steps = value("steps")
        return {"accepted": True, "minimum": 0 if steps else None, "maximum": steps - 1 if steps else None}
    if operation == "playbackVolume":
        volume = value("volume")
        return {"accepted": True, "volume": volume if volume < 255 else None}
    if operation == "playbackStatus":
        return {"accepted": True, "available": value("available")["name"] == "ENABLE", "state": value("stateCode")}
    if operation == "inventory":
        return {"accepted": True, "devices": [{"address": value(f"address{index}").upper(),
                 "name": value(f"name{index}"), "connectionID": value(f"connectionID{index}")}
                for index in range(value("count"))]}
    if operation == "functions":
        return {"accepted": True, "functions": sorted({value(key) & 255 for key in case["oracle"] if key.startswith("function")})}
    raise ValueError(operation)


def unsupported():
    return [
        {"schema": "MDRv1 general-setting nonempty lists", "reason": "Only empty-list metadata is recognized to remove Boolean controls; nonempty list metadata and list values are not implemented. Boolean strings through 128 bytes use the old MDR oracle, and 129–255-byte strings use the APK Kotlin parser."},
        {"schema": "MDRv1 general-setting slot D4", "reason": "The pinned APK v1 GsInquiredType enum defines only D1, D2 and D3."},
        {"schema": "MDRv1 inventory counts 128 through 255", "reason": "The APK validator reads an unsigned count but the original list accessor uses a signed byte; tested counts are 0, 1, 2, 8 and 127."},
        {"schema": "MDRv1 playback-right selection", "reason": "Acouplet exposes the legacy inventory read-only and does not use the trailing playback-right byte."},
        {"schema": "MDRv1 unknown function codes", "reason": "The APK maps unknown codes to NO_USE while Acouplet retains them for capability discovery; all known enum values and list-length boundaries are compared."},
    ]

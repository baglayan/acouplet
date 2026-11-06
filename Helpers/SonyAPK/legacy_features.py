from legacy import PARAM, _call, _case, _get, _parse
import legacy_optimizer


def _code(case, key, cls, method, target, enum):
    value = _get(case, key + "Enum", cls, method, target)
    return _get(case, key, PARAM + enum, "byteCode", value)


def _feature(case, function, phase):
    case["coverage_ids"] = [f"mdr-v1-t1-{function:02x}.{phase}"]
    return case


def _sound_capability(identifier, records):
    payload = bytes([0x41, 1, len(records)])
    for preset, name in records:
        name = name.encode("utf-8")
        payload += bytes([preset, len(name)]) + name
    case = _case("features.soundCapability." + identifier, "features.soundCapability", kind=1,
                 payload=payload.hex(), names=all(name for _, name in records))
    obj = _parse(case, "tm0.z2", payload)
    detail = _get(case, "detail", "tm0.z2", "j", obj)
    items = _get(case, "items", "tm0.z2$c", "b", detail)
    _get(case, "count", "java.util.List", "size", items)
    for index in range(len(records)):
        item = _call(case["calls"], f"item{index}", "java.util.List", "get", ["int"], [index], items)
        _code(case, f"preset{index}", "vm0.e1", "b", item, "VptPresetId")
        _get(case, f"name{index}", "vm0.e1", "a", item)
    return _feature(case, 0x41, "capability")


def cases():
    result = []
    for count in [0, 1, 2, 8, 16]:
        result.append(_sound_capability(f"count.{count}", [(index, f"Preset {index}") for index in range(count)]))
    for length in range(129):
        result.append(_sound_capability(f"name.{length}", [(length % 16, "n" * length)]))
    for name in ["Salle Écho", "日本語", "🎧"]:
        result.append(_sound_capability("unicode." + name, [(3, name)]))
    for position_type in [0, 1]:
        payload = bytes([0x41, 2, position_type])
        case = _case(f"features.positionType.{position_type}", "features.soundCapability", kind=2, payload=payload.hex())
        obj = _parse(case, "tm0.z2", payload)
        detail = _get(case, "detail", "tm0.z2", "j", obj)
        _code(case, "positionType", "tm0.z2$b", "b", detail, "SoundPositionType")
        result.append(_feature(case, 0x42, "capability"))
    for kind, presets in [(1, list(range(16))), (2, [0, 1, 2, 3, 0x11, 0x12])]:
        enum = "VptPresetId" if kind == 1 else "SoundPositionPresetId"
        detail_class = "vm0.c1" if kind == 1 else "vm0.j0"
        for command, cls in [(0x43, "tm0.b3"), (0x45, "tm0.n1")]:
            for status in [0, 1]:
                payload = bytes([command, kind, status])
                case = _case(f"features.soundStatus.{kind}.{command}.{status}", "features.soundStatus", kind=kind, payload=payload.hex())
                obj = _parse(case, cls, payload)
                _get(case, "available", cls, "h", obj)
                result.append(_feature(case, 0x40 + kind, "parser"))
        for preset in presets:
            for command, cls in [(0x47, "tm0.a3"), (0x49, "tm0.m1")]:
                payload = bytes([command, kind, preset])
                case = _case(f"features.soundParameter.{kind}.{command}.{preset}", "features.soundParameter", kind=kind, payload=payload.hex())
                obj = _parse(case, cls, payload)
                detail = _get(case, "detail", cls, "h", obj)
                _code(case, "preset", detail_class, "e", detail, enum)
                result.append(_feature(case, 0x40 + kind, "parser"))
            case = _case(f"features.soundSet.{kind}.{preset}", "features.soundSet", kind=kind, preset=preset)
            calls = case["calls"]
            value = _call(calls, case["id"] + ":preset", PARAM + enum, "fromByteCode", ["byte"], [preset])
            detail = _call(calls, "detail", detail_class, "<init>", [PARAM + enum], [{"ref": value}])
            obj = _call(calls, "object", "tm0.t3", "<init>", ["vm0.d1"], [{"ref": detail}])
            _get(case, "payload", "tm0.t3", "d", obj)
            result.append(_feature(case, 0x40 + kind, "serializer"))
        for command, cls in [(0x43, "tm0.b3"), (0x47, "tm0.a3")]:
            payload = bytes([command, kind, 0])
            for length in range(len(payload)):
                case = _case(f"features.malformed.sound.{kind}.{command}.{length}",
                             "features.soundStatus" if command == 0x43 else "features.soundParameter",
                             kind=kind, payload=payload[:length].hex())
                _parse(case, cls, payload[:length])
                case.update(category="malformed", expected={"accepted": False})
                result.append(_feature(case, 0x40 + kind, "parser"))
    for name, payload in [("truncatedName", bytes([0x41, 1, 1, 0, 2, 65])),
                          ("invalidUTF8", bytes([0x41, 1, 1, 0, 1, 255])),
                          ("duplicatePreset", bytes([0x41, 1, 2, 0, 0, 0, 0])),
                          ("longName", bytes([0x41, 1, 1, 0, 129]) + bytes([65]) * 129),
                          ("trailingBytes", bytes([0x41, 1, 1, 0, 0, 0]))]:
        case = _case("features.malformed.soundCapability." + name, "features.soundCapability", kind=1, payload=payload.hex())
        _parse(case, "tm0.z2", payload)
        case.update(category="malformed", expected={"accepted": False})
        result.append(_feature(case, 0x41, "capability"))

    for kind in [1, 2]:
        for upscaling_type in ([0] if kind == 1 else range(3)):
            payload = bytes([0xE1, kind, 0]) if kind == 1 else bytes([0xE1, kind, upscaling_type, 0])
            case = _case(f"features.audioCapability.{kind}.{upscaling_type}", "features.audioCapability", kind=kind, payload=payload.hex())
            obj = _parse(case, "tm0.p1", payload)
            detail = _get(case, "detail", "tm0.p1", "j", obj)
            cls = "tm0.p1$c" if kind == 1 else "tm0.p1$d"
            _code(case, "settingType", cls, "b", detail, "ConnectionModeSettingType" if kind == 1 else "UpscalingSettingType")
            if kind == 2:
                _code(case, "upscalingType", cls, "c", detail, "UpscalingType")
            result.append(_feature(case, 0xE0 + kind, "capability"))
        for command, cls in [(0xE3, "tm0.s1"), (0xE5, "tm0.r0")]:
            for status in [0, 1]:
                payload = bytes([command, kind, status])
                case = _case(f"features.audioStatus.{kind}.{command}.{status}", "features.audioStatus", kind=kind, payload=payload.hex())
                obj = _parse(case, cls, payload)
                _get(case, "available", cls, "h", obj)
                result.append(_feature(case, 0xE0 + kind, "parser"))
        detail_class = "vm0.k" if kind == 1 else "vm0.z0"
        type_enum = "ConnectionModeSettingType" if kind == 1 else "UpscalingSettingType"
        value_enum = "ConnectionModeSettingValue" if kind == 1 else "UpscalingSettingValue"
        for value in [0, 1]:
            for command, cls in [(0xE7, "tm0.r1"), (0xE9, "tm0.q0")]:
                payload = bytes([command, kind, 0, value])
                case = _case(f"features.audioParameter.{kind}.{command}.{value}", "features.audioParameter", kind=kind, payload=payload.hex())
                obj = _parse(case, cls, payload)
                detail = _get(case, "detail", cls, "h", obj)
                _code(case, "mode", detail_class, "f", detail, value_enum)
                result.append(_feature(case, 0xE0 + kind, "parser"))
            case = _case(f"features.audioSet.{kind}.{value}", "features.audioSet", kind=kind, value=value)
            calls = case["calls"]
            setting = _call(calls, case["id"] + ":setting", PARAM + type_enum, "fromByteCode", ["byte"], [0])
            mode = _call(calls, "mode", PARAM + value_enum, "fromByteCode", ["byte"], [value])
            detail = _call(calls, "detail", detail_class, "<init>", [PARAM + type_enum, PARAM + value_enum], [{"ref": setting}, {"ref": mode}])
            obj = _call(calls, "object", "tm0.e3", "<init>", ["vm0.f"], [{"ref": detail}])
            _get(case, "payload", "tm0.e3", "d", obj)
            result.append(_feature(case, 0xE0 + kind, "serializer"))
    return result + legacy_optimizer.cases()


def normalize(case, results):
    if case["swift"]["op"].startswith("legacy.optimizer"):
        return legacy_optimizer.normalize(case, results)
    if case.get("category") == "malformed":
        return case["expected"]

    def value(key):
        return results[case["oracle"][key]]

    operation = case["swift"]["op"].rsplit(".", 1)[1]
    if operation == "soundCapability":
        if case["swift"]["kind"] == 2:
            return {"accepted": True, "positionType": value("positionType") & 255}
        result = {"accepted": True, "presets": [value(f"preset{index}") & 255 for index in range(value("count"))]}
        if case["swift"]["names"]:
            result["names"] = [value(f"name{index}") for index in range(value("count"))]
        return result
    if operation in ["soundStatus", "audioStatus"]:
        return {"accepted": True, "available": value("available")["name"] == "ENABLE"}
    if operation == "soundParameter":
        return {"accepted": True, "preset": value("preset") & 255}
    if operation in ["soundSet", "audioSet"]:
        return {"payload": value("payload")["bytes"]}
    if operation == "audioCapability":
        result = {"accepted": True, "settingType": value("settingType") & 255}
        if case["swift"]["kind"] == 2:
            result["upscalingType"] = value("upscalingType") & 255
        return result
    if operation == "audioParameter":
        return {"accepted": True, "mode": value("mode") & 255}
    raise ValueError(operation)


def unsupported():
    return legacy_optimizer.unsupported() + [
        {"schema": "MDRv1 VPT unknown preset identifiers", "reason": "The APK maps unknown identifiers to OFF while production preserves the raw identifier and prevents selecting it. Differential cases include every declared VPT preset."},
        {"schema": "MDRv1 sound-effect fallback display names", "reason": "Empty APK labels are localized by production UI code; these cases compare preset identifiers, while nonempty labels are compared exactly."},
    ]

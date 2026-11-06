from itertools import product

from legacy import PARAM, _call, _case, _get, _parse


APP = "com.sony.songpal.mdr.j2objc.tandem.features.ncasm."
INQUIRIES = {1: "NOISE_CANCELLING", 2: "NOISE_CANCELLING_AND_AMBIENT_SOUND_MODE", 3: "AMBIENT_SOUND_MODE"}


def _feature(case, kind, phase):
    case["coverage_ids"] = [f"mdr-v1-t1-{0x60 + kind:02x}.{phase}"]
    return case


def _enum(name, value):
    return {"enum": PARAM + name, "name": value}


def _code(case, key, cls, method, target, enum):
    value = _get(case, key + "Enum", cls, method, target)
    _get(case, key, PARAM + enum, "byteCode", value)
    return value


def _capability(payload):
    kind = payload[1]
    case = _case("noise.capability." + payload.hex(), "noise.capability", kind=kind, payload=payload.hex())
    obj = _parse(case, "tm0.d2", payload)
    detail = _get(case, "detail", "tm0.d2", "l", obj)
    if kind == 1:
        _code(case, "noiseType", "tm0.d2$e", "b", detail, "NcSettingType")
    else:
        cls = "tm0.d2$c" if kind == 2 else "tm0.d2$b"
        if kind == 2:
            nc = _code(case, "noiseType", cls, "d", detail, "NcAsmSettingType")
            _get(case, "noiseSteps", cls, "e", detail)
        asm = _code(case, "ambientType", cls, "c", detail, "AsmSettingType")
        items = _get(case, "items", cls, "b", detail)
        count = payload[5 if kind == 2 else 3]
        _get(case, "count", "java.util.List", "size", items)
        for index in range(count):
            item = _call(case["calls"], f"item{index}", "java.util.List", "get", ["int"], [index], items)
            _code(case, f"id{index}", "vm0.b", "a", item, "AsmId")
            _get(case, f"steps{index}", "vm0.b", "b", item)
        if kind == 2:
            nc_app = _call(case["calls"], "ncApp", APP + "NoiseCancellingType", "fromTypeOfNcAsm",
                           [PARAM + "NcAsmSettingType"], [{"ref": nc}])
            asm_app = _call(case["calls"], "asmApp", APP + "AmbientSoundType", "fromTypeOfTableSet1",
                            [PARAM + "AsmSettingType"], [{"ref": asm}])
            case["oracle"]["configuration"] = _call(case["calls"], "configuration", APP + "NcAsmConfigurationType", "from",
                                                     [APP + "NoiseCancellingType", APP + "AmbientSoundType"],
                                                     [{"ref": nc_app}, {"ref": asm_app}])
    return _feature(case, kind, "capability")


def _parameter(payload):
    case = _case("noise.parameter." + payload.hex(), "noise.parameter", kind=payload[1], payload=payload.hex())
    cls = "tm0.e2" if payload[0] == 0x67 else "tm0.y0"
    obj = _parse(case, cls, payload)
    _get(case, "payload", cls, "d", obj)
    return _feature(case, payload[1], "parser")


def _set(kind, name, detail_args, detail_types, **inputs):
    case = _case("noise.set." + name, "noise.set", kind=kind, **inputs)
    cls = {1: "vm0.c0", 2: "vm0.a0", 3: "vm0.c"}[kind]
    detail = _call(case["calls"], case["id"] + ":detail", cls, "<init>", detail_types, detail_args)
    obj = _call(case["calls"], "object", "tm0.i3", "<init>", ["vm0.b0"], [{"ref": detail}])
    _get(case, "payload", "tm0.i3", "d", obj)
    return _feature(case, kind, "serializer")


def cases():
    result = [_capability(bytes([0x61, 1, kind])) for kind in [0, 1]]
    for ambient_type, steps in product([0, 1], [1, 2, 20, 127, 128, 255]):
        result.append(_capability(bytes([0x61, 3, ambient_type, 2, 0, steps, 1, steps])))
        for noise_type in [0, 1, 2]:
            result.append(_capability(bytes([0x61, 2, noise_type, 3, ambient_type, 2, 0, steps, 1, steps])))
    for kind, cls in product([1, 2, 3], ["tm0.p", "tm0.r", "tm0.q"]):
        query = ["tm0.p", "tm0.r", "tm0.q"].index(cls)
        case = _case(f"noise.query.{kind}.{query}", "noise.query", kind=kind, query=query)
        obj = _call(case["calls"], case["id"] + ":object", cls, "<init>", [PARAM + "NcAsmInquiredType"],
                    [_enum("NcAsmInquiredType", INQUIRIES[kind])])
        _get(case, "payload", cls, "d", obj)
        result.append(_feature(case, kind, "serializer"))
    for kind, command, available in product([1, 2, 3], [0x63, 0x65], [0, 1]):
        payload = bytes([command, kind, available])
        case = _case("noise.status." + payload.hex(), "noise.status", kind=kind, payload=payload.hex())
        cls = "tm0.f2" if command == 0x63 else "tm0.z0"
        obj = _parse(case, cls, payload)
        _get(case, "available", cls, "h", obj)
        result.append(_feature(case, kind, "parser"))
    for command, noise_type, value in product([0x67, 0x69], [0, 1], [0, 1]):
        result.append(_parameter(bytes([command, 1, noise_type, value])))
    for command, effect, ambient_type, ambient_id, value in product([0x67, 0x69], [0, 1, 16, 17], [0, 1], [0, 1], [0, 1]):
        result.append(_parameter(bytes([command, 3, effect, ambient_type, ambient_id, value])))
    for command, effect, noise_type, ambient_type, ambient_id in product([0x67, 0x69], [0, 1, 16, 17], [0, 1, 2], [0, 1], [0, 1]):
        for value in [0, 1, 2, 127, 128, 255]:
            result.append(_parameter(bytes([command, 2, effect, noise_type, value, ambient_type, ambient_id, value if ambient_type else value % 2])))
    for enabled in [False, True]:
        for capability_type, state_type in product([0, 1], repeat=2):
            result.append(_set(1, f"nc.{capability_type}.{state_type}.{enabled}",
                               [_enum("NcSettingType", "ON_OFF"), _enum("NcSettingValue", "ON" if enabled else "OFF")],
                               [PARAM + "NcSettingType", PARAM + "NcSettingValue"],
                               capability=bytes([0x61, 1, capability_type]).hex(), state=bytes([0x67, 1, state_type, 0]).hex(), enabled=enabled))
        for voice in [False, True]:
            result.append(_set(3, f"asm.{enabled}.{voice}",
                               [_enum("NcAsmEffect", "ON" if enabled else "OFF"), _enum("AsmSettingType", "ON_OFF"),
                                _enum("AsmId", "VOICE" if voice else "NORMAL"), int(enabled)],
                               [PARAM + "NcAsmEffect", PARAM + "AsmSettingType", PARAM + "AsmId", "int"],
                               capability="6103000200020102", state="670301000001", enabled=enabled, voice=voice))
    for noise_type, ambient_type, mode, voice in product([0, 2], [0, 1], ["off", "anc", "ambient", "wind"], [False, True]):
        if noise_type == 0 and mode == "wind":
            continue
        level = 20 if ambient_type else 1
        nc = (2 if noise_type == 2 else 1) if mode == "anc" else int(mode == "wind")
        asm = level if mode in ["off", "ambient"] else 0
        result.append(_set(2, f"combined.{noise_type}.{ambient_type}.{mode}.{voice}",
                           [_enum("NcAsmEffect", "OFF" if mode == "off" else "ON"),
                            _enum("NcAsmSettingType", "DUAL_SINGLE_OFF" if noise_type == 2 else "ON_OFF"), nc,
                            _enum("AsmSettingType", "LEVEL_ADJUSTMENT" if ambient_type else "ON_OFF"),
                            _enum("AsmId", "VOICE" if voice else "NORMAL"), asm],
                           [PARAM + "NcAsmEffect", PARAM + "NcAsmSettingType", "int", PARAM + "AsmSettingType", PARAM + "AsmId", "int"],
                           capability=bytes([0x61, 2, noise_type, 3, ambient_type, 2, 0, 20, 1, 20]).hex(),
                           state=bytes([0x67, 2, 1, noise_type, 0, ambient_type, int(voice), level]).hex(),
                           mode=mode, level=level, voice=voice))
    for payload in [bytes.fromhex(value) for value in ["610100", "6103000200020102", "67010001", "690301000101"]]:
        operation = "capability" if payload[0] == 0x61 else "parameter"
        for length in range(len(payload)):
            case = _case(f"noise.malformed.{payload.hex()}.{length}", "noise." + operation, kind=payload[1], payload=payload[:length].hex())
            _parse(case, "tm0.d2" if operation == "capability" else "tm0.e2" if payload[0] == 0x67 else "tm0.y0", payload[:length])
            case.update(category="malformed", expected={"accepted": False})
            result.append(_feature(case, payload[1], "capability" if operation == "capability" else "parser"))
    return result


def normalize(case, results):
    if case.get("category") == "malformed":
        return case["expected"]

    def value(key):
        return results[case["oracle"][key]]

    kind = case["swift"]["kind"]
    operation = case["swift"]["op"].rsplit(".", 1)[1]
    if operation in ["query", "set"]:
        return {"payload": value("payload")["bytes"]}
    if operation == "parameter":
        return {"accepted": True, "payload": value("payload")["bytes"]}
    if operation == "status":
        return {"accepted": True, "available": value("available")["name"] == "ENABLE"}
    if operation == "capability":
        noise_type = value("noiseType") & 255 if kind != 3 else 0
        ambient_type = value("ambientType") & 255 if kind != 1 else 0
        supported = value("configuration")["name"] != "UNKNOWN" if kind == 2 else noise_type <= 1 and ambient_type == 0
        return {"accepted": True, "inquiry": kind, "noiseType": noise_type,
                "noiseSteps": value("noiseSteps") if kind == 2 else 0, "ambientType": ambient_type,
                "ambientSteps": sorted([[value(f"id{index}") & 255, value(f"steps{index}")]
                                        for index in range(value("count"))]) if kind != 1 else [], "supported": supported}
    raise ValueError(operation)


def unsupported():
    return [{"schema": "MDRv1 combined NC level adjustment", "reason": "The APK does not implement a combined NC LEVEL_ADJUSTMENT control: its original NcAsmConfigurationType.from returns UNKNOWN. This is not a missing Acouplet setter. Standalone NC remains binary for both declared capability types and always serializes ON_OFF, matching t30.b."},
            {"schema": "MDRv1 standalone ASM level adjustment", "reason": "The APK's standalone ASM detail-screen factory accepts ON_OFF only; LEVEL_ADJUSTMENT has no implemented level control. Acouplet preserves that wire type for inspection without enabling unsupported writes."}]

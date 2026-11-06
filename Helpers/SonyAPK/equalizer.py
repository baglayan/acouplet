from legacy import PARAM, _call, _get, _parse


MODERN = "com.sony.songpal.tandemfamily.message.mdr.v2.table1.eqebb.param."
VARIANTS = [(1, 1, 0x51), (1, 3, 0x53), (2, 0, 0x50), (2, 2, 0x52), (2, 4, 0x57)]
LEGACY_BANDS = [(16, 1)] + [(1, value) for value in [400, 1000, 2500, 6300, 16000]]
TEN_BANDS = [(1, value) for value in [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]]
FEATURE = "com.sony.songpal.mdr.j2objc.tandem.features.eq."


def _case(variant, name, operation, phase, **inputs):
    generation, inquiry, function = variant
    identifier = f"equalizer.v{generation}.{inquiry}.{name}"
    return {"id": identifier, "swift": {"op": "equalizer." + operation, "generation": generation,
            "function": function, **inputs}, "calls": [], "oracle": {},
            "coverage_ids": [f"mdr-v{generation}-t1-{function:02x}.{phase}"]}


def _modern_parse(case, owner, payload, method="f"):
    builder = _call(case["calls"], case["id"] + ":builder", owner + "$b", "<init>")
    return _call(case["calls"], "object", owner + "$b", method, ["byte[]"], [{"bytes": payload.hex()}], builder)


def _code(case, key, owner, method, target, enum):
    value = _get(case, key + "Enum", owner, method, target)
    return _get(case, key, enum, "byteCode", value)


def _capability(variant, bands, steps, records, ult=None):
    payload = bytes([0x51, variant[1], bands, steps])
    if ult is not None:
        payload += bytes([ult])
    payload += bytes([len(records)])
    for preset, name in records:
        encoded = name.encode()
        payload += bytes([preset, len(encoded)]) + encoded
    return payload


def _bands(inquiry, bands):
    return bytes([0x5B, inquiry, len(bands)]) + b"".join(bytes([kind]) + value.to_bytes(2, "big") for kind, value in bands)


def _setup(variant, bands, steps):
    inquiry = variant[1]
    return [list(_capability(variant, len(bands), steps, [(0, ""), (0xA0, ""), (0xA1, "")])),
            list(_bands(inquiry, bands)), [0x53, inquiry, 0] + ([0] if inquiry == 4 else []),
            [0x57, inquiry, 0xA0, len(bands)] + [(steps - 1) // 2] * len(bands)]


def cases():
    result = []
    for variant in VARIANTS + [(2, 3, 0x53)]:
        generation, inquiry, function = variant
        param = PARAM if generation == 1 else MODERN
        for count, steps, records in [(6, 21, [(0, ""), (0xA0, "Manual"), (0xA1, "日本語")]),
                                       (10, 41, [(0xA2, "n" * 128)]), (0, 1, [])]:
            payload = _capability(variant, count, steps, records, 4 if generation == 2 and inquiry == 3 else None)
            case = _case(variant, f"capability.{count}", "capability", "capability", payload=payload.hex())
            if generation == 1:
                obj = _parse(case, "tm0.z1", payload)
                obj = _get(case, "detail", "tm0.z1", "j", obj)
                owner, methods, item_owner, item_methods = "tm0.z1$c", ("b", "d", "c"), "vm0.t", ("b", "a")
            else:
                owner = "jn0.a0" if inquiry == 3 else "jn0.z"
                obj = _modern_parse(case, owner, payload)
                methods, item_owner, item_methods = ("e", "g", "f"), "kn0.e", ("g", "f")
                if inquiry == 3:
                    _get(case, "ultAdditionalSteps", owner, "h", obj)
            _get(case, "bandCount", owner, methods[0], obj)
            _get(case, "levelSteps", owner, methods[1], obj)
            items = _get(case, "items", owner, methods[2], obj)
            _get(case, "count", "java.util.List", "size", items)
            for index in range(len(records)):
                item = _call(case["calls"], f"item{index}", "java.util.List", "get", ["int"], [index], items)
                _code(case, f"preset{index}", item_owner, item_methods[0], item, param + "EqPresetId")
                _get(case, f"name{index}", item_owner, item_methods[1], item)
            result.append(case)
        if generation == 2 and inquiry == 3:
            continue
        for bands in [LEGACY_BANDS] + ([TEN_BANDS] if generation == 2 else []):
            payload = _bands(inquiry, bands)
            case = _case(variant, f"bands.{len(bands)}", "bands", "capability", payload=payload.hex())
            if generation == 1:
                obj = _parse(case, "tm0.a2", payload)
                detail = _get(case, "detail", "tm0.a2", "h", obj)
                items = _get(case, "items", "vm0.r", "e", detail)
                owner, methods = "vm0.o", ("a", "b")
            else:
                obj = _modern_parse(case, "jn0.e0", payload, "g")
                items = _get(case, "items", "jn0.e0", "e", obj)
                owner, methods = "kn0.b", ("c", "f")
            _get(case, "count", "java.util.List", "size", items)
            for index in range(len(bands)):
                item = _call(case["calls"], f"item{index}", "java.util.List", "get", ["int"], [index], items)
                _code(case, f"type{index}", owner, methods[0], item, param + "EqBandInformationType")
                _get(case, f"value{index}", owner, methods[1], item)
            result.append(case)
        for status in [0, 1]:
            errors = [0, 1, 2, 254] if inquiry == 4 else []
            payload = bytes([0x53, inquiry, status] + ([len(errors)] + errors if inquiry == 4 else []))
            case = _case(variant, f"status.{status}", "status", "parser", payload=payload.hex())
            if generation == 1:
                obj = _parse(case, "tm0.c2", payload)
                _get(case, "available", "tm0.c2", "h", obj)
            else:
                obj = _modern_parse(case, "jn0.o0", payload, "e")
                _get(case, "available", "jn0.p0" if inquiry == 4 else "jn0.n0", "g" if inquiry == 4 else "e", obj)
                if inquiry == 4:
                    _get(case, "errors", "jn0.p0", "e", obj)
            result.append(case)
        for preset in [0, 0x10, 0xA0, 0xA1, 0xA2]:
            for values in [[], [0, 1, 10, 19, 20, 7]]:
                payload = bytes([0x57, inquiry, preset, len(values)] + values)
                case = _case(variant, f"parameter.{preset}.{len(values)}", "parameter", "parser", payload=payload.hex())
                if generation == 1:
                    obj = _parse(case, "tm0.b2", payload)
                    detail = _get(case, "detail", "tm0.b2", "h", obj)
                    owner, methods = "vm0.s", ("f", "e")
                else:
                    obj = _modern_parse(case, "jn0.j0", payload)
                    detail = _get(case, "detail", "jn0.j0", "g", obj)
                    owner, methods = "kn0.c", ("e", "c")
                _code(case, "preset", owner, methods[0], detail, param + "EqPresetId")
                _get(case, "values", owner, methods[1], detail)
                result.append(case)
        for preset in [0, 0xA0, 0xA1]:
            result.append(_setter(variant, f"presetSet.{preset}", preset, [], LEGACY_BANDS, 21))
        if (generation == 1 and inquiry == 1) or (generation == 2 and inquiry != 2):
            for bands in [LEGACY_BANDS] + ([TEN_BANDS] if generation == 2 else []):
                for level in [0, 10, 20]:
                    result.append(_setter(variant, f"settingsSet.{len(bands)}.{level}", 255 if generation == 1 else 0xA0,
                                          [level] * len(bands), bands, 21))
            for name, bands, steps, values, count in [
                ("partialClearBass", [(2, 3), (16, 1), (1, 80)], 12, [0, 11, 5], 1),
                ("unlabelledRepeated", [(1, 0), (1, 1750), (1, 1750), (0, 0), (0x7F, 0xBEEF)], 255, [0, 127, 128, 254, 1], 5),
                ("wide", [(1, 40 + index * 150) for index in range(16)], 12, [0, 11, 5, 8] * 4, 16),
            ]:
                result.append(_layout(variant, name, bands, steps, values, count))
    return result


def _setter(variant, name, preset, values, bands, steps):
    generation, inquiry, function = variant
    param = PARAM if generation == 1 else MODERN
    case = _case(variant, name, "settingsSet" if values else "presetSet", "serializer", preset=preset,
                 values=[value - (steps - 1) // 2 for value in values], setup=_setup(variant, bands, steps))
    calls = case["calls"]
    kind = _call(calls, case["id"] + ":kind", param + "EqEbbInquiredType", "fromByteCode", ["byte"], [inquiry])
    selected = _call(calls, "preset", param + "EqPresetId", "fromByteCode", ["byte"], [preset])
    if generation == 1:
        detail = _call(calls, "detail", "vm0.s", "<init>", [param + "EqEbbInquiredType", param + "EqPresetId", "int[]"],
                       [{"ref": kind}, {"ref": selected}, values])
        obj = _call(calls, "object", "tm0.f3", "<init>", ["vm0.q"], [{"ref": detail}])
        owner = "tm0.f3"
    else:
        builder = _call(calls, "detailBuilder", "kn0.c$a", "<init>")
        detail = _call(calls, "detail", "kn0.c$a", "c", [param + "EqPresetId", "int[]"], [{"ref": selected}, values], builder)
        builder = _call(calls, "builder", "jn0.x0$b", "<init>")
        obj = _call(calls, "object", "jn0.x0$b", "h", [param + "EqEbbInquiredType", "kn0.c"], [{"ref": kind}, {"ref": detail}], builder)
        owner = "jn0.x0"
    _get(case, "payload", owner, "d", obj)
    return case


def _layout(variant, name, bands, steps, values, count):
    generation, inquiry, function = variant
    param = PARAM if generation == 1 else MODERN
    case = _setter(variant, "layout." + name, 255 if generation == 1 else 0xA0, values, bands, steps)
    case["swift"]["op"] = "equalizer.layout"
    case["swift"]["setup"][0][2] = count
    case["swift"]["setup"][-1][4:] = values
    calls = case["calls"]
    payload = _bands(inquiry, bands)
    if generation == 1:
        obj = _call(calls, "bandObject", "tm0.a2", "<init>")
        _call(calls, "bandParse", "tm0.a2", "g", ["byte[]"], [{"bytes": payload.hex()}], obj)
        detail = _call(calls, "bandDetail", "tm0.a2", "h", target=obj)
        items = _call(calls, "bandItems", "vm0.r", "e", target=detail)
        owner, methods = "vm0.o", ("a", "b", "c")
    else:
        builder = _call(calls, "bandBuilder", "jn0.e0$b", "<init>")
        obj = _call(calls, "bandObject", "jn0.e0$b", "g", ["byte[]"], [{"bytes": payload.hex()}], builder)
        items = _call(calls, "bandItems", "jn0.e0", "e", target=obj)
        owner, methods = "kn0.b", ("c", "f", "g")
    metadata = []
    for index in range(len(bands)):
        item = _call(calls, f"band{index}", "java.util.List", "get", ["int"], [index], items)
        kind = _call(calls, f"bandType{index}", owner, methods[0], target=item)
        value = _call(calls, f"bandValue{index}", owner, methods[1], target=item)
        specific = _call(calls, f"bandSpecific{index}", owner, methods[2], target=item)
        mapped = _call(calls, f"mappedType{index}", FEATURE + "EqBandInformationType", f"fromEqBandInformationTableSet{generation}",
                       [param + "EqBandInformationType", param + "SpecificInformationType"], [{"ref": kind}, {"ref": specific}])
        case["oracle"][f"bandValue{index}"] = value
        case["oracle"][f"mappedType{index}"] = mapped
        metadata.append({"ref": _call(calls, f"metadata{index}", FEATURE + "a", "<init>",
                                     [FEATURE + "EqBandInformationType", "int"], [{"ref": mapped}, {"ref": value}])})
    model = _call(calls, "model", FEATURE + "b", "<init>", ["boolean", FEATURE + "EqPresetId", "int[]", "java.util.List"],
                  [True, {"enum": FEATURE + "EqPresetId", "name": "CUSTOM"}, values, metadata])
    metadata = _call(calls, "modelMetadata", FEATURE + "b", "d", target=model)
    _get(case, "bandCount", "java.util.List", "size", metadata)
    _get(case, "rawValues", FEATURE + "b", "f", model)
    _get(case, "clearBassIndex", FEATURE + "b", "i", model)
    capability = _call(calls, "levelCapability", "com.sony.songpal.mdr.j2objc.devicecapability.tableset1.e", "<init>",
                       ["int", "int", "java.util.List", "boolean"], [count, steps, [], True])
    converter = _call(calls, "levelConverter", "h20.c", "<init>",
                      ["com.sony.songpal.mdr.j2objc.devicecapability.tableset1.e", "om0.e", "lq.d"], [{"ref": capability}, None, None])
    for key, raw in [("lowerBound", 0), ("upperBound", steps - 1)] + [(f"level{index}", value) for index, value in enumerate(values)]:
        case["oracle"][key] = _call(calls, key, "h20.c", "m", ["int"], [raw], converter)
    return case


def normalize(case, results):
    def value(key):
        return results[case["oracle"][key]]

    operation = case["swift"]["op"].split(".")[-1]
    if operation.endswith("Set"):
        return {"payload": value("payload")["bytes"]}
    if operation == "layout":
        return {"payload": value("payload")["bytes"], "bandCount": value("bandCount"),
                "bands": [{"type": value(f"mappedType{index}")["name"], "value": value(f"bandValue{index}")}
                          for index in range(value("bandCount"))],
                "rawValues": value("rawValues"), "clearBassIndex": value("clearBassIndex"),
                "values": [value(f"level{index}") for index in range(value("bandCount"))],
                "range": [value("lowerBound"), value("upperBound")]}
    if operation == "capability":
        return {"accepted": True, "bandCount": value("bandCount"), "levelSteps": value("levelSteps"),
                "ultAdditionalSteps": value("ultAdditionalSteps") if "ultAdditionalSteps" in case["oracle"] else None,
                "presets": [{"id": value(f"preset{i}") & 255, "name": value(f"name{i}") or None} for i in range(value("count"))]}
    if operation == "bands":
        return {"accepted": True, "bands": [{"type": value(f"type{i}") & 255, "value": value(f"value{i}")} for i in range(value("count"))]}
    if operation == "status":
        codes = {"CALLING": 0, "DEMO_MODE": 1, "LISTENING_MODE": 2, "OTHER": 254}
        return {"accepted": True, "available": value("available")["name"] == "ENABLE",
                "errors": [codes[item["name"]] for item in value("errors")] if "errors" in case["oracle"] else None}
    if operation == "parameter":
        return {"accepted": True, "preset": value("preset") & 255, "values": value("values") or None}
    raise ValueError(operation)


def unsupported():
    return [{"schema": "Equalizer extensions outside existing preset EQ support", "reason": "These checks cover existing MDRv1 preset EQ and MDRv2 ordinary preset EQ, error status, and ULT capability parsing only. ULT setters, custom-EQ extensions, sound-effect extensions, controller and UI behavior are not exercised."}]


def mutations():
    return [
        {"name": "equalizer capability level-step field", "replacement": (
            "SonyEqualizer.swift", "levelSteps = payload[3]", "levelSteps = payload[2]"),
         "case_ids": [case["id"] for case in cases() if case["swift"]["op"] == "equalizer.capability"]},
        {"name": "legacy equalizer manual-write preset", "replacement": (
            "SonyEqualizer.swift", "generation == .v1 ? 0xFF : EqualizerPreset.manual.rawValue, UInt8(settings.values.count)",
            "generation == .v1 ? 0xA0 : EqualizerPreset.manual.rawValue, UInt8(settings.values.count)"),
         "case_ids": [case["id"] for case in cases() if case["swift"]["op"] == "equalizer.settingsSet" and case["swift"]["generation"] == 1]},
        {"name": "even-step equalizer center offset", "replacement": (
            "SonyEqualizer.swift", "let center = (Int(settings.levelSteps) - 1) / 2", "let center = range.upperBound"),
         "case_ids": [case["id"] for case in cases() if case["swift"]["op"] == "equalizer.layout"]},
    ]

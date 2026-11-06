from itertools import product

from legacy import PARAM, _call, _case, _get, _parse


FEATURES = [(0x13, "CODEC_INDICATOR", "codec", "tm0.c"),
            (0x12, "UPSCALING_INDICATOR", "upscaling", "tm0.k0"),
            (0x17, "LEFT_RIGHT_CONNECTION_STATUS", "connection", "tm0.j")]


def _coverage(case, feature, stage):
    case["coverage_ids"] = [f"mdr-v1-t1-{feature:02X}.{stage}"]
    return case


def _enum(case, key, cls, method, target, enum):
    value = _get(case, key, cls, method, target)
    _get(case, key + "Code", PARAM + enum, "byteCode", value)


def _codec(identifier, payload):
    case = _case("indicators.codec." + identifier, "indicatorsCodec", payload=payload.hex())
    cls = "tm0.q1" if payload[0] == 0x19 else "tm0.p0"
    obj = _parse(case, cls, payload)
    _enum(case, "codec", cls, "h", obj, "AudioCodec")
    return _coverage(case, 0x13, "parser")


def _upscaling(identifier, payload):
    case = _case("indicators.upscaling." + identifier, "indicatorsUpscaling", payload=payload.hex())
    cls = "tm0.y2" if payload[0] == 0x15 else "tm0.l1"
    obj = _parse(case, cls, payload)
    _enum(case, "type", cls, "i", obj, "UpscalingEffectType")
    _enum(case, "status", cls, "h", obj, "UpscalingEffectStatus")
    return _coverage(case, 0x12, "parser")


def _connection(identifier, payload):
    case = _case("indicators.connection." + identifier, "indicatorsConnection", payload=payload.hex())
    cls = "tm0.x1" if payload[0] == 0x25 else "tm0.t0"
    obj = _parse(case, cls, payload)
    detail = _get(case, "detail", cls, "h", obj)
    _enum(case, "left", "vm0.y", "e", detail, "ConnectionStatus")
    _enum(case, "right", "vm0.y", "f", detail, "ConnectionStatus")
    return _coverage(case, 0x17, "parser")


def _boundary(case, expected):
    case.update(category="malformed", expected=expected)
    return case


def cases():
    result = []
    for mask in range(8):
        functions = [feature for index, (feature, _, _, _) in enumerate(FEATURES) if mask & (1 << index)]
        functions += [0x11, 0x14, 0x18, 0xFE]
        case = _case(f"indicators.queries.{mask}", "indicatorsQueries", functions=functions)
        case["coverage_ids"] = [f"mdr-v1-t1-{feature:02X}.{stage}"
                                for feature, _, _, _ in FEATURES for stage in ["capability", "serializer"]]
        for index, function in enumerate(functions):
            case["oracle"][f"function{index}"] = _call(
                case["calls"], case["id"] + ":function0" if index == 0 else f"function{index}",
                PARAM + "FunctionType", "fromByteCode", ["byte"], [function])
        for _, _, key, cls in FEATURES:
            types = [PARAM + "ConnectionStatusInquiredType"] if key == "connection" else []
            arguments = [{"enum": types[0], "name": "LEFT_RIGHT_CONNECTION_STATUS"}] if types else []
            obj = _call(case["calls"], key + "Query", cls, "<init>", types, arguments)
            _get(case, key + "QueryPayload", cls, "d", obj)
        result.append(case)

    for command, codec in product([0x19, 0x1B], [0, 1, 2, 0x10, 0x20, 0x21, 255]):
        payload = bytes([command, 0, codec])
        result.append(_codec(payload.hex(), payload))
    for command, effect, status in product([0x15, 0x17], range(3), range(3)):
        payload = bytes([command, 0, effect, status])
        result.append(_upscaling(payload.hex(), payload))
    for command, left, right in product([0x25, 0x27], range(2), range(2)):
        payload = bytes([command, 1, left, right])
        result.append(_connection(payload.hex(), payload))

    for command, codec in product([0x19, 0x1B], [3, 0x30, 127, 128, 254]):
        payload = bytes([command, 0, codec])
        result.append(_boundary(_codec("unknown." + payload.hex(), payload),
                                {"accepted": True, "codecValue": codec, "codec": "UNKNOWN"}))
    for command, index, value in product([0x15, 0x17], [2, 3], [3, 127, 128, 254, 255]):
        payload = bytearray([command, 0, 2, 1])
        payload[index] = value
        result.append(_boundary(_upscaling("unknown." + payload.hex(), payload),
                                {"accepted": True, "typeValue": payload[2], "statusValue": payload[3],
                                 "type": None if index == 2 else 2, "status": None if index == 3 else 1}))
    for command, index, value in product([0x25, 0x27], [2, 3], [2, 127, 128, 254, 255]):
        payload = bytearray([command, 1, 1, 0])
        payload[index] = value
        result.append(_boundary(_connection("unknown." + payload.hex(), payload),
                                {"accepted": True, "leftValue": payload[2], "rightValue": payload[3],
                                 "leftConnected": None if index == 2 else True,
                                 "rightConnected": None if index == 3 else False}))

    for feature, operation, payload, cls in [
            (0x13, "indicatorsCodec", bytes([0x19, 0, 0x10]), "tm0.q1"),
            (0x13, "indicatorsCodec", bytes([0x1B, 0, 0x10]), "tm0.p0"),
            (0x12, "indicatorsUpscaling", bytes([0x15, 0, 2, 1]), "tm0.y2"),
            (0x12, "indicatorsUpscaling", bytes([0x17, 0, 2, 1]), "tm0.l1"),
            (0x17, "indicatorsConnection", bytes([0x25, 1, 1, 0]), "tm0.x1"),
            (0x17, "indicatorsConnection", bytes([0x27, 1, 1, 0]), "tm0.t0")]:
        invalid = [("prefix." + str(length), payload[:length]) for length in range(len(payload))]
        invalid += [("trailing", payload + bytes([0]))]
        invalid += [("inquired." + str(value), payload[:1] + bytes([value]) + payload[2:])
                    for value in [0, 1, 2, 255] if value != payload[1]]
        invalid += [("command", bytes([0xFF]) + payload[1:])]
        for name, invalid_payload in invalid:
            case = _case(f"indicators.malformed.{payload[0]}.{name}", operation, payload=invalid_payload.hex())
            _parse(case, cls, invalid_payload)
            result.append(_coverage(_boundary(case, {"accepted": False}), feature, "parser"))
        for key, value in [("functions", []), ("frameType", 0x0E), ("frameType", 0x1C), ("frameType", 0x2C)]:
            case = _case(f"indicators.malformed.{payload[0]}.{key}.{value}", operation,
                         payload=payload.hex(), **{key: value})
            _parse(case, cls, payload)
            result.append(_coverage(_boundary(case, {"accepted": False}), feature, "parser"))
    return result


def normalize(case, results):
    if case.get("category") == "malformed":
        return case["expected"]

    def value(key):
        return results[case["oracle"][key]]

    operation = case["swift"]["op"]
    if operation == "legacy.indicatorsQueries":
        functions = {value(f"function{index}")["name"] for index in range(len(case["swift"]["functions"]))}
        return {**{key: name in functions for _, name, key, _ in FEATURES},
                "payloads": [value(key + "QueryPayload")["bytes"] for _, name, key, _ in FEATURES if name in functions]}
    if operation == "legacy.indicatorsCodec":
        return {"accepted": True, "codecValue": value("codecCode") & 255, "codec": value("codec")["name"]}
    if operation == "legacy.indicatorsUpscaling":
        return {"accepted": True, "typeValue": value("typeCode") & 255, "statusValue": value("statusCode") & 255,
                "type": value("typeCode") & 255, "status": value("statusCode") & 255}
    if operation == "legacy.indicatorsConnection":
        return {"accepted": True, "leftValue": value("leftCode") & 255, "rightValue": value("rightCode") & 255,
                "leftConnected": value("left")["name"] == "CONNECTED", "rightConnected": value("right")["name"] == "CONNECTED"}
    raise ValueError(operation)


def mutations():
    return [
        {"name": "legacy codec query corruption",
         "replacement": ("SonyLegacyIndicators.swift", "[[0x18, 0]]", "[[0x14, 0]]"),
         "case_ids": ["legacy.indicators.queries.7"]},
        {"name": "legacy upscaling status replaced by effect type",
         "replacement": ("SonyLegacyIndicators.swift", "upscalingStatusValue = payload[3]", "upscalingStatusValue = payload[2]"),
         "case_ids": ["legacy.indicators.upscaling.15000201"]},
        {"name": "legacy left status replaced by right status",
         "replacement": ("SonyLegacyIndicators.swift", "leftConnectionValue = payload[2]", "leftConnectionValue = payload[3]"),
         "case_ids": ["legacy.indicators.connection.25010100"]},
    ]


def unsupported():
    return [{"schema": "MDRv1 indicator unknown enum semantics",
             "reason": "The APK maps unknown values to UNSETTLED, DSEE_HX, OFF or NOT_CONNECTED. Production preserves raw values and reports unknown. These cases are explicit boundary checks, not differential passes."},
            {"schema": "MDRv1 indicator controller and user interface",
             "reason": "This APK module independently checks protocol models. The controller ownership tests and Settings/Preferences routes provide separate application evidence; this module does not establish hardware behavior."}]

from itertools import product

from legacy import PARAM, _call, _case, _get, _parse


def _capability_case(identifier, payload):
    case = _case("optimizer.capability." + identifier, "optimizerCapability", payload=payload.hex())
    case["coverage_ids"] = ["mdr-v1-t1-81.capability"]
    obj = _parse(case, "tm0.g2", payload)
    for key, method in [("optimizationSeconds", "j"), ("personalSeconds", "k"), ("pressureSeconds", "h")]:
        _get(case, key, "tm0.g2", method, obj)
    for key, method, enum in [("personalType", "l", "PersonalMeasureType"), ("pressureType", "i", "BarometricMeasureType")]:
        value = _get(case, key, "tm0.g2", method, obj)
        _get(case, key + "Code", PARAM + enum, "byteCode", value)
    return case


def _status_case(identifier, payload):
    case = _case("optimizer.status." + identifier, "optimizerStatus", payload=payload.hex())
    case["coverage_ids"] = ["mdr-v1-t1-81.parser"]
    cls = "tm0.i2" if payload[0] == 0x83 else "tm0.b1"
    obj = _parse(case, cls, payload)
    availability = _get(case, "availability", cls, "i", obj)
    _get(case, "availabilityCode", "com.sony.songpal.tandemfamily.mdr.param.CommonStatus", "byteCode", availability)
    phase = _get(case, "phase", cls, "h", obj)
    _get(case, "phaseCode", PARAM + "OptimizerStatus", "byteCode", phase)
    return case


def _measurements_case(identifier, payload):
    capability = bytes([0x81, 1, 5, payload[2], 3, payload[4], 4])
    case = _case("optimizer.measurements." + identifier, "optimizerMeasurements",
                 payload=payload.hex(), capability=capability.hex())
    case["coverage_ids"] = ["mdr-v1-t1-81.parser"]
    cls = "tm0.h2" if payload[0] == 0x87 else "tm0.a1"
    obj = _parse(case, cls, payload)
    for key, method in [("personalValue", "k"), ("pressureValue", "i")]:
        _get(case, key, cls, method, obj)
    for key, method, enum in [("personalType", "j", "PersonalMeasureType"), ("pressureType", "h", "BarometricMeasureType")]:
        value = _get(case, key, cls, method, obj)
        _get(case, key + "Code", PARAM + enum, "byteCode", value)
    case["oracle"]["personalSemantic"] = _call(case["calls"], "personalSemantic", PARAM + "PersonalValue",
                                               "fromByteCode", ["byte"], [payload[3]])
    pressure = _call(case["calls"], "pressureSemantic", PARAM + "BarometricPressureValue",
                     "fromByteCode", ["byte"], [payload[5]])
    if payload[5] in [7, 8, 9, 10]:
        _get(case, "pressureAtmospheres", PARAM + "BarometricPressureValue", "toFloat", pressure)
    return case


def _boundary(case, expected):
    case["category"] = "malformed"
    case["expected"] = expected
    return case


def cases():
    result = []
    boundaries = [0, 1, 127, 128, 254, 255]
    timings = {(5, 3, 4)}
    for index, value in product(range(3), boundaries):
        values = [5, 3, 4]
        values[index] = value
        timings.add(tuple(values))
    for personal_type, pressure_type in product(range(2), repeat=2):
        for optimization, personal, pressure in sorted(timings):
            payload = bytes([0x81, 1, optimization, personal_type, personal, pressure_type, pressure])
            result.append(_capability_case(payload.hex(), payload))

    for command, availability, phase in product([0x83, 0x85], range(2), [0, 1, 2, 16, 17]):
        payload = bytes([command, 1, availability, phase])
        result.append(_status_case(payload.hex(), payload))

    for command, personal_type, pressure_type, personal_value, pressure_value in product(
            [0x87, 0x89], range(2), range(2), range(2), [0, 7, 8, 9, 10]):
        payload = bytes([command, 1, personal_type, personal_value, pressure_type, pressure_value])
        result.append(_measurements_case(payload.hex(), payload))

    for control in ["START", "CANCEL"]:
        case = _case("optimizer.set." + control, "optimizerSet", control=control)
        case["coverage_ids"] = ["mdr-v1-t1-81.serializer"]
        obj = _call(case["calls"], case["id"] + ":object", "tm0.j3", "<init>",
                    [PARAM + "OptimizerInquiredType", PARAM + "OptimizerControl"],
                    [{"enum": PARAM + "OptimizerInquiredType", "name": "NC_OPTIMIZER"},
                     {"enum": PARAM + "OptimizerControl", "name": control}])
        _get(case, "payload", "tm0.j3", "d", obj)
        result.append(case)

    for query, cls in [("status", "tm0.u"), ("measurements", "tm0.t")]:
        case = _case("optimizer.query." + query, "optimizerQuery", query=query)
        case["coverage_ids"] = ["mdr-v1-t1-81.serializer"]
        obj = _call(case["calls"], case["id"] + ":object", cls, "<init>",
                    [PARAM + "OptimizerInquiredType"], [{"enum": PARAM + "OptimizerInquiredType", "name": "NC_OPTIMIZER"}])
        _get(case, "payload", cls, "d", obj)
        result.append(case)

    for command, personal_type, pressure_type in product([0x87, 0x89], range(2), range(2)):
        for value in [2, 127, 128, 254, 255]:
            payload = bytes([command, 1, personal_type, value, pressure_type, 10])
            case = _measurements_case("unknownPersonal." + payload.hex(), payload)
            result.append(_boundary(case, {"accepted": True, "personalType": personal_type, "personalValue": value,
                                           "pressureType": pressure_type, "pressureValue": 10, "personalMeasured": None,
                                           "pressureAtmospheres": 1.0 if pressure_type else None}))
        for value in [1, 6, 11, 127, 128, 254, 255]:
            payload = bytes([command, 1, personal_type, 1, pressure_type, value])
            case = _measurements_case("unknownPressure." + payload.hex(), payload)
            result.append(_boundary(case, {"accepted": True, "personalType": personal_type, "personalValue": 1,
                                           "pressureType": pressure_type, "pressureValue": value,
                                           "personalMeasured": True if personal_type else None, "pressureAtmospheres": None}))

    for command in [0x83, 0x85]:
        for value in [2, 127, 128, 254, 255]:
            payload = bytes([command, 1, value, 0])
            case = _status_case("unknownAvailability." + payload.hex(), payload)
            result.append(_boundary(case, {"accepted": True, "availability": value, "available": None,
                                           "phaseValue": 0, "phase": 0, "active": False, "canStart": False}))
        for value in [3, 15, 18, 127, 128, 254, 255]:
            payload = bytes([command, 1, 0, value])
            case = _status_case("unknownPhase." + payload.hex(), payload)
            result.append(_boundary(case, {"accepted": True, "availability": 0, "available": True,
                                           "phaseValue": value, "phase": None, "active": None, "canStart": False}))

    for index, value in product([3, 5], [2, 127, 128, 254, 255]):
        payload = bytearray([0x81, 1, 5, 1, 3, 1, 4])
        payload[index] = value
        case = _capability_case("unknownType." + payload.hex(), payload)
        result.append(_boundary(case, {"accepted": True, "optimizationSeconds": 5, "personalType": payload[3],
                                       "personalSeconds": 3, "pressureType": payload[5], "pressureSeconds": 4,
                                       "recognized": False}))

    for operation, payload, cls in [("optimizerCapability", bytes([0x81, 1, 5, 1, 3, 1, 4]), "tm0.g2"),
                                    ("optimizerStatus", bytes([0x83, 1, 0, 0]), "tm0.i2"),
                                    ("optimizerStatus", bytes([0x85, 1, 0, 0]), "tm0.b1"),
                                    ("optimizerMeasurements", bytes([0x87, 1, 1, 1, 1, 10]), "tm0.h2"),
                                    ("optimizerMeasurements", bytes([0x89, 1, 1, 1, 1, 10]), "tm0.a1")]:
        invalid = [("prefix." + str(length), payload[:length]) for length in range(len(payload))]
        invalid += [("trailing", payload + bytes([0]))]
        invalid += [("inquired." + str(value), payload[:1] + bytes([value]) + payload[2:]) for value in [0, 2, 255]]
        for name, invalid_payload in invalid:
            case = _case(f"optimizer.malformed.{payload[0]}.{name}", operation, payload=invalid_payload.hex(),
                         capability="81010501030104")
            case["coverage_ids"] = ["mdr-v1-t1-81.capability" if operation == "optimizerCapability" else "mdr-v1-t1-81.parser"]
            _parse(case, cls, invalid_payload)
            result.append(_boundary(case, {"accepted": False}))
        for key, value in [("supported", False), ("frameType", 0x0E)]:
            case = _case(f"optimizer.malformed.{payload[0]}.{key}", operation, payload=payload.hex(),
                         capability="81010501030104", **{key: value})
            case["coverage_ids"] = ["mdr-v1-t1-81.capability" if operation == "optimizerCapability" else "mdr-v1-t1-81.parser"]
            _parse(case, cls, payload)
            result.append(_boundary(case, {"accepted": False}))
    for command, capability in product([0x87, 0x89], ["", "81010500030104", "81010501030004"]):
        payload = bytes([command, 1, 1, 1, 1, 10])
        case = _measurements_case("capabilityMismatch." + payload.hex() + "." + capability, payload)
        case["swift"]["capability"] = capability
        result.append(_boundary(case, {"accepted": False}))
    return result


def normalize(case, results):
    if case.get("category") == "malformed":
        return case["expected"]

    def value(key):
        return results[case["oracle"][key]]

    operation = case["swift"]["op"]
    if operation in ["legacy.optimizerSet", "legacy.optimizerQuery"]:
        return {"payload": value("payload")["bytes"]}
    if operation == "legacy.optimizerCapability":
        return {"accepted": True, "optimizationSeconds": value("optimizationSeconds"),
                "personalType": value("personalTypeCode") & 255, "personalSeconds": value("personalSeconds"),
                "pressureType": value("pressureTypeCode") & 255, "pressureSeconds": value("pressureSeconds"),
                "recognized": value("personalType")["name"] != "OUT_OF_RANGE" and value("pressureType")["name"] != "OUT_OF_RANGE"}
    if operation == "legacy.optimizerStatus":
        available = value("availability")["name"] == "ENABLE"
        phase = value("phaseCode")
        return {"accepted": True, "availability": value("availabilityCode") & 255, "available": available,
                "phaseValue": phase, "phase": phase, "active": phase in [1, 2, 16],
                "canStart": available and phase in [0, 17]}
    if operation == "legacy.optimizerMeasurements":
        personal = value("personalType")["name"] == "PERSONAL"
        pressure = value("pressureType")["name"] == "BAROMETRIC_PRESSURE"
        return {"accepted": True, "personalType": value("personalTypeCode") & 255,
                "personalValue": value("personalValue"), "pressureType": value("pressureTypeCode") & 255,
                "pressureValue": value("pressureValue"),
                "personalMeasured": value("personalSemantic")["name"] == "MEASURED" if personal else None,
                "pressureAtmospheres": round(value("pressureAtmospheres"), 1) if pressure and "pressureAtmospheres" in case["oracle"] else None}
    raise ValueError(operation)


def unsupported():
    return [{"schema": "MDRv1 NC music optimizer (inquired type 2)",
             "reason": "The production model implements NC_OPTIMIZER (type 1); the other APK optimizer variant is checked only for rejection."},
            {"schema": "MDRv1 optimizer unknown enum semantics",
             "reason": "The APK substitutes IDLE or OUT_OF_RANGE for unknown values while the production model preserves raw values and exposes unknown state. These safety boundaries are reported separately from differential passes."}]

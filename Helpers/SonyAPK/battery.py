from legacy import PARAM, _call, _get, _parse


POWER = "com.sony.songpal.tandemfamily.message.mdr.v2.table1.power.param."
CHARGING = "com.sony.songpal.mdr.j2objc.tandem.features.battery.ChargingStatus"
KMP_CHARGING = "com.sony.songpal.mdr.kmp.tandem.command.v2.table1.power.ProtocolBatteryChargingStatus"
MODERN_CLASSES = {
    0x23: {0: "yn0.j0", 1: "yn0.q0", 2: "yn0.o0", 8: "yn0.l0", 9: "yn0.s0", 10: "yn0.p0"},
    0x25: {0: "yn0.l", 1: "yn0.s", 2: "yn0.q", 8: "yn0.n", 9: "yn0.u", 10: "yn0.r"},
}


def _case(generation, payload):
    return {"id": f"battery.{generation}.{payload.hex()}",
            "swift": {"op": "battery." + generation, "payload": payload.hex()},
            "calls": [], "oracle": {}}


def _legacy_case(payload):
    case = _case("legacy", payload)
    inquiry = payload[1]
    cls = "tm0.t1" if payload[0] == 0x11 else "tm0.s0"
    obj = _parse(case, cls, payload)
    detail = _get(case, "detail", cls, "h", obj)
    detail_class = ["vm0.h", "vm0.x", "vm0.m"][inquiry]
    parts = [("left", "f", "e"), ("right", "h", "g")] if inquiry == 1 else [
        ("single" if inquiry == 0 else "case", "f", "e")]
    for part, level_getter, charge_getter in parts:
        _get(case, part + "Level", detail_class, level_getter, detail)
        charge = _get(case, part + "Charge", detail_class, charge_getter, detail)
        _get(case, part + "Charging", PARAM + "BatteryChargingStatus", "byteCode", charge)
    case["coverage_ids"] = [f"mdr-v1-t1-{[0x11, 0x15, 0x18][inquiry]:02x}.parser"]
    return case


def _modern_case(payload):
    case = _case("modern", payload)
    inquiry = payload[1]
    cls = MODERN_CLASSES[payload[0]][inquiry]
    builder_class = cls + ("$a" if cls == "yn0.q0" else "$b")
    builder = _call(case["calls"], case["id"] + ":builder", builder_class, "<init>")
    obj = _call(case["calls"], "object", builder_class, "i", ["byte[]"], [{"bytes": payload.hex()}], builder)
    parts = [("left", "e", "f"), ("right", "g", "h")] if inquiry in [1, 9] else [
        ("single" if inquiry in [0, 8] else "case", "e", "f")]
    for part, level_getter, charge_getter in parts:
        _get(case, part + "Level", cls, level_getter, obj)
        charge = _get(case, part + "Charge", cls, charge_getter, obj)
        _get(case, part + "Charging", POWER + "BatteryChargingStatus", "byteCode", charge)
        if inquiry >= 8:
            _get(case, part + "Threshold", cls, {"single": "g", "case": "g", "left": "i", "right": "j"}[part], obj)
    case["coverage_ids"] = [f"mdr-v2-t1-{0x20 + inquiry:02x}.parser"]
    return case


def _kmp_threshold_case(payload):
    case = _case("modern", payload)
    inquiry = payload[1]
    mappings = {
        (0x23, 8): ("kj0.b2", "kj0.a2", [("single", ("a", "b", "c"))]),
        (0x23, 9): ("kj0.j2", "kj0.i2", [("left", ("a", "b", "e")), ("right", ("c", "d", "f"))]),
        (0x23, 10): ("kj0.f2", "kj0.e2", [("case", ("a", "b", "c"))]),
        (0x25, 8): ("kj0.x0", "kj0.w0", [("single", ("a", "b", "c"))]),
        (0x25, 9): ("kj0.f1", "kj0.e1", [("left", ("a", "b", "e")), ("right", ("c", "d", "f"))]),
        (0x25, 10): ("kj0.b1", "kj0.a1", [("case", ("a", "b", "c"))]),
    }
    parser, owner, parts = mappings[payload[0], inquiry]
    builder = _call(case["calls"], case["id"] + ":parser", parser, "<init>")
    obj = _call(case["calls"], "object", parser, "a", ["byte[]"], [{"bytes": payload.hex()}], builder)
    for part, fields in parts:
        for key, field in zip(["Level", "Charge", "Threshold"], fields):
            identifier = case["id"] + ":" + part + key
            case["calls"].append({"id": identifier, "class": owner, "field": field, "target": obj})
            case["oracle"][part + key] = identifier
        _get(case, part + "Charging", KMP_CHARGING, "getByteValue", case["oracle"][part + "Charge"])
    old_builder_class = MODERN_CLASSES[payload[0]][inquiry] + "$b"
    old_builder = _call(case["calls"], "oldBuilder", old_builder_class, "<init>")
    case["oracle"]["oldParserAccepted"] = _call(case["calls"], "oldParserAccepted", old_builder_class, "b",
                                                 ["byte[]"], [{"bytes": payload.hex()}], old_builder)
    case["coverage_ids"] = [f"mdr-v2-t1-{0x20 + inquiry:02x}.parser"]
    return case


def _threshold_rejected_case(payload, command, inquiry):
    case = _case("modern", payload)
    case["id"] += f".rejected.{command}.{inquiry}"
    cls = MODERN_CLASSES[command][inquiry] + "$b"
    builder = _call(case["calls"], case["id"] + ":builder", cls, "<init>")
    case["oracle"]["accepted"] = _call(case["calls"], "accepted", cls, "b", ["byte[]"], [{"bytes": payload.hex()}], builder)
    case["coverage_ids"] = [f"mdr-v2-t1-{0x20 + inquiry:02x}.parser"]
    return case


def _case_threshold_decision(level, charging, threshold):
    case = {"id": f"battery.caseThresholdDecision.{level}.{charging}.{threshold}", "calls": [], "oracle": {},
            "swift": {"op": "battery.caseThresholdDecision", "level": level, "charging": charging, "threshold": threshold},
            "coverage_ids": ["mdr-v2-t1-2a.parser"]}
    args = [level, {"enum": CHARGING, "name": ["NOT_CHARGING", "CHARGING", "NOT_CHARGING", "CHARGED"][charging]}]
    types = ["int", CHARGING]
    if threshold is not None:
        args.append(threshold)
        types.append("int")
    obj = _call(case["calls"], case["id"] + ":model", "y00.e", "<init>", types, args)
    _get(case, "belowThreshold", "y00.e", "d", obj)
    _get(case, "hasThreshold", "y00.e", "e", obj)
    return case


def cases():
    result = []
    for command in [0x11, 0x13]:
        for inquiry in range(3):
            for level in [0, 1, 20, 50, 80, 99, 100]:
                for charging in [0, 1, 0xF0]:
                    payload = bytes([command, inquiry, level, charging])
                    if inquiry == 1:
                        for right_charging in [0, 1, 0xF0]:
                            result.append(_legacy_case(payload + bytes([100 - level, right_charging])))
                    else:
                        result.append(_legacy_case(payload))
    for command in [0x23, 0x25]:
        for inquiry in range(3):
            for level in ([0, 1, 20, 50, 80, 99, 100] if inquiry == 0 else [1, 20, 50, 80, 99, 100]):
                for charging in range(4):
                    payload = bytes([command, inquiry, level, charging])
                    if inquiry == 1:
                        for right_charging in range(4):
                            result.append(_modern_case(payload + bytes([101 - level, right_charging])))
                    else:
                        result.append(_modern_case(payload))
        for threshold in [0, 1, 20, 30, 99, 100]:
            for level in sorted({max(0, threshold - 1), threshold, min(100, threshold + 1)}):
                for charging in range(4):
                    result.append(_modern_case(bytes([command, 8, level, charging, threshold])))
                    if level > 0:
                        result.append(_modern_case(bytes([command, 9, level, charging, 101 - level, 3 - charging,
                                                          threshold, 100 - threshold])))
                        result.append(_modern_case(bytes([command, 10, level, charging, threshold])))
        for threshold in [101, 127, 128, 254, 255]:
            for payload in [bytes([command, 8, 50, 2, threshold]), bytes([command, 9, 50, 1, 60, 3, threshold, 20]),
                            bytes([command, 10, 50, 0, threshold])]:
                result.append(_kmp_threshold_case(payload))
        for payload in [bytes([command, 8, 50, 0, 20]), bytes([command, 9, 50, 0, 60, 0, 20, 30]),
                        bytes([command, 10, 50, 0, 20])]:
            for count in range(len(payload)):
                result.append(_threshold_rejected_case(payload[:count], command, payload[1]))
            result.append(_threshold_rejected_case(payload + bytes([0]), command, payload[1]))
    for threshold in [None, 0, 1, 20, 30, 100]:
        levels = [0, 19, 20, 21, 100] if threshold is None else sorted({max(0, threshold - 1), threshold, min(100, threshold + 1)})
        for level in levels:
            for charging in range(4):
                result.append(_case_threshold_decision(level, charging, threshold))
    return result


def normalize(case, results):
    def value(key):
        return results[case["oracle"][key]]

    if case["swift"]["op"] == "battery.caseThresholdDecision":
        return {"belowThreshold": value("belowThreshold") if value("hasThreshold") else None}
    if "accepted" in case["oracle"]:
        return {"accepted": value("accepted")}
    if "oldParserAccepted" in case["oracle"] and value("oldParserAccepted"):
        raise ValueError("Old battery parser unexpectedly accepted an out-of-range threshold")
    inquiry = bytes.fromhex(case["swift"]["payload"])[1]
    parts = ["left", "right"] if inquiry in [1, 9] else ["single" if inquiry in [0, 8] else "case"]
    result = {"accepted": True}
    for part in parts:
        charging = value(part + "Charging") & 255
        result[part] = {"level": value(part + "Level"), "charging": 2 if charging == 0xF0 else charging,
                        "threshold": value(part + "Threshold") if part + "Threshold" in case["oracle"] else None}
    return result


def mutations():
    return [{"name": "battery level decoding corruption",
             "replacement": ("SonyProtocol.swift", "self.level = Int(level)", "self.level = Int(level) + 1"),
             "case_ids": ["battery.legacy.11000000", "battery.modern.23000000"]},
            {"name": "battery threshold equality corruption",
             "replacement": ("SonyProtocol.swift", "return level < Int(lowBatteryThreshold)", "return level <= Int(lowBatteryThreshold)"),
             "case_ids": ["battery.caseThresholdDecision.20.0.20"]},
            {"name": "battery threshold decoding loss",
             "replacement": ("SonyProtocol.swift", "self.lowBatteryThreshold = lowBatteryThreshold", "self.lowBatteryThreshold = nil"),
             "case_ids": ["battery.modern.2308140014"]}]


def unsupported():
    return [
        {"schema": "Battery invalid-level and unknown-charge policy", "reason": "Semantic comparisons use valid 0–100 levels and declared charging states. Production rejects invalid readings; the legacy APK preserves raw levels and defaults unknown charging bytes."},
        {"schema": "Modern battery absent-reading policy", "reason": "Modern LR and cradle parser comparisons use positive levels; production treats zero as absent. Controller notification sequencing is outside this parser batch."},
        {"schema": "Battery unknown thresholds and headphone low-state presentation", "reason": "KMP parsers preserve threshold bytes above 100 while older yn0 parsers reject them. Production retains those bytes but exposes no low-state decision. The verified strict comparison is the case model y00.e.d(); Sony headphone/LR consumers were not found using their stored thresholds."},
    ]

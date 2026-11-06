from itertools import product

from legacy import PARAM, _call, _get, _parse


MODERN = "com.sony.songpal.tandemfamily.message.mdr.v2."
POWER = MODERN + "table1.power.param."
POWER2 = MODERN + "table2.power.param."
ON_OFF = MODERN + "OnOffSettingValue"
AVAILABILITY = MODERN + "EnableDisable"
FUNCTION = MODERN + "FunctionType"
KMP = "com.sony.songpal.mdr.kmp.tandem.command.v2."
ELEMENTS = {
    0: "POWER_OFF_IN_5_MIN", 1: "POWER_OFF_IN_30_MIN", 2: "POWER_OFF_IN_60_MIN",
    3: "POWER_OFF_IN_180_MIN", 4: "POWER_OFF_IN_15_MIN",
    0x10: "POWER_OFF_WHEN_REMOVED_FROM_EARS", 0x11: "POWER_OFF_DISABLE",
}


def _case(identifier, operation, feature, phase, **inputs):
    return {"id": "power." + identifier, "swift": {"op": "power." + operation, **inputs},
            "calls": [], "oracle": {}, "coverage_ids": [feature + "." + phase]}


def _modern_parse(case, owner, payload, method="g"):
    case["swift"]["payload"] = bytes(payload).hex()
    builder = _call(case["calls"], case["id"] + ":builder", owner + "$b", "<init>")
    return _call(case["calls"], "object", owner + "$b", method,
                 ["byte[]"], [{"bytes": bytes(payload).hex()}], builder)


def _code(case, key, owner, method, target, enum):
    value = _get(case, key + "Enum", owner, method, target)
    return _get(case, key, enum, "byteCode", value)


def _list(case, key, owner, method, target, enum, count):
    values = _get(case, key + "List", owner, method, target)
    _get(case, key + "Count", "java.util.List", "size", values)
    for index in range(count):
        value = _call(case["calls"], key + str(index) + "Enum", "java.util.List", "get", ["int"], [index], values)
        _get(case, key + str(index), enum, "byteCode", value)


def _write(case, owner, method, types, args):
    builder = _call(case["calls"], case["id"] + ":builder", owner + "$b", "<init>")
    obj = _call(case["calls"], "object", owner + "$b", method, types, args, builder)
    _get(case, "payload", owner, "d", obj)
    return case


def _enum(owner, name):
    return {"enum": owner, "name": name}


def switch_cases():
    result = []
    variants = [("switch", 6, 0x26, "POWER_SAVE_MODE"),
                ("care", 12, 0x2C, "CARING_CHARGE"),
                ("switch", 14, 0x2E, "STAMINA"),
                ("switch", 15, 0x2F, "AUTOMATIC_TOUCH_PANEL_BACKLIGHT_TURN_OFF")]
    for operation, inquiry, function, name in variants:
        feature = f"mdr-v2-t1-{function:02x}"
        for command, owner, method, getter, key, enum in [
            (0x23, "yn0.n0", "g", "e", "available", AVAILABILITY),
            (0x25, "yn0.p", "g", "e", "available", AVAILABILITY),
            (0x27, "yn0.f0", "g", "c", "enabled", ON_OFF),
            (0x29, "yn0.h", "g", "e", "enabled", ON_OFF),
        ]:
            if inquiry == 6 and command in (0x23, 0x25):
                owner = "yn0.t0" if command == 0x23 else "yn0.w"
                method = "f"
            for value in range(2):
                case = _case(f"switch.{inquiry}.{command}.{value}", operation, feature, "parser", inquiry=inquiry)
                obj = _modern_parse(case, owner, [command, inquiry, value], method)
                _code(case, key, owner, getter, obj, enum)
                result.append(case)
        for enabled in (False, True):
            case = _case(f"switch.{inquiry}.set.{enabled}", operation, feature, "serializer", inquiry=inquiry, enabled=enabled)
            result.append(_write(case, "yn0.y0", "i", [POWER + "PowerInquiredType", ON_OFF],
                                 [_enum(POWER + "PowerInquiredType", name), _enum(ON_OFF, "ON" if enabled else "OFF")]))
        if operation == "switch":
            for command, owner in [(0x22, "yn0.c"), (0x26, "yn0.b")]:
                case = _case(f"switch.{inquiry}.query.{command}", operation, feature, "serializer",
                             inquiry=inquiry, query=command)
                result.append(_write(case, owner, "g", [POWER + "PowerInquiredType"],
                                     [_enum(POWER + "PowerInquiredType", name)]))
    return result


def bluetooth_standby_cases():
    result = []
    feature = "mdr-v2-t1-2d"
    for command, parser, owner, key, enum in [
        (0x23, "kj0.n1", "kj0.m1", "available", KMP + "ProtocolEnableDisable"),
        (0x25, "kj0.l0", "kj0.k0", "available", KMP + "ProtocolEnableDisable"),
        (0x27, "kj0.l1", "kj0.k1", "enabled", KMP + "ProtocolOnOff"),
        (0x29, "kj0.j0", "kj0.i0", "enabled", KMP + "ProtocolOnOff"),
    ]:
        for value in range(2):
            payload = bytes([command, 13, value]).hex()
            case = _case(f"bluetoothStandby.{command}.{value}", "switch", feature, "parser",
                         inquiry=13, payload=payload)
            builder = _call(case["calls"], case["id"] + ":parser", parser, "<init>")
            obj = _call(case["calls"], "object", parser, "a", ["byte[]"], [{"bytes": payload}], builder)
            state = _get(case, key + "Enum", owner, "a", obj)
            _get(case, key, enum, "getByteValue", state)
            result.append(case)
    for enabled in (False, True):
        case = _case(f"bluetoothStandby.set.{enabled}", "switch", feature, "serializer",
                     inquiry=13, enabled=enabled)
        builder = _call(case["calls"], case["id"] + ":serializer", "kj0.n2", "<init>")
        obj = _call(case["calls"], "object", "kj0.m2", "<init>", [KMP + "ProtocolOnOff"],
                    [_enum(KMP + "ProtocolOnOff", "ON" if enabled else "OFF")])
        case["oracle"]["payload"] = _call(case["calls"], "payload", "kj0.n2", "b", ["kj0.m2"], [{"ref": obj}], builder)
        result.append(case)
    for command, serializer, owner in [(0x22, "kj0.h", "kj0.g"), (0x26, "kj0.f", "kj0.e")]:
        case = _case(f"bluetoothStandby.query.{command}", "switch", feature, "serializer",
                     inquiry=13, query=command)
        builder = _call(case["calls"], case["id"] + ":serializer", serializer, "<init>")
        obj = _call(case["calls"], "object", owner, "<init>")
        case["oracle"]["payload"] = _call(case["calls"], "payload", serializer, "b", [owner], [{"ref": obj}], builder)
        result.append(case)
    return result


def auto_standby_cases():
    result = []
    feature = "mdr-v2-t2-20"
    for index, payload in enumerate(([0x21, 0, 0], [0x21, 0, 0, 0xFE])):
        case = _case(f"standby.capability.{index}", "standby", feature, "capability", frameType=14)
        obj = _modern_parse(case, "qo0.l", payload, "f")
        _code(case, "candidate", "qo0.l", "e", obj, POWER2 + "AutoStandbyCandidateElement")
        result.append(case)
    for command, owner, getter, key, enum in [
        (0x23, "qo0.s", "c", "available", AVAILABILITY),
        (0x25, "qo0.i", "e", "available", AVAILABILITY),
        (0x27, "qo0.p", "c", "enabled", ON_OFF),
        (0x29, "qo0.e", "e", "enabled", ON_OFF),
    ]:
        for value in range(2):
            case = _case(f"standby.{command}.{value}", "standby", feature, "parser", frameType=14)
            obj = _modern_parse(case, owner, [command, 0, value])
            _code(case, key, owner, getter, obj, enum)
            result.append(case)
    for enabled in (False, True):
        case = _case(f"standby.set.{enabled}", "standby", feature, "serializer", frameType=14, enabled=enabled)
        result.append(_write(case, "qo0.v", "i", [POWER2 + "PowerInquiredType", ON_OFF],
                             [_enum(POWER2 + "PowerInquiredType", "AUTO_STANDBY"),
                              _enum(ON_OFF, "ON" if enabled else "OFF")]))
    for command, owner, method in [(0x20, "qo0.a", "f"), (0x22, "qo0.c", "f"), (0x26, "qo0.b", "g")]:
        case = _case(f"standby.query.{command}", "standby", feature, "serializer", frameType=14, query=command)
        result.append(_write(case, owner, method, [POWER2 + "PowerInquiredType"],
                             [_enum(POWER2 + "PowerInquiredType", "AUTO_STANDBY")]))
    return result


def charge_in_use_cases():
    result = []
    owner = "com.sony.songpal.mdr.j2objc.devicecapability.tableset2."
    builder_class = owner + "DeviceCapabilityTableset2Builder"
    color = "com.sony.songpal.util.modelinfo.ModelColor"
    series = MODERN + "table1.connect.param.ModelSeries"
    for table in (0, 1, 2):
        case = _case(f"chargeInUse.{table}", "chargeInUse", "mdr-v2-t2-21", "capability",
                     functions=[0x21] if table == 1 else [], functions2=[0x21] if table == 2 else [])
        builder = _call(case["calls"], case["id"] + ":builder", builder_class, "<init>")
        for method, value_type, value in [("A", "int", 0), ("D0", "int", 0),
                                          ("n0", color, _enum(color, "DEFAULT")),
                                          ("o0", "java.lang.String", "fixture"),
                                          ("p0", series, _enum(series, "NO_SERIES")),
                                          ("W0", "java.lang.String", "fixture-id"),
                                          ("X", "java.lang.String", "0")]:
            _call(case["calls"], "builder." + method, builder_class, method, [value_type], [value], builder)
        entries = []
        if table:
            function = _call(case["calls"], "function", FUNCTION, "fromByteCode", [FUNCTION + "$Table", "byte"],
                             [_enum(FUNCTION + "$Table", "NO_" + str(table)), 0x21])
            entry = _call(case["calls"], "entry", "cn0.c", "<init>", [FUNCTION, "int"], [{"ref": function}, 0])
            entries.append({"ref": entry})
        _call(case["calls"], "functions", builder_class, "a", ["java.util.List"], [entries], builder)
        capability = _call(case["calls"], "capability", builder_class, "b", target=builder)
        _get(case, "supported", owner + "r", "X", capability)
        result.append(case)
    return result


def care_cases():
    result = []
    feature = "mdr-v2-t2-22"
    for threshold in (1, 20, 80, 100):
        case = _case(f"care.threshold.{threshold}", "care", feature, "capability", frameType=14)
        obj = _modern_parse(case, "qo0.m", [0x21, 1, threshold], "f")
        _get(case, "threshold", "qo0.m", "e", obj)
        result.append(case)
    for command, owner, availability, notice in [(0x23, "qo0.r", "c", "e"), (0x25, "qo0.h", "e", "f")]:
        for available, necessary in product(range(2), repeat=2):
            case = _case(f"care.status.{command}.{available}.{necessary}", "care", feature, "parser", frameType=14)
            obj = _modern_parse(case, owner, [command, 1, available, necessary])
            _code(case, "available", owner, availability, obj, AVAILABILITY)
            _code(case, "noticeNecessary", owner, notice, obj, POWER2 + "NoticeForBatteryNecessity")
            result.append(case)
    for command, owner, getter in [(0x27, "qo0.p", "c"), (0x29, "qo0.e", "e")]:
        for value in range(2):
            case = _case(f"care.parameter.{command}.{value}", "care", feature, "parser", frameType=14)
            obj = _modern_parse(case, owner, [command, 1, value])
            _code(case, "enabled", owner, getter, obj, ON_OFF)
            result.append(case)
    for enabled in (False, True):
        case = _case(f"care.set.{enabled}", "care", feature, "serializer", frameType=14, enabled=enabled)
        result.append(_write(case, "qo0.v", "i", [POWER2 + "PowerInquiredType", ON_OFF],
                             [_enum(POWER2 + "PowerInquiredType", "CARING_CHARGE_WITH_THRESHOLD"),
                              _enum(ON_OFF, "ON" if enabled else "OFF")]))
    return result


def save_cases():
    result = []
    feature = "mdr-v2-t1-2b"
    for threshold, functions, functions2 in product((0, 20, 100), ([], [0x50, 0xF1]), ([], [0x22, 0x32])):
        case = _case(f"save.capability.{threshold}.{len(functions)}.{len(functions2)}", "save", feature, "capability")
        obj = _modern_parse(case, "yn0.a0", [0x21, 11, threshold, len(functions), *functions, len(functions2), *functions2])
        _get(case, "threshold", "yn0.a0", "h", obj)
        _list(case, "affectedFunctions", "yn0.a0", "l", obj, FUNCTION, len(functions))
        _list(case, "affectedFunctions2", "yn0.a0", "m", obj, FUNCTION, len(functions2))
        result.append(case)
    for command, owner, enabled_getter, effect_getter in [(0x27, "yn0.e0", "e", "c"), (0x29, "yn0.g", "f", "e")]:
        for enabled, effect in product(range(2), repeat=2):
            case = _case(f"save.parameter.{command}.{enabled}.{effect}", "save", feature, "parser")
            obj = _modern_parse(case, owner, [command, 11, enabled, effect], "f")
            _code(case, "enabled", owner, enabled_getter, obj, ON_OFF)
            _code(case, "effectActive", owner, effect_getter, obj, ON_OFF)
            result.append(case)
    for enabled in (False, True):
        case = _case(f"save.set.{enabled}", "save", feature, "serializer", enabled=enabled)
        result.append(_write(case, "yn0.x0", "h", [ON_OFF, POWER + "BatterySafeModeEffectStatusControl"],
                             [_enum(ON_OFF, "ON" if enabled else "OFF"),
                              _enum(POWER + "BatterySafeModeEffectStatusControl", "NOT_TO_CHANGE")]))
    case = _case("save.cancel", "save", feature, "serializer", cancel=True)
    result.append(_write(case, "yn0.x0", "h", [ON_OFF, POWER + "BatterySafeModeEffectStatusControl"],
                         [_enum(ON_OFF, "ON"), _enum(POWER + "BatterySafeModeEffectStatusControl", "TURN_OFF_THE_EFFECT")]))
    return result


def auto_off_cases():
    result = []
    for generation, inquiry, function in [(1, 4, 0xF4), (2, 4, 0x24), (2, 5, 0x25)]:
        feature = f"mdr-v{generation}-t1-{function:02x}"
        prefix = f"autoOff.{generation}.{inquiry}"
        enum = PARAM + "AutoPowerOffElementId" if generation == 1 else POWER + (
            "AutoPowerOffElements" if inquiry == 4 else "AutoPowerOffWearingDetectionElements")
        options = list(range(4 if generation == 1 else 5)) + ([0x10] if generation == 1 or inquiry == 5 else []) + [0x11]
        for index, values in enumerate((options, list(reversed(options)), [options[0], options[-1]])):
            payload = bytes([0xF1 if generation == 1 else 0x21, inquiry, len(values), *values])
            case = _case(f"{prefix}.capability.{index}", "autoOff", feature, "capability",
                         generation=generation, inquiry=inquiry, payload=payload.hex())
            if generation == 1:
                obj = _parse(case, "tm0.t2", payload)
                detail = _get(case, "detail", "tm0.t2", "m", obj)
                _list(case, "options", "tm0.t2$c", "b", detail, enum, len(values))
            else:
                owner = "yn0.y" if inquiry == 4 else "yn0.z"
                obj = _modern_parse(case, owner, payload)
                _list(case, "options", owner, "e", obj, enum, len(values))
            result.append(case)
        for notification, value in product((False, True), range(2)):
            command = (0xF5 if notification else 0xF3) if generation == 1 else (0x25 if notification else 0x23)
            payload = bytes([command, inquiry, value])
            case = _case(f"{prefix}.status.{command}.{value}", "autoOff", feature, "parser",
                         generation=generation, inquiry=inquiry, payload=payload.hex())
            if generation == 1:
                owner = "tm0.j1" if notification else "tm0.w2"
                obj = _parse(case, owner, payload)
                _code(case, "available", owner, "j", obj, "com.sony.songpal.tandemfamily.mdr.param.CommonStatus")
            else:
                owner = ("yn0.j" if notification else "yn0.h0") if inquiry == 4 else ("yn0.k" if notification else "yn0.i0")
                obj = _modern_parse(case, owner, payload, "f")
                _code(case, "available", owner, "e", obj, AVAILABILITY)
            result.append(case)
        timers = (0, 3) if generation == 1 else (0, 3, 4)
        for notification, current, last in product((False, True), options, timers):
            command = (0xF9 if notification else 0xF7) if generation == 1 else (0x29 if notification else 0x27)
            payload = bytes([command, inquiry] + ([1] if generation == 1 else []) + [current, last])
            case = _case(f"{prefix}.parameter.{command}.{current}.{last}", "autoOff", feature, "parser",
                         generation=generation, inquiry=inquiry, payload=payload.hex())
            if generation == 1:
                owner = "tm0.i1" if notification else "tm0.v2"
                obj = _parse(case, owner, payload)
                detail = _get(case, "detail", owner, "h", obj)
                _code(case, "current", "vm0.g", "e", detail, enum)
                _code(case, "last", "vm0.g", "f", detail, enum)
            else:
                owner = ("yn0.e" if notification else "yn0.c0") if inquiry == 4 else ("yn0.f" if notification else "yn0.d0")
                obj = _modern_parse(case, owner, payload, "f")
                _code(case, "current", owner, "e" if notification else "c", obj, enum)
                _code(case, "last", owner, "f" if notification else "e", obj, enum)
            result.append(case)
        for selected, last in product(options, timers):
            case = _case(f"{prefix}.set.{selected}.{last}", "autoOff", feature, "serializer",
                         generation=generation, inquiry=inquiry, options=options, selected=selected, last=last)
            selection = _call(case["calls"], case["id"] + ":selection", enum, "fromByteCode", ["byte"], [selected])
            _get(case, "isSelectTime", enum, "isSelectTime", selection)
            remembered = selected if selected < 0x10 else last
            arguments = [_enum(enum, ELEMENTS[selected]), _enum(enum, ELEMENTS[remembered])]
            if generation == 1:
                detail = _call(case["calls"], "detail", "vm0.g", "<init>", [PARAM + "AutoPowerOffParameterType", enum, enum],
                               [_enum(PARAM + "AutoPowerOffParameterType", "ACTIVE_AND_SELECTIME_ID"), *arguments])
                obj = _call(case["calls"], "object", "tm0.r3", "<init>", ["vm0.k0"], [{"ref": detail}])
                _get(case, "payload", "tm0.r3", "d", obj)
            else:
                _write(case, "yn0.v0" if inquiry == 4 else "yn0.w0", "h", [enum, enum], arguments)
            result.append(case)
    return result


def cases():
    result = (switch_cases() + bluetooth_standby_cases() + auto_standby_cases() + charge_in_use_cases()
              + care_cases() + save_cases() + auto_off_cases())
    for name, operation, payload, inputs in [
        ("care.zeroThreshold", "care", [0x21, 1, 0], {"frameType": 14}),
        ("care.shortStatus", "care", [0x23, 1, 0], {"frameType": 14}),
        ("switch.trailing", "switch", [0x29, 15, 0, 0], {"inquiry": 15}),
        ("standby.unknownCandidate", "standby", [0x21, 0, 1], {"frameType": 14}),
        ("standby.shortStatus", "standby", [0x23, 0], {"frameType": 14}),
        ("standby.trailingParameter", "standby", [0x27, 0, 0, 0], {"frameType": 14}),
        ("save.truncatedCounts", "save", [0x21, 11, 20, 2, 0x50], {}),
        ("save.trailing", "save", [0x27, 11, 0, 0, 0], {}),
        ("autoOff.duplicateOptions", "autoOff", [0x21, 5, 2, 0, 0], {"generation": 2, "inquiry": 5}),
        ("autoOff.shortParameter", "autoOff", [0xF7, 4, 1, 0], {"generation": 1, "inquiry": 4}),
    ]:
        result.append({"id": "power.boundary." + name, "swift": {"op": "power." + operation,
                       "payload": bytes(payload).hex(), **inputs}, "calls": [], "oracle": {},
                       "coverage_ids": [], "category": "malformed", "expected": {"accepted": False}})
    return result


def normalize(case, results):
    def value(key):
        return results[case["oracle"][key]]

    if "payload" in case["oracle"]:
        if "isSelectTime" in case["oracle"]:
            selected = case["swift"]["selected"]
            if value("isSelectTime") != (selected < 0x10):
                raise ValueError("APK timer selection differs from the serializer fixture")
        return {"payload": value("payload")["bytes"]}
    if "supported" in case["oracle"]:
        return {"supported": value("supported")}
    result = {"accepted": True}
    for key in ("threshold", "candidate", "current", "last"):
        if key in case["oracle"]:
            result[key] = value(key) & 255
    for key in ("available", "enabled", "effectActive", "noticeNecessary"):
        if key in case["oracle"]:
            result[key] = value(key) == 0
    for key in ("options", "affectedFunctions", "affectedFunctions2"):
        if key + "Count" in case["oracle"]:
            result[key] = [value(key + str(index)) & 255 for index in range(value(key + "Count"))]
    return result


def mutations():
    return [{"name": "auto power save switch polarity corruption",
             "replacement": ("SonyPowerFeatures.swift",
                             "return [0x28, 0x0B, enabled ? 0x00 : 0x01, 0x00]",
                             "return [0x28, 0x0B, enabled ? 0x01 : 0x00, 0x00]"),
             "case_ids": ["power.save.set.False", "power.save.set.True"]}]


def unsupported():
    return [
        {"schema": "Power application sequencing", "reason": "This group compares capability/state parsing and serializer bytes. Capability routing, query scheduling, stale replies, request ownership, stamina warning acknowledgements, UI behavior and physical firmware are not exercised."},
        {"schema": "Power unknown-value and malformed-input policy", "reason": "Semantic comparisons use APK-declared values and structurally valid replies. Production-only malformed boundaries carry no feature coverage. Unknown-value defaults and every malformed length are not compared."},
        {"schema": "Automatic power-off remembered timer", "reason": "The APK enum's isSelectTime and actual serializer are executed; shared app selectors jn.p.j and jn.z.j are inspected but not executed. Timer inputs cover first, last and modern 15-minute choices rather than every remembered-timer combination."},
    ]

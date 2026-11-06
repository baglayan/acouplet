from itertools import product
from legacy import _call, _get


PARAM = 'com.sony.songpal.tandemfamily.message.mdr.v2.table1.ncasm.param.'
SYSTEM = 'com.sony.songpal.tandemfamily.message.mdr.v2.table1.system.param.'
COMMON = 'com.sony.songpal.tandemfamily.message.mdr.v2.'
APP = 'com.sony.songpal.mdr.j2objc.tandem.features.ncasm.'
FUNCTIONS = {0x61: 1, 0x62: 0x11, 0x63: 0x12, 0x64: 0x13, 0x65: 0x14, 0x6A: 0x16, 0x6C: 0x18}
INQUIRIES = {
    1: 'NC_ON_OFF', 0x11: 'NC_ON_OFF_AND_ASM_ON_OFF', 0x12: 'NC_MODE_SWITCH_AND_ASM_ON_OFF',
    0x13: 'NC_ON_OFF_AND_ASM_SEAMLESS', 0x14: 'NC_MODE_SWITCH_AND_ASM_SEAMLESS',
    0x16: 'MODE_NC_ASM_DUAL_SINGLE_NC_MODE_SWITCH_AND_ASM_SEAMLESS',
    0x18: 'MODE_NC_NCSS_ASM_DUAL_NC_MODE_SWITCH_AND_ASM_SEAMLESS',
    0x30: 'NC_AMB_TOGGLE', 0x40: 'NC_TEST_MODE',
}
TAILS = {
    1: [('noiseValue', 'n', 'a', 'NcAsmOnOffValue')],
    0x11: [('noiseValue', 'o', 'c', 'NcAsmOnOffValue'), ('ambientMode', 'o', 'a', 'AmbientSoundMode'),
           ('ambientLevel', 'o', 'b', 'NcAsmOnOffValue')],
    0x12: [('noiseValue', 'k', 'c', 'NcValue'), ('ambientMode', 'k', 'a', 'AmbientSoundMode'),
           ('ambientLevel', 'k', 'b', 'NcAsmOnOffValue')],
    0x13: [('noiseValue', 'p', 'c', 'NcAsmOnOffValue'), ('ambientMode', 'p', 'b', 'AmbientSoundMode'),
           ('ambientLevel', 'p', 'a', None)],
    0x14: [('noiseValue', 'l', 'c', 'NcValue'), ('ambientMode', 'l', 'b', 'AmbientSoundMode'),
           ('ambientLevel', 'l', 'a', None)],
    0x16: [('ncAsmMode', 'h', 'c', 'NcAsmMode'), ('noiseValue', 'h', 'd', 'NcValue'),
           ('ambientMode', 'h', 'b', 'AmbientSoundMode'), ('ambientLevel', 'h', 'a', None)],
    0x18: [('ncAsmMode', 'm', 'c', 'NcNcssAsmMode'), ('ambientMode', 'm', 'b', 'AmbientSoundMode'),
           ('ambientLevel', 'm', 'a', None)],
}
ENUMS = {
    'ValueChangeStatus': ['UNDER_CHANGING', 'CHANGED'], 'NcAsmOnOffValue': ['OFF', 'ON'],
    'AmbientSoundMode': ['NORMAL', 'VOICE'], 'NcValue': ['OFF', 'ON_SINGLE', 'ON_DUAL', 'AUTO', 'AUTO_SINGLE', 'AUTO_DUAL'],
    'NcAsmMode': ['NC', 'ASM'], 'NcNcssAsmMode': ['NC', 'ASM', 'NcSS'],
}


def _case(identifier, operation, function, **inputs):
    phase = 'serializer' if operation in ('read', 'set', 'toggleSet', 'testRead', 'testSet') else 'capability' if operation in ('capability', 'toggleCapability') else 'parser'
    return {'id': 'modern_noise.' + identifier,
            'swift': {'op': 'modernNoise.' + operation, 'function': function, **inputs},
            'calls': [], 'oracle': {}, 'coverage_ids': [f'mdr-v2-t1-{function:02x}.' + phase]}


def _parse(case, cls, method, payload):
    builder = _call(case['calls'], case['id'] + ':builder', cls + '$b', '<init>')
    return _call(case['calls'], 'object', cls + '$b', method, ['byte[]'], [{'bytes': payload.hex()}], builder)


def _enum_get(case, key, cls, method, obj, enum):
    value = _get(case, key + 'Enum', cls, method, obj)
    _get(case, key, enum, 'byteCode', value)


def _static(case, key, cls, method, payload):
    value = _call(case['calls'], case['id'] + ':' + key if not case['calls'] else key, cls, method,
                  ['byte[]'], [{'bytes': payload.hex()}])
    case['oracle'][key] = value
    return value


def _capability(function, payload):
    inquiry = FUNCTIONS[function]
    case = _case(f'capability.{function}.{payload.hex()}', 'capability', function, payload=payload.hex())
    if inquiry == 0x11:
        _static(case, 'valid', 'un0.a', 'b', payload)
        items = _static(case, 'items', 'un0.a', 'a', payload)
    else:
        obj = _parse(case, 'sn0.u', 'e', payload)
        if inquiry == 1:
            _get(case, 'payload', 'sn0.u', 'd', obj)
            return case
        cls = {0x12: 'c0', 0x13: 'h0', 0x14: 'd0', 0x16: 'z', 0x18: 'e0'}[inquiry]
        items = _get(case, 'items', 'sn0.' + cls, 'e', obj)
    _get(case, 'count', 'java.util.List', 'size', items)
    for index in range(payload[2] if len(payload) > 2 else 0):
        item = _call(case['calls'], f'item{index}', 'java.util.List', 'get', ['int'], [index], items)
        if inquiry in (0x11, 0x12):
            _get(case, f'mode{index}', PARAM + 'AmbientSoundMode', 'byteCode', item)
        else:
            _enum_get(case, f'mode{index}', 'tn0.a', 'a', item, PARAM + 'AmbientSoundMode')
            interval = _get(case, f'range{index}', 'tn0.a', 'b', item)
            for key, method in [('minimum', 'b'), ('maximum', 'a'), ('step', 'c')]:
                _get(case, f'{key}{index}', 'cn0.b', method, interval)
    return case


def _available(function, payload):
    case = _case(f'available.{function}.{payload.hex()}', 'available', function, payload=payload.hex())
    cls = 'sn0.x0' if payload[0] == 0x63 else 'sn0.s'
    obj = _parse(case, cls, 'e', payload)
    _enum_get(case, 'available', 'sn0.w0' if payload[0] == 0x63 else 'sn0.r', 'c', obj, COMMON + 'EnableDisable')
    return case


def _state(function, payload):
    inquiry = FUNCTIONS[function]
    case = _case(f'state.{function}.{payload.hex()}', 'state', function, payload=payload.hex())
    cls = 'sn0.i0' if payload[0] == 0x67 else 'sn0.d'
    if inquiry == 0x11:
        builder = _call(case['calls'], case['id'] + ':builder', cls + '$b', '<init>')
        case['oracle']['headerValid'] = _call(case['calls'], 'headerValid', cls + '$b', 'b', ['byte[]'], [{'bytes': payload.hex()}], builder)
        _static(case, 'valid', 'un0.o', 'd', payload)
        for key, index, enum in [('change', 2, 'ValueChangeStatus'), ('effect', 3, 'NcAsmOnOffValue')]:
            if len(payload) > index:
                item = _call(case['calls'], key + 'Enum', PARAM + enum, 'fromByteCode', ['byte'], [payload[index] if payload[index] < 128 else payload[index] - 256])
                _get(case, key, PARAM + enum, 'byteCode', item)
    else:
        obj = _parse(case, cls, 'e', payload)
        _get(case, 'payload', cls, 'd', obj)
        _enum_get(case, 'effect', cls, 'c', obj, PARAM + 'NcAsmOnOffValue')
        _enum_get(case, 'change', cls, 'e', obj, PARAM + 'ValueChangeStatus')
    for key, helper, method, enum in TAILS[inquiry]:
        value = _static(case, key + 'Enum' if enum else key, 'un0.' + helper, method, payload)
        if enum:
            _get(case, key, PARAM + enum, 'byteCode', value)
    return case


def _auto_mode(payload):
    case = _case(f'autoMode.{payload.hex()}', 'autoMode', 0x68, payload=payload.hex())
    cls = 'sn0.i0' if payload[0] == 0x67 else 'sn0.d'
    obj = _parse(case, cls, 'e', payload)
    parsed = _get(case, 'payload', cls, 'd', obj)
    change = _get(case, 'change', cls, 'e', obj)
    effect = _get(case, 'effect', cls, 'c', obj)
    status = _call(case['calls'], 'status', APP + 'NcAsmSendStatus', 'fromTableSet2',
                   [PARAM + 'ValueChangeStatus', PARAM + 'NcAsmOnOffValue'], [{'ref': change}, {'ref': effect}])
    arguments = [{'ref': status}]
    types = [APP + 'NcAsmSendStatus']
    for key, getter, enum, app_enum, converter in [
        ('ncAsmMode', 'c', 'NcAsmMode', 'NoiseCancellingAsmMode', 'fromTableSet2'),
        ('noiseValue', 'd', 'NcValue', 'NoiseCancellingTernaryValue', 'fromNcValueTableSet2'),
        ('ambientMode', 'b', 'AmbientSoundMode', 'AmbientSoundMode', 'fromAsmIdTableSet2'),
    ]:
        value = _call(case['calls'], key, 'un0.i', getter, ['byte[]'], [{'ref': parsed}])
        converted = _call(case['calls'], key + 'App', APP + app_enum, converter, [PARAM + enum], [{'ref': value}])
        arguments.append({'ref': converted})
        types.append(APP + app_enum)
    level = _call(case['calls'], 'ambientLevel', 'un0.i', 'a', ['byte[]'], [{'ref': parsed}])
    case['oracle']['mode'] = _call(case['calls'], 'mode', 'com.sony.songpal.mdr.j2objc.actionlog.param.e', 'n',
                                  types + ['int'], arguments + [{'ref': level}])
    return case


def _write(function, initial, tail, effect=1, **inputs):
    inquiry = FUNCTIONS[function]
    suffix = '.'.join(f'{key}={value}' for key, value in inputs.items()) or 'unchanged'
    case = _case(f'set.{function}.{initial.hex()}.{suffix}', 'set', function, payload=initial.hex(), **inputs)
    cls = 'sn0.' + {1: 'k1', 0x11: 'l1', 0x12: 'h1', 0x13: 'm1', 0x14: 'i1', 0x16: 'e1', 0x18: 'j1'}[inquiry]
    builder = _call(case['calls'], case['id'] + ':builder', cls + '$b', '<init>')
    types = [PARAM + 'ValueChangeStatus', PARAM + 'NcAsmOnOffValue']
    args = [{'enum': types[0], 'name': 'CHANGED'}, {'enum': types[1], 'name': ENUMS['NcAsmOnOffValue'][effect]}]
    for value, (_, _, _, enum) in zip(tail, TAILS[inquiry]):
        types.append(PARAM + enum if enum else 'int')
        args.append({'enum': PARAM + enum, 'name': ENUMS[enum][value]} if enum else value)
    obj = _call(case['calls'], 'object', cls + '$b', 'h', types, args, builder)
    _get(case, 'payload', cls, 'd', obj)
    return case


def _toggle(operation, payload):
    case = _case(f'{operation}.{payload.hex()}', operation, 0x69, payload=payload.hex())
    cls = 'sn0.b0' if operation == 'toggleCapability' else 'sn0.p0' if payload[0] == 0x67 else 'sn0.k'
    obj = _parse(case, cls, 'f' if operation == 'toggleCapability' else 'e', payload)
    _enum_get(case, 'key' if operation == 'toggleCapability' else 'selected', cls,
              'e' if operation == 'toggleCapability' else 'f', obj, SYSTEM + ('Key' if operation == 'toggleCapability' else 'Function'))
    return case


def _test(payload):
    case = _case(f'test.{payload.hex()}', 'test', 0x6C, payload=payload.hex())
    cls = 'sn0.y0' if payload[0] == 0x63 else 'sn0.t'
    obj = _parse(case, cls, 'f', payload)
    _enum_get(case, 'active', cls, 'c', obj, PARAM + 'NcTestModeStatus')
    return case


def _boundary(case, expected=None):
    case.update(category='malformed', expected={'accepted': False} if expected is None else expected)
    return case


def cases():
    result = []
    for function, inquiry in [*FUNCTIONS.items(), (0x69, 0x30)]:
        for index, cls in enumerate(['sn0.a', 'sn0.c', 'sn0.b']):
            case = _case(f'read.{function}.{index}', 'read', function, index=index)
            builder = _call(case['calls'], case['id'] + ':builder', cls + '$b', '<init>')
            obj = _call(case['calls'], 'object', cls + '$b', 'f', [PARAM + 'NcAsmInquiredType'],
                        [{'enum': PARAM + 'NcAsmInquiredType', 'name': INQUIRIES[inquiry]}], builder)
            _get(case, 'payload', cls, 'd', obj)
            result.append(case)
        for command, value in product([0x63, 0x65], [0, 1]):
            result.append(_available(function, bytes([command, inquiry, value])))
        for payload in [bytes([0x63, inquiry]), bytes([0x63, inquiry, 0, 0]), bytes([0x63, inquiry, 255])]:
            result.append(_boundary(_available(function, payload), {'available': None}))
        if inquiry == 0x30:
            continue
        if inquiry == 1:
            capabilities = [bytes([0x61, inquiry])]
        elif inquiry in (0x11, 0x12):
            capabilities = [bytes([0x61, inquiry, len(modes), *modes]) for modes in [[], [0], [1], [0, 1], [1, 0]]]
        else:
            capabilities = [bytes([0x61, inquiry, 0])]
            for minimum, maximum, step in [(0, 1, 1), (1, 20, 1), (2, 22, 2), (0, 127, 3), (128, 255, 1), (254, 255, 255)]:
                for modes in [[0], [1], [0, 1], [1, 0]]:
                    capabilities.append(bytes([0x61, inquiry, len(modes)] + [value for mode in modes for value in [mode, minimum, maximum, step]]))
        result.extend(_capability(function, payload) for payload in capabilities)
        if inquiry == 1:
            tails = [[value] for value in [0, 1]]
        elif inquiry in (0x11, 0x12):
            tails = list(product(range(2 if inquiry == 0x11 else 6), [0, 1], [0, 1]))
        elif inquiry in (0x13, 0x14):
            tails = list(product(range(2 if inquiry == 0x13 else 6), [0, 1], [0, 1, 20, 127, 128, 255]))
        elif inquiry == 0x16:
            tails = list(product([0, 1], range(6), [0, 1], [0, 1, 20, 127, 128, 255]))
        else:
            tails = list(product(range(3), [0, 1], [0, 1, 20, 127, 128, 255]))
        for command, effect, tail in product([0x67, 0x69], [0, 1], tails):
            result.append(_state(function, bytes([command, inquiry, 1, effect, *tail])))
        for tail in tails:
            initial = bytes([0x67, inquiry, 1, 1, *tail])
            result.append(_write(function, initial, tail))
        tail = [1] if inquiry == 1 else [1, 2, 0, 20] if inquiry == 0x16 else [1, 0, 1 if inquiry in (0x11, 0x12) else 20]
        initial = bytes([0x67, inquiry, 1, 1, *tail])
        result.append(_write(function, initial, [0] if inquiry == 1 else tail, effect=0, mode='off'))
        if inquiry == 1:
            result.append(_write(function, initial, [1], mode='anc'))
        else:
            ambient = list(tail)
            ambient[0] = 0 if inquiry <= 0x14 else 1
            result.append(_write(function, initial, ambient, mode='ambient'))
            anc = list(tail)
            anc[0] = 1 if inquiry in (0x11, 0x13) else 2 if inquiry in (0x12, 0x14) else 0
            if inquiry <= 0x14:
                anc[-1] = 0
            if inquiry == 0x16:
                anc[1] = 2
            result.append(_write(function, initial, anc, mode='anc'))
            if inquiry in (0x12, 0x14, 0x16):
                wind = list(anc)
                wind[1 if inquiry == 0x16 else 0] = 1
                result.append(_write(function, initial, wind, mode='wind'))
            focus = list(tail)
            focus[-2] = 1
            result.append(_write(function, initial, focus, focusOnVoice=True))
            if inquiry not in (0x11, 0x12):
                for value in [0, 1, 20, 127, 128, 255]:
                    ambient = list(tail)
                    ambient[-1] = value
                    result.append(_write(function, initial, ambient, ambientLevel=value))
            if inquiry == 0x18:
                for enabled in [False, True]:
                    special = list(tail)
                    special[0] = 2 if enabled else 0
                    result.append(_write(function, initial, special, noiseCancellingSS=enabled))
        for factory, payload in [(_capability, capabilities[-1]), (_state, initial)]:
            for length in range(2, len(payload)):
                result.append(_boundary(factory(function, payload[:length])))
            result.append(_boundary(factory(function, payload + b'\x00')))
        for index in range(2, len(initial)):
            if index == len(initial) - 1 and inquiry not in (1, 0x11, 0x12):
                continue
            payload = bytearray(initial)
            payload[index] = 255
            result.append(_boundary(_state(function, bytes(payload))))
        changing = bytearray(initial)
        changing[2] = 0
        result.append(_boundary(_state(function, bytes(changing))))
        if inquiry != 1:
            width = 1 if inquiry in (0x11, 0x12) else 4
            record = bytes([0]) if width == 1 else bytes([0, 0, 20, 1])
            result.append(_boundary(_capability(function, bytes([0x61, inquiry, 2]) + record * 2)))
            result.append(_boundary(_capability(function, bytes([0x61, inquiry, 1, 255]) + record[1:])))
            if width == 4:
                for record in [[0, 255, 255, 1], [0, 0, 0, 1], [0, 0, 20, 0], [0, 20, 10, 1]]:
                    result.append(_boundary(_capability(function, bytes([0x61, inquiry, 1, *record]))))
    for key in range(6):
        result.append(_toggle('toggleCapability', bytes([0x61, 0x30, key])))
    for command, value in product([0x67, 0x69], range(1, 5)):
        result.append(_toggle('toggleState', bytes([command, 0x30, value])))
    for value, name in enumerate(['NC_ASM_OFF', 'NC_ASM', 'NC_OFF', 'ASM_OFF'], 1):
        case = _case(f'toggleSet.{value}', 'toggleSet', 0x69, value=value)
        builder = _call(case['calls'], case['id'] + ':builder', 'sn0.g1$b', '<init>')
        obj = _call(case['calls'], 'object', 'sn0.g1$b', 'f', [SYSTEM + 'Function'], [{'enum': SYSTEM + 'Function', 'name': name}], builder)
        _get(case, 'payload', 'sn0.g1', 'd', obj)
        result.append(case)
    for operation, command, invalid in [('toggleCapability', 0x61, [6, 255]), ('toggleState', 0x67, [0, 5, 80, 255])]:
        for payload in [bytes([command, 0x30]), bytes([command, 0x30, 1, 0])] + [bytes([command, 0x30, value]) for value in invalid]:
            result.append(_boundary(_toggle(operation, payload)))
    case = _case('testRead', 'testRead', 0x6C)
    builder = _call(case['calls'], case['id'] + ':builder', 'sn0.c$b', '<init>')
    obj = _call(case['calls'], 'object', 'sn0.c$b', 'f', [PARAM + 'NcAsmInquiredType'], [{'enum': PARAM + 'NcAsmInquiredType', 'name': 'NC_TEST_MODE'}], builder)
    _get(case, 'payload', 'sn0.c', 'd', obj)
    result.append(case)
    for command, value in product([0x63, 0x65], [0, 1]):
        result.append(_test(bytes([command, 0x40, value])))
    for start in [False, True]:
        case = _case(f'testSet.{start}', 'testSet', 0x6C, start=start)
        builder = _call(case['calls'], case['id'] + ':builder', 'sn0.o1$b', '<init>')
        obj = _call(case['calls'], 'object', 'sn0.o1$b', 'h', [PARAM + 'NcTestModeOperation'],
                    [{'enum': PARAM + 'NcTestModeOperation', 'name': 'TEST_MODE_START' if start else 'TEST_MODE_FINISH'}], builder)
        _get(case, 'payload', 'sn0.o1', 'd', obj)
        result.append(case)
    for payload in [bytes([0x63, 0x40]), bytes([0x63, 0x40, 0, 0]), bytes([0x63, 0x40, 255])]:
        result.append(_boundary(_test(payload), {'active': None}))
    for command, effect, mode, value in product([0x67, 0x69], [0, 1], [0, 1], [2, 3, 4, 5]):
        result.append(_auto_mode(bytes([command, 0x15, 1, effect, mode, value, 0, 9])))
    return result


def normalize(case, results):
    values = {key: results[value] for key, value in case['oracle'].items()}
    operation = case['swift']['op'].split('.')[-1]
    if operation in ('read', 'set', 'toggleSet', 'testRead', 'testSet'):
        return {'payload': values['payload']['bytes']}
    if operation == 'available':
        return {'available': values['available'] == 0}
    if operation == 'toggleCapability':
        return {'key': values['key'], 'options': [1, 2, 3, 4]}
    if operation == 'toggleState':
        return {'selected': values['selected']}
    if operation == 'test':
        return {'active': values['active'] == 0}
    if operation == 'autoMode':
        mode = values['mode']
        return {'mode': {'off': 'off', 'asm': 'ambient', 'auto': 'wind', 'nc': 'anc'}[mode.split()[0]]}
    inquiry = FUNCTIONS[case['swift']['function']]
    if values.get('valid') is False or values.get('headerValid') is False:
        return {'accepted': False}
    if operation == 'capability':
        return {'records': sorted([{'mode': values[f'mode{index}'],
                                   'minimum': values.get(f'minimum{index}', 0),
                                   'maximum': values.get(f'maximum{index}', 1),
                                   'step': values.get(f'step{index}', 1)}
                                  for index in range(values.get('count', 0))], key=lambda record: record['mode'])}
    if operation == 'state':
        if inquiry == 0x11:
            payload = bytes([0x67, inquiry, values['change'], values['effect'], *[values[key] for key, *_ in TAILS[inquiry]]])
        else:
            payload = bytes.fromhex(values['payload']['bytes'])
            payload = b'\x67' + payload[1:]
        return {'payload': payload.hex(), 'effectEnabled': values['effect'] == 1,
                'ambientMode': values.get('ambientMode', 0), 'ambientLevel': values.get('ambientLevel', 0),
                'noiseValue': values.get('noiseValue'),
                'ncAsmMode': values.get('ncAsmMode', 1 if values.get('noiseValue') == 0 else 0),
                'noiseCancellingSS': inquiry == 0x18 and values['effect'] == 1 and values['ncAsmMode'] == 2}
    raise ValueError(operation)


def unsupported():
    return [
        {'schema': 'Noise inquiry 11 stripped wrappers', 'reason': 'The original generic capability and parameter dispatch omit inquiry 11. Its retained un0.a and un0.o validators/accessors and sn0.l1 typed serializer provide the oracle for this variant.'},
        {'schema': 'Noise changing and malformed state', 'reason': 'Swift clears state while ValueChangeStatus is UNDER_CHANGING and rejects malformed capabilities, duplicate modes, and reversed ranges. These are boundary checks; the APK allows changing state and some malformed capability combinations.'},
        {'schema': 'Noise capability and setter policy', 'reason': 'Typed APK serializers validate wire fields independently of capability ranges. Swift additionally requires current capability, availability, and state. Differential write cases use available state and a complete capability range.'},
    ]


def mutations():
    return [
        {'name': 'modern noise function 63 uses on-off inquiry',
         'replacement': ('SonyNoiseControl.swift', '0x63: 0x12', '0x63: 0x11'),
         'case_ids': ['modern_noise.read.99.0']},
        {'name': 'modern noise toggle selected options exclude fourth option',
         'replacement': ('SonyNoiseControl.swift', '(1...4).contains(payload[2])', '(1...3).contains(payload[2])'),
         'case_ids': ['modern_noise.toggleState.673004']},
        {'name': 'modern noise test operation polarity reversed',
         'replacement': ('SonyNoiseControl.swift', 'start ? 0 : 1', 'start ? 1 : 0'),
         'case_ids': ['modern_noise.testSet.True']},
    ]

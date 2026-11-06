from legacy import _call, _get


FUNCTION = 'com.sony.songpal.tandemfamily.message.mdr.v2.FunctionType'
COMMON_PARAM = 'com.sony.songpal.tandemfamily.message.mdr.v2.table1.common.param.CommonInquiredType'
FEATURES = [
    ('common', 1, 0x19, 'PHONE_AND_CONNECTED_DEVICE_INFOMATION_FOR_CLASSIC', bytes([0x10, 0x07])),
    ('tws', 1, 0x40, 'TWS_SUPPORTS_A2DP_LEA_UNI_LEA_BROAD_WITH_CTKD', bytes([0x40, 0x00])),
    ('hbs', 1, 0x41, 'HBS_SUPPORTS_A2DP_LEA_UNI_LEA_BROAD_WITH_CTKD', bytes([0x40, 0x01])),
    ('pas', 2, 0x64, 'PAS_SUPPORTS_A2DP_LEA_UNI_LEA_BROAD_WITH_CTKD', bytes([0x60, 0x04])),
]


def _case(identifier, operation, **inputs):
    return {'id': 'connection_identity.' + identifier,
            'swift': {'op': 'connectionIdentity.' + operation, **inputs},
            'calls': [], 'oracle': {}}


def _query(case, name):
    if name == 'common':
        builder = _call(case['calls'], case['id'] + ':commonBuilder' if not case['calls'] else 'commonBuilder', 'hn0.a$b', '<init>')
        obj = _call(case['calls'], 'commonQuery', 'hn0.a$b', 'g', [COMMON_PARAM],
                    [{'enum': COMMON_PARAM, 'name': 'SMART_PHONE_AND_CONNECTED_DEVICE_INFORMATION'}], builder)
        _get(case, 'commonPayload', 'hn0.a', 'd', obj)
        return
    cls, value_cls = {'tws': ('ij0.d', 'ij0.c'), 'hbs': ('ij0.b', 'ij0.a'), 'pas': ('qj0.d', 'qj0.c')}[name]
    serializer = _call(case['calls'], case['id'] + ':' + name + 'Serializer' if not case['calls'] else name + 'Serializer', cls, '<init>')
    obj = _call(case['calls'], name + 'Query', value_cls, '<init>')
    case['oracle'][name + 'Payload'] = _call(case['calls'], name + 'Payload', cls, 'b',
                                          [value_cls], [{'ref': obj}], serializer)


def _queries(identifier, frame_type, functions, functions2):
    case = _case('queries.' + identifier, 'queries', frameType=frame_type, functions=functions, functions2=functions2)
    case['coverage_ids'] = [f'mdr-v2-t{table}-{function:02x}.{stage}'
                            for _, table, function, _, _ in FEATURES for stage in ['capability', 'serializer']]
    for table, codes in [(1, functions), (2, functions2)]:
        for index, function in enumerate(codes):
            key = f'function{table}.{index}'
            case['oracle'][key] = _call(case['calls'], case['id'] + ':' + key if not case['calls'] else key, FUNCTION, 'fromByteCode',
                                        [FUNCTION + '$Table', 'byte'],
                                        [{'enum': FUNCTION + '$Table', 'name': f'NO_{table}'}, function])
    for name, _, _, _, _ in FEATURES:
        _query(case, name)
    return case


def _parse(identifier, feature, payload, **inputs):
    name, table, function, _, _ = feature
    defaults = {'frameType': 0x0C if table == 1 else 0x0E,
                'functions': [function] if table == 1 else [], 'functions2': [function] if table == 2 else []}
    case = _case(name + '.' + identifier, 'parse', payload=payload.hex(), **(defaults | inputs))
    case['feature'] = name
    case['coverage_ids'] = [f'mdr-v2-t{table}-{function:02x}.parser']
    if name == 'common':
        builder = _call(case['calls'], case['id'] + ':parser', 'hn0.m$b', '<init>')
        obj = _call(case['calls'], 'object', 'hn0.m$b', 'f', ['byte[]'], [{'bytes': payload.hex()}], builder)
        _get(case, 'host', 'hn0.m', 'e', obj)
        _get(case, 'address0', 'hn0.m', 'c', obj)
    else:
        parser_cls, cls, getters = {'tws': ('ij0.l0', 'ij0.k0', ['c', 'a', 'b']),
                                    'hbs': ('ij0.j0', 'ij0.i0', ['b', 'a']),
                                    'pas': ('qj0.t', 'qj0.s', ['b', 'a'])}[name]
        parser = _call(case['calls'], case['id'] + ':parser', parser_cls, '<init>')
        obj = _call(case['calls'], 'object', parser_cls, 'a', ['byte[]'], [{'bytes': payload.hex()}], parser)
        for index, getter in enumerate(getters):
            _get(case, f'address{index}', cls, getter, obj)
    _query(case, name)
    return case


def _boundary(case, expected=None):
    case.update(category='malformed', expected={'accepted': False} if expected is None else expected)
    return case


def cases():
    result = []
    for mask in range(16):
        functions = [function for index, (_, table, function, _, _) in enumerate(FEATURES) if table == 1 and mask & (1 << index)]
        functions2 = [function for index, (_, table, function, _, _) in enumerate(FEATURES) if table == 2 and mask & (1 << index)]
        for frame_type in [0x0C, 0x0E]:
            result.append(_queries(f'{frame_type}.{mask}', frame_type, functions, functions2))
    for frame_type in [0x0C, 0x0E]:
        result.append(_queries(f'wrong-table-capabilities.{frame_type}', frame_type, [0x64], [0x19, 0x40, 0x41]))
    for frame_type in [0x01, 0x0D, 0x0F, 0x1C, 0x2C]:
        result.append(_boundary(_queries(f'unsupported-frame.{frame_type}', frame_type, [0x19, 0x40, 0x41], [0x64]),
                                {'payloads': []}))

    samples = [
        ['01:23:45:67:89:AB', '10:32:54:76:98:BA', 'CD:EF:01:23:45:67'],
        ['01:23:45:67:89:ab', 'aB:cD:eF:01:23:45', 'cd:ef:01:23:45:67'],
        ['00:00:00:00:00:00'] * 3,
        ['FF:FF:FF:FF:FF:FF'] * 3,
        ['01:23:45:67:89:AB'] * 3,
    ]
    for feature in FEATURES:
        name, table, function, _, query = feature
        count = 3 if name == 'tws' else 2
        prefix = bytes([query[0] + 1, query[1]])
        for index, addresses in enumerate(samples):
            payload = prefix + ''.join(addresses[:count]).encode('ascii')
            result.append(_parse(f'valid.{index}', feature, payload))
        payload = prefix + ''.join(samples[0][:count]).encode('ascii')
        result.append(_parse('combined-capabilities', feature, payload, functions=[0x19, 0x40, 0x41], functions2=[0x64]))
        for length in range(len(payload)):
            result.append(_boundary(_parse(f'truncated.{length}', feature, payload[:length])))
        for suffix in [b'\x00', b'\x00\x01']:
            result.append(_boundary(_parse('trailing.' + suffix.hex(), feature, payload + suffix)))
        for index, values in [(0, [0x10, 0x40, 0x60, 0xFF]), (1, [0x00, 0x01, 0x04, 0x07, 0xFF])]:
            for value in values:
                if value == payload[index]:
                    continue
                invalid = bytearray(payload)
                invalid[index] = value
                result.append(_boundary(_parse(f'field.{index}.{value}', feature, bytes(invalid))))
        for address_index in range(count):
            for index in range(17):
                invalid = bytearray(payload)
                invalid[2 + address_index * 17 + index] = ord('-') if index % 3 == 2 else ord('G')
                result.append(_boundary(_parse(f'address.{address_index}.{index}', feature, bytes(invalid))))
            for value in [0x00, 0x80, 0xFF]:
                invalid = bytearray(payload)
                invalid[2 + address_index * 17] = value
                result.append(_boundary(_parse(f'address-byte.{address_index}.{value}', feature, bytes(invalid))))
        for frame_type in [0x01, 0x0C, 0x0D, 0x0E, 0x0F, 0x1C, 0x2C]:
            if frame_type != (0x0C if table == 1 else 0x0E):
                result.append(_boundary(_parse(f'wrong-frame.{frame_type}', feature, payload, frameType=frame_type)))
        result.append(_boundary(_parse('unadvertised', feature, payload, functions=[], functions2=[])))
        result.append(_boundary(_parse('wrong-table-capability', feature, payload,
                                      functions=[] if table == 1 else [function],
                                      functions2=[function] if table == 1 else [])))
    return result


def normalize(case, results):
    values = {key: results[value] for key, value in case['oracle'].items()}
    if case['swift']['op'] == 'connectionIdentity.queries':
        frame_type = case['swift']['frameType']
        functions = {value['name'] for key, value in values.items() if key.startswith('function')}
        return {'payloads': sorted(values[name + 'Payload']['bytes'] for name, table, _, function, _ in FEATURES
                                    if function in functions and frame_type == (0x0C if table == 1 else 0x0E))}
    return {'accepted': True, 'queryPayload': values[case['feature'] + 'Payload']['bytes'],
            'addresses': sorted({value.upper() for key, value in values.items() if key.startswith('address')})}


def unsupported():
    return [
        {'schema': 'Connection identity strict validation',
         'reason': 'Acouplet additionally requires the advertised function in the matching table, the exact reply command, and ASCII colon-separated hexadecimal addresses. Kotlin identity parsers validate length and inquiry but accept arbitrary address text. These rejections are explicit boundary checks.'},
        {'schema': 'Connection identity application behavior',
         'reason': 'These checks compare original query serializers and capability parsers. Common capability host addresses are inspected separately and excluded from the headphone address set. Identity correlation with a paired device, session freshness and reconnection behavior require separate controller tests; no physical hardware is verified.'},
    ]


def mutations():
    return [
        {'name': 'common identity includes the host address',
         'replacement': ('SonyConnectionIdentity.swift',
                         'addresses = Set(query == [0x10, 0x07] ? Array(parsed.dropFirst()) : parsed)',
                         'addresses = Set(parsed)'),
         'case_ids': ['connection_identity.common.valid.0']},
        {'name': 'PAS identity capability gate changed',
         'replacement': ('SonyConnectionIdentity.swift', 'supportedFunctions2.contains(0x64)',
                         'supportedFunctions2.contains(0x65)'),
         'case_ids': ['connection_identity.queries.14.8', 'connection_identity.pas.valid.0']},
        {'name': 'identity address separators unchecked',
         'replacement': ('SonyConnectionIdentity.swift', 'index % 3 == 2 ? byte == 0x3A', 'index % 3 == 2 ? true'),
         'case_ids': ['connection_identity.common.address.0.2', 'connection_identity.tws.address.2.2',
                      'connection_identity.hbs.address.1.2', 'connection_identity.pas.address.1.2']},
    ]

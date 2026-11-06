from itertools import product
from legacy import _call, _get


PARAM = 'com.sony.songpal.tandemfamily.message.mdr.v2.table1.common.param.'


def _case(identifier, function, payload, functions=None):
    return {'id': 'common_connection.' + identifier,
            'swift': {'op': 'commonConnection.parse', 'payload': payload.hex(),
                      'functions': [function] if functions is None else functions},
            'calls': [], 'oracle': {}, 'coverage_ids': [f'mdr-v2-t1-{function:02x}.parser']}


def _reconnection(identifier, payload, functions=None):
    case = _case('reconnection.' + identifier, 0x1A, payload, functions)
    builder = _call(case['calls'], case['id'] + ':builder', 'hn0.c$b', '<init>')
    obj = _call(case['calls'], 'object', 'hn0.c$b', 'f', ['byte[]'], [{'bytes': payload.hex()}], builder)
    request_type = _get(case, 'requestTypeEnum', 'hn0.d', 'c', obj)
    _get(case, 'requestType', PARAM + 'RequestType', 'byteCode', request_type)
    _get(case, 'address', 'hn0.d', 'e', obj)
    return case


def _release(identifier, payload, functions=None):
    case = _case('release.' + identifier, 0x1C, payload, functions)
    parser = _call(case['calls'], case['id'] + ':parser', 'ej0.h', '<init>')
    obj = _call(case['calls'], 'object', 'ej0.h', 'a', ['byte[]'], [{'bytes': payload.hex()}], parser)
    _get(case, 'event', 'ej0.g', 'toString', obj)
    return case


def _boundary(case):
    case.update(category='malformed', expected={'accepted': False})
    return case


def cases():
    result = []
    addresses = ['00:00:00:00:00:00', 'FF:FF:FF:FF:FF:FF', '01:23:45:67:89:AB',
                 '01:23:45:67:89:ab', 'aB:cD:eF:01:23:45']
    for request_type, address in product([0, 1], addresses):
        payload = bytes([0x19, 0x08, request_type]) + address.encode('ascii')
        result.append(_reconnection(payload.hex(), payload))
    result.append(_release('190a', bytes([0x19, 0x0A])))
    payload = bytes([0x19, 0x08, 1]) + b'01:23:45:67:89:AB'
    result.append(_reconnection('combined-capabilities', payload, [0x1A, 0x1C]))
    result.append(_release('combined-capabilities', bytes([0x19, 0x0A]), [0x1A, 0x1C]))
    for length in range(len(payload)):
        result.append(_boundary(_reconnection(f'truncated.{length}', payload[:length])))
    for suffix in [b'\x00', b'\x00\x01']:
        result.append(_boundary(_reconnection('trailing.' + suffix.hex(), payload + suffix)))
    for index, values in [(0, [0x18, 0x1B, 0x00, 0xFF]), (1, [0x00, 0x07, 0x09, 0x0A, 0xFF]),
                          (2, [2, 127, 128, 255])]:
        for value in values:
            invalid = bytearray(payload)
            invalid[index] = value
            result.append(_boundary(_reconnection(f'field.{index}.{value}', bytes(invalid))))
    for index in range(17):
        invalid = bytearray(payload)
        invalid[index + 3] = ord('-') if index % 3 == 2 else ord('G')
        result.append(_boundary(_reconnection(f'address.{index}', bytes(invalid))))
    for value in [0x00, 0x80, 0xFF]:
        invalid = bytearray(payload)
        invalid[3] = value
        result.append(_boundary(_reconnection(f'address-byte.{value}', bytes(invalid))))
    for functions in [[], [0x1C], [0x19, 0x1B]]:
        result.append(_boundary(_reconnection('unsupported.' + str(functions), payload, functions)))
    for invalid in [b'', b'\x19', b'\x19\x0A\x00', b'\x19\x0A\x00\x01',
                    b'\x18\x0A', b'\x1B\x0A', b'\x00\x0A', b'\xFF\x0A',
                    b'\x19\x00', b'\x19\x08', b'\x19\x09', b'\x19\xFF']:
        result.append(_boundary(_release('invalid.' + invalid.hex(), invalid)))
    for functions in [[], [0x1A], [0x1B, 0x1D]]:
        result.append(_boundary(_release('unsupported.' + str(functions), bytes([0x19, 0x0A]), functions)))
    return result


def normalize(case, results):
    values = {key: results[value] for key, value in case['oracle'].items()}
    if 'event' in values:
        return {'event': values['event']}
    return {'requestType': values['requestType'], 'address': values['address'].upper()}


def unsupported():
    return [
        {'schema': 'Common connection strict validation',
         'reason': 'Acouplet requires the advertised capability, exact payload length, known request type, command 0x19 and a colon-separated hexadecimal address. Some original parsers accept looser inputs. Rejection cases are boundary checks; valid address comparison normalizes hexadecimal letter case.'},
        {'schema': 'Common connection lifecycle',
         'reason': 'These checks compare notification parsing. Session identity, acknowledgment order, reconnection, GATT ownership and production BLE availability require separate controller evidence; no serializer or user-interface claim is made.'},
    ]


def mutations():
    return [
        {'name': 'common connection notification command changed',
         'replacement': ('SonyCommonConnection.swift', 'payload[0] == 0x19', 'payload[0] == 0x18'),
         'case_ids': [case['id'] for case in cases() if case.get('category') != 'malformed']},
        {'name': 'common connection request type reversed',
         'replacement': ('SonyCommonConnection.swift', 'RequestType(rawValue: payload[2])', 'RequestType(rawValue: payload[2] ^ 0x01)'),
         'case_ids': [case['id'] for case in cases() if '.reconnection.' in case['id'] and case.get('category') != 'malformed']},
        {'name': 'common connection GATT capability gate changed',
         'replacement': ('SonyCommonConnection.swift', 'supportedFunctions.contains(0x1C)', 'supportedFunctions.contains(0x1A)'),
         'case_ids': ['common_connection.release.190a', 'common_connection.release.unsupported.[26]']},
        {'name': 'common connection GATT trailing bytes accepted',
         'replacement': ('SonyCommonConnection.swift', 'supportedFunctions.contains(0x1C), payload.count == 2',
                         'supportedFunctions.contains(0x1C), payload.count >= 2'),
         'case_ids': ['common_connection.release.invalid.190a00']},
        {'name': 'common connection address separators unchecked',
         'replacement': ('SonyCommonConnection.swift', 'index % 3 == 2 ? byte == 0x3A', 'index % 3 == 2 ? true'),
         'case_ids': ['common_connection.reconnection.address.2']},
    ]

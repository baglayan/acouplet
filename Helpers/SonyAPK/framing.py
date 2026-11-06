import random


def cases():
    result = []
    randomizer = random.Random(0x534F4E59)
    payloads = [b'', bytes(range(256)), bytes([0x3C, 0x3D, 0x3E]) * 90]
    payloads += [bytes([value]) for value in range(256)]
    payloads += [randomizer.randbytes(length) for length in (2, 7, 31, 255, 256, 1024, 4096)]
    for index, payload in enumerate(payloads):
        for sequence in (0, 1):
            identifier = f'frame-{index}-{sequence}'
            frame_type = (0x0C, 0x0E, 0x1C, 0x1E, 0x2C)[index % 5]
            result.append({
                'id': identifier,
                'swift': {'op': 'frame.encode', 'type': frame_type,
                          'sequence': sequence, 'payload': payload.hex()},
                'calls': [{'id': identifier, 'op': 'frame', 'type': frame_type,
                           'sequence': sequence, 'payload': payload.hex(), 'mtu': (17, 65536)[index % 2]}],
                'oracle': {'encoded': identifier},
            })
    for sequence in (0, 1):
        identifier = f'ack-{sequence}'
        result.append({'id': identifier, 'swift': {'op': 'frame.encode', 'type': 1,
                       'sequence': sequence, 'payload': ''},
                       'calls': [{'id': identifier, 'op': 'ack', 'sequence': sequence}],
                       'oracle': {'encoded': identifier}})
    data_type = 'com.sony.songpal.tandemfamily.message.DataType'
    for value in range(256):
        identifier = f'frame-ack-required-{value}'
        result.append({'id': identifier, 'swift': {'op': 'frame.ackRequired', 'type': value},
                       'calls': [{'id': identifier + '-type', 'class': data_type, 'method': 'fromByteCode',
                                  'types': ['byte'], 'args': [value]},
                                 {'id': identifier, 'target': identifier + '-type', 'class': data_type,
                                  'method': 'ackRequired', 'types': [], 'args': []}],
                       'oracle': {'required': identifier}})
    return result


def normalize(case, results):
    return {key: results[identifier]['bytes'] if key == 'encoded' else results[identifier]
            for key, identifier in case['oracle'].items()}

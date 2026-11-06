from legacy import _call, _get


PARAM = 'com.sony.songpal.tandemfamily.message.mdr.v2.table1.playback.param.'
COMMON = 'com.sony.songpal.tandemfamily.message.mdr.v2.'
INQUIRIES = {
    1: 'PLAYBACK_CONTROL_WITH_CALL_VOLUME_ADJUSTMENT',
    2: 'PLAYBACK_CONTROL_WITH_CALL_VOLUME_ADJUSTMENT_AND_FUNCTION_CHANGE',
    3: 'PLAYBACK_CONTROL_WITH_FUNCTION_CHANGE',
    0x20: 'MUSIC_VOLUME', 0x21: 'CALL_VOLUME',
    0x30: 'MUSIC_VOLUME_WITH_MUTE', 0x31: 'CALL_VOLUME_WITH_MUTE',
}


def _case(identifier, operation, function, **inputs):
    return {'id': 'modern_playback.' + identifier,
            'swift': {'op': 'modernPlayback.' + operation, 'function': function, **inputs},
            'calls': [], 'oracle': {},
            'coverage_ids': [f'mdr-v2-t1-{function:02x}.' + ('serializer' if operation in ('read', 'set') else 'capability' if operation == 'capability' else 'parser')]}


def _parse(case, cls, method, payload):
    builder = _call(case['calls'], case['id'] + ':builder', cls + '$b', '<init>')
    return _call(case['calls'], 'object', cls + '$b', method, ['byte[]'], [{'bytes': payload.hex()}], builder)


def _enum_get(case, key, cls, method, obj, enum):
    value = _get(case, key + 'Enum', cls, method, obj)
    _get(case, key, enum, 'byteCode', value)


def _capability(function, payload):
    case = _case(f'capability.{function}.{payload.hex()}', 'capability', function, payload=payload.hex())
    cls, method = ('wn0.q', 'f') if function == 0xA4 else ('wn0.p', 'g')
    obj = _parse(case, cls, method, payload)
    _get(case, 'musicSteps', cls, 'e' if function == 0xA4 else 'f', obj)
    if function != 0xA4:
        _get(case, 'callSteps', cls, 'e', obj)
    return case


def _status(function, payload):
    case = _case(f'status.{function}.{payload.hex()}', 'status', function, payload=payload.hex())
    notify = payload[0] == 0xA5
    inquiry = payload[1]
    cls, available, state, call, control = {
        (1, False): ('wn0.a0', 'f', 'e', 'c', None),
        (1, True): ('wn0.m', 'g', 'f', 'e', None),
        (2, False): ('wn0.y', 'g', 'f', 'c', 'e'),
        (2, True): ('wn0.k', 'h', 'g', 'e', 'f'),
        (3, False): ('wn0.z', 'f', 'e', None, 'c'),
        (3, True): ('wn0.l', 'g', 'f', None, 'e'),
    }[(inquiry, notify)]
    obj = _parse(case, cls, 'g', payload)
    _enum_get(case, 'available', cls, available, obj, COMMON + 'EnableDisable')
    _enum_get(case, 'state', cls, state, obj, PARAM + 'PlaybackStatus')
    if call:
        _enum_get(case, 'musicCall', cls, call, obj, PARAM + 'MusicCallStatus')
    if control:
        _enum_get(case, 'controlAvailable', cls, control, obj, COMMON + 'EnableDisable')
    return case


def _volume(function, payload):
    case = _case(f'volume.{function}.{payload.hex()}', 'volume', function, payload=payload.hex())
    notify = payload[0] == 0xA9
    muted = function == 0xA2
    cls, getter, mute_getter = {
        (False, False): ('wn0.u', 'c', None), (True, False): ('wn0.g', 'e', None),
        (False, True): ('wn0.v', 'e', 'c'), (True, True): ('wn0.h', 'f', 'e'),
    }[(notify, muted)]
    obj = _parse(case, cls, 'g', payload)
    _get(case, 'volume', cls, getter, obj)
    if muted:
        _enum_get(case, 'muted', cls, mute_getter, obj, COMMON + 'OnOffSettingValue')
    return case


def _track(function, payload):
    case = _case(f'track.{function}.{payload.hex()}', 'track', function, payload=payload.hex())
    cls = 'wn0.t' if payload[0] == 0xA7 else 'wn0.f'
    obj = _parse(case, cls, 'g', payload)
    names = _get(case, 'names', cls, 'c' if payload[0] == 0xA7 else 'e', obj)
    for index in range(4):
        item = _call(case['calls'], f'name{index}', 'java.util.List', 'get', ['int'], [index], names)
        _get(case, f'text{index}', 'xn0.a', 'f', item)
        _enum_get(case, f'status{index}', 'xn0.a', 'g', item, PARAM + 'PlaybackNameStatus')
    return case


def _boundary(case):
    case.update(category='malformed', expected={'accepted': False})
    return case


def cases():
    result = []
    for function in range(0xA1, 0xA5):
        inquiry = {0xA1: 1, 0xA2: 1, 0xA3: 2, 0xA4: 3}[function]
        volumes = [0x30, 0x31] if function == 0xA2 else [0x20] if function == 0xA4 else [0x20, 0x21]
        queries = [(0xA0, inquiry), (0xA2, inquiry), (0xA6, inquiry)] + [(0xA6, value) for value in volumes]
        for index, (command, value) in enumerate(queries):
            case = _case(f'read.{function}.{index}', 'read', function, index=index)
            cls = {0xA0: 'wn0.a', 0xA2: 'wn0.c', 0xA6: 'wn0.b'}[command]
            builder = _call(case['calls'], case['id'] + ':builder', cls + '$b', '<init>')
            obj = _call(case['calls'], 'object', cls + '$b', 'f', [PARAM + 'PlayInquiredType'],
                        [{'enum': PARAM + 'PlayInquiredType', 'name': INQUIRIES[value]}], builder)
            _get(case, 'payload', cls, 'd', obj)
            result.append(case)
        for steps in [1, 31, 128, 255]:
            payload = bytes([0xA1, inquiry, steps] + ([] if function == 0xA4 else [steps]))
            result.append(_capability(function, payload))
        for command in [0xA3, 0xA5]:
            for available in [0, 1]:
                for state in range(4):
                    for call in ([None] if function == 0xA4 else [0, 1]):
                        for control in ([0, 1] if inquiry != 1 else [None]):
                            payload = bytes([command, inquiry, available, state]
                                            + ([] if call is None else [call]) + ([] if control is None else [control]))
                            result.append(_status(function, payload))
        for command in [0xA7, 0xA9]:
            for volume in volumes:
                for value in [0, 1, 127, 128, 254]:
                    for mute in ([0, 1] if function == 0xA2 else [None]):
                        payload = bytes([command, volume, value] + ([] if mute is None else [mute]))
                        result.append(_volume(function, payload))
            for status in [0, 1, 2]:
                for text in ['', 'Title', 'İstanbul 🎧', 'x' * 128]:
                    name = bytes([status, len(text.encode())]) + text.encode()
                    result.append(_track(function, bytes([command, inquiry]) + name * 4))
            names = b''.join(bytes([2, len(text)]) + text for text in [b'Title', b'Album', b'Artist', b'Genre'])
            result.append(_track(function, bytes([command, inquiry]) + names))
        for command, name in [(1, 'PAUSE'), (2, 'TRACK_UP'), (3, 'TRACK_DOWN'), (7, 'PLAY')]:
            case = _case(f'set.command.{function}.{command}', 'set', function, command=command)
            builder = _call(case['calls'], case['id'] + ':builder', 'wn0.f0$b', '<init>')
            obj = _call(case['calls'], 'object', 'wn0.f0$b', 'i',
                        [PARAM + 'PlayInquiredType', COMMON + 'EnableDisable', PARAM + 'PlaybackControl'],
                        [{'enum': PARAM + 'PlayInquiredType', 'name': INQUIRIES[3 if function == 0xA4 else 1]},
                         {'enum': COMMON + 'EnableDisable', 'name': 'ENABLE'},
                         {'enum': PARAM + 'PlaybackControl', 'name': name}], builder)
            _get(case, 'payload', 'wn0.f0', 'd', obj)
            result.append(case)
        for volume in volumes:
            for value in [0, 1, 127, 128, 254]:
                case = _case(f'set.volume.{function}.{volume}.{value}', 'set', function, value=value, call=volume in (0x21, 0x31))
                builder = _call(case['calls'], case['id'] + ':builder', 'wn0.d0$b', '<init>')
                obj = _call(case['calls'], 'object', 'wn0.d0$b', 'i', [PARAM + 'PlayInquiredType', 'int'],
                            [{'enum': PARAM + 'PlayInquiredType', 'name': INQUIRIES[volume]}, value], builder)
                _get(case, 'payload', 'wn0.d0', 'd', obj)
                result.append(case)
        valid_capability = bytes([0xA1, inquiry, 31] + ([] if function == 0xA4 else [16]))
        valid_status = bytes([0xA3, inquiry, 0, 1] + ([] if function == 0xA4 else [0]) + ([] if inquiry == 1 else [0]))
        valid_volume = bytes([0xA7, volumes[0], 12] + ([1] if function == 0xA2 else []))
        valid_track = bytes([0xA7, inquiry]) + bytes([2, 1, 65]) * 4
        for factory, payload in [(_capability, valid_capability), (_status, valid_status), (_volume, valid_volume), (_track, valid_track)]:
            for length in range(2, len(payload)):
                result.append(_boundary(factory(function, payload[:length])))
            result.append(_boundary(factory(function, payload + b'\x00')))
        for index in range(2, len(valid_status)):
            invalid = bytearray(valid_status)
            invalid[index] = 255
            case = _boundary(_status(function, bytes(invalid)))
            case['expected'] = {
                'available': None if index == 2 else True,
                'state': None if index == 3 else 1,
                'musicCall': (255 if index == 4 else 0) if function != 0xA4 else None,
                'controlAvailable': (None if index == len(valid_status) - 1 else True) if inquiry != 1 else None,
            }
            result.append(case)
        result.append(_boundary(_capability(function, bytes([0xA1, inquiry, 0] + ([] if function == 0xA4 else [16])))))
        case = _boundary(_track(function, bytes([0xA7, inquiry, 3, 1, 65]) + bytes([1, 0]) * 3))
        case['expected'] = {'names': [None] * 4}
        result.append(case)
        for name in [bytes([2, 129]) + b'a' * 129, bytes([2, 1, 255])]:
            result.append(_boundary(_track(function, bytes([0xA7, inquiry]) + name + bytes([1, 0]) * 3)))
        if function == 0xA2:
            case = _boundary(_volume(function, bytes([0xA7, 0x30, 12, 255])))
            case['expected'] = {'volume': 12, 'muted': None}
            result.append(case)
    return result


def normalize(case, results):
    values = {key: results[value] for key, value in case['oracle'].items()}
    operation = case['swift']['op'].split('.')[-1]
    if operation in ('read', 'set'):
        return {'payload': values['payload']['bytes']}
    if operation == 'capability':
        return {'musicSteps': values['musicSteps'], 'callSteps': values.get('callSteps')}
    if operation == 'status':
        return {'available': values['available'] == 0, 'state': values['state'], 'musicCall': values.get('musicCall'),
                'controlAvailable': values['controlAvailable'] == 0 if 'controlAvailable' in values else None}
    if operation == 'volume':
        return {'volume': values['volume'], 'muted': values['muted'] == 0 if 'muted' in values else None}
    if operation == 'track':
        return {'names': [values[f'text{index}'] if values[f'status{index}'] == 2 and values[f'text{index}'] else None for index in range(4)]}
    raise ValueError(operation)


def unsupported():
    return [
        {'schema': 'Playback unknown enum values', 'reason': 'Correctly shaped messages invalidate unknown status/name/mute fields rather than retaining stale known values. The APK rejects unknown enums. These cases are boundary checks; hasKnownStatus and relevant controls remain unavailable.'},
        {'schema': 'Mixed playback capabilities', 'reason': 'Swift preserves A1, then selects A2, A3, A4. This is application policy: APK consumers have different precedence and its acquisition layer initializes advertised variants independently.'},
        {'schema': 'Playback metadata malformed UTF-8', 'reason': 'Swift rejects malformed UTF-8; the APK decodes replacement characters. These cases are boundary checks, not equality claims.'},
        {'schema': 'Playback mute write', 'reason': 'APK volume-with-mute writes contain only a volume byte. Mute status is parsed; no independent mute toggle command is asserted.'},
        {'schema': 'Playback A3 command inquiry', 'reason': 'The generic APK builder accepts inquiry 2, but its actual shared d40.i sender emits inquiry 1 for A1/A2/A3. Swift follows the sender.'},
    ]


def mutations():
    return [
        {'name': 'modern playback mute inquiries replaced with ordinary volume inquiries',
         'replacement': ('SonyPlayback.swift', 'supportsMute = generation == .v2 && function == 0xA2', 'supportsMute = false'),
         'case_ids': ['modern_playback.read.162.3', 'modern_playback.read.162.4']},
        {'name': 'modern playback extra availability polarity reversed',
         'replacement': ('SonyPlayback.swift', 'playbackControlAvailable = value <= 1 ? value == 0 : nil',
                         'playbackControlAvailable = value <= 1 ? value == 1 : nil'),
         'case_ids': ['modern_playback.status.163.a30200010000', 'modern_playback.status.164.a303000100']},
        {'name': 'modern playback A3 command differs from original shared sender',
         'replacement': ('SonyPlayback.swift', 'playbackInquiryType == 3 ? 3 : 1, 0x00, command.rawValue',
                         'playbackInquiryType, 0x00, command.rawValue'),
         'case_ids': ['modern_playback.set.command.163.7']},
    ]

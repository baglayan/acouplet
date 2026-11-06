def cases():
    result = []
    schedules = [
        ([{'type': 12, 'payload': [16, 0]}], [0, 1]),
        ([{'type': 12, 'payload': [16, 0]}, {'type': 12, 'payload': [18, 0]}], [0, 1, 1, 0]),
        ([{'type': 12, 'payload': [16, 0]}, {'type': 14, 'payload': [166, 1]},
          {'type': 12, 'payload': [162, 1]}], [1, 0, 1]),
        ([{'type': 12, 'payload': [60, 61, 62]}, {'type': 14, 'payload': [0, 255]}], [0, 0, 1, 1, 1, 0]),
        ([{'type': 12, 'payload': [16, 0]}, {'type': 14, 'payload': [166, 1]}], [0]),
    ]
    for generation in (1, 2):
        for index, (commands, acknowledgments) in enumerate(schedules):
            identifier = f'queue-v{generation}-ack-{index}'
            result.append({
                'id': identifier,
                'swift': {'op': 'queue.ack', 'commands': commands, 'acknowledgments': acknowledgments},
                'calls': [{'id': identifier, 'op': 'queue', 'scenario': 'ack', 'generation': generation,
                           'commands': commands, 'acknowledgments': acknowledgments}],
            })
    return result


def normalize(case, results):
    return results[case['id']]


def evidence_calls():
    return [
        {'id': f'queue-v{generation}-retry-{retries}', 'op': 'queue', 'scenario': 'timeout',
         'generation': generation, 'command': {'type': 12, 'payload': [16, 0]}, 'retries': retries}
        for generation in (1, 2) for retries in (0, 2)
    ]


def unsupported():
    return [
        {'schema': 'synchronous GET scheduling',
         'reason': 'ACK cases execute the original transport gate only; k70.v0 and l70.m1 reply waits are not invoked.'},
        {'schema': 'controller retry policy and transport ownership',
         'reason': 'The Swift comparison executes SonyCommandQueue, whose controller owns timers, write completion, and response matching.'},
    ]

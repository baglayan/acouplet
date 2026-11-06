import argparse
from collections import Counter
from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import tempfile
import uuid

from runtime import APKOracle, APK_SHA256


ROOT = Path(__file__).resolve().parents[2]
SCENARIOS = ('reply_before_ack', 'ack_before_reply', 'withheld_reply', 'unrelated_reply',
             'cancel_reply_wait', 'cancel_ack_wait')
PRODUCTION_COMPARISONS = [
    {'property': 'A received reply does not release the outgoing ACK gate or reopen on ACK retry',
     'test': 'Tests/SonyCommandQueueTests.swift:testReadRetryDoesNotReopenAResponseAlreadyConsumedBeforeAcknowledgment'},
    {'property': 'The response owner can survive ACK and malformed or unrelated replies',
     'test': 'Tests/SonyProtocolTests.swift:testV2CapabilityOwnershipSurvivesACKAndMalformedReplies'},
    {'property': 'A wrong-table or malformed response does not discharge the owned discovery deadline',
     'test': 'Tests/SonyProtocolTests.swift:testMalformedAndWrongTableDiscoveryRepliesPreserveTheOwnedDeadline'},
    {'property': 'Swift feature response timeouts may retain ownership for a late reply',
     'test': 'Tests/SonySystemFeaturesTests.swift:testExpiredFeatureReadKeepsOwnershipUntilValidLateReplyAndFreshRead'},
    {'property': 'Swift feature cancellation may retain an admitted read until drained',
     'test': 'Tests/SonyLegacyOptimizerControllerTests.swift:testCancellationBeforeInitialWriteCompletionKeepsTheReadOwnerUntilDrained'},
]


def evidence_calls():
    return [{'id': f'get-reply-v{generation}-{scenario}', 'op': 'get_reply',
             'generation': generation, 'scenario': scenario}
            for generation in (1, 2) for scenario in SCENARIOS]


def expected_state(ack, reply, finished=False):
    return {'awaiting_ack': ack, 'reply_remaining': reply, 'listener_count': 0 if finished else 1,
            'worker_finished': finished}


def observation_errors(call, value):
    errors = []
    generation, scenario = call['generation'], call['scenario']
    for key, expected in [('generation', generation), ('scenario', scenario),
                          ('wrapper', 'k70.v0' if generation == 1 else 'l70.m1'),
                          ('method', 'b0' if generation == 1 else 'E0')]:
        if value.get(key) != expected:
            errors.append('Original wrapper identity differs: ' + key)
    returns_null = scenario in ('withheld_reply', 'cancel_reply_wait', 'cancel_ack_wait')
    if 'return_value' not in value or value['return_value'] != (None if returns_null else 1):
        errors.append('Unexpected wrapper return value')
    snapshots = value.get('snapshots', {})
    expected = {'initial': expected_state(True, 1),
                'finished': expected_state(scenario == 'cancel_ack_wait', 1 if returns_null else 0, True)}
    if scenario == 'reply_before_ack':
        expected['before_ack'] = expected_state(True, 0)
    if scenario in ('ack_before_reply', 'withheld_reply'):
        expected['before_reply'] = expected_state(False, 1)
    if scenario == 'unrelated_reply':
        expected['after_unrelated'] = expected_state(False, 1)
    if scenario == 'cancel_reply_wait':
        expected['before_interrupt'] = expected_state(False, 1)
    if scenario in ('withheld_reply', 'cancel_reply_wait'):
        expected['after_late_reply'] = expected['finished']
    if snapshots != expected:
        errors.append('Observed ACK/reply/listener lifecycle differs from the scenario')
    for key in ('connection_closed', 'transport_closed'):
        if value.get(key) != 0:
            errors.append('Original transport closed during the GET observation: ' + key)
    diagnostics = value.get('diagnostics', [])
    if scenario == 'withheld_reply':
        if len(diagnostics) != 1 or not diagnostics[0].startswith('NO response: '):
            errors.append('Withheld reply did not produce the original no-response diagnostic')
        elapsed = value.get('elapsed_after_ack_ns')
        if not isinstance(elapsed, int) or elapsed < 2_000_000_000:
            errors.append('Withheld reply returned before the original two-second post-ACK deadline')
    elif diagnostics:
        errors.append('Unexpected original no-response diagnostic')
    requests = value.get('requests', [])
    expected_request = {'type': 12, 'sequence': 0, 'payload': [0xE6, 1 if generation == 1 else 0]}
    if not requests or any(request != expected_request for request in requests):
        errors.append('Original wrapper sent an unexpected request or retry')
    events = value.get('events', [])
    inputs = [event['event'] for event in events if event.get('event') in ('input_ack', 'input_reply', 'interrupt')]
    expected_inputs = {
        'reply_before_ack': ['input_reply', 'input_ack'],
        'ack_before_reply': ['input_ack', 'input_reply'],
        'withheld_reply': ['input_ack', 'input_reply'],
        'unrelated_reply': ['input_ack', 'input_reply', 'input_reply'],
        'cancel_reply_wait': ['input_ack', 'interrupt', 'input_reply'],
        'cancel_ack_wait': ['interrupt'],
    }
    if inputs != expected_inputs[scenario]:
        errors.append('Injected reply/ACK/cancellation order differs from the scenario')
    replies = [event for event in events if event.get('event') == 'input_reply']
    expected_replies = [] if scenario == 'cancel_ack_wait' else [(False, scenario in ('withheld_reply', 'cancel_reply_wait'))]
    if scenario == 'unrelated_reply':
        expected_replies.insert(0, (True, False))
    expected_payloads = [[0xE7, 2 if unrelated else 1, 0, 1] if generation == 1
                         else [0xE7, 5 if unrelated else 0, 1] for unrelated, _ in expected_replies]
    if (len(replies) != len(expected_replies) or any(
            event.get('payload') != payload or event.get('unrelated') != unrelated
            or event.get('late') != late or event.get('sequence') != index % 2
            for index, (event, payload, (unrelated, late)) in enumerate(zip(replies, expected_payloads, expected_replies)))):
        errors.append('Injected reply payload, inquiry, sequence or late-delivery marker differs from the scenario')
    acknowledgments = [event.get('sequence') for event in events if event.get('event') == 'input_ack']
    if acknowledgments != ([] if scenario == 'cancel_ack_wait' else [1]):
        errors.append('Injected ACK did not match the original outgoing sequence')
    if scenario == 'cancel_reply_wait':
        observed = [index for index, event in enumerate(events) if event.get('event') == 'reply_wait_observed']
        interrupted = [index for index, event in enumerate(events) if event.get('event') == 'interrupt']
        if len(observed) != 1 or len(interrupted) != 1 or observed[0] >= interrupted[0]:
            errors.append('Cancellation did not establish the original reply wait before interrupting')
        else:
            stack = events[observed[0]].get('stack', [])
            wrapper_wait = 'k70.v0.W0(' if generation == 1 else 'l70.m1.K2('
            if (not any('java.util.concurrent.CountDownLatch.await(' in frame for frame in stack)
                    or not any(wrapper_wait in frame for frame in stack)
                    or any('lm0.c.n(' in frame for frame in stack)):
                errors.append('Cancellation stack does not identify the original wrapper reply wait')
    return errors


def evaluate(raw, calls):
    if (raw.get('apk_sha256') != APK_SHA256 or raw.get('class_loader') != 'dalvik.system.DexClassLoader'
            or not raw.get('serial', '').startswith('emulator-')):
        raise ValueError('Original APK runtime identity is missing or differs from the pinned emulator oracle')
    if [result['id'] for result in raw['results']] != [call['id'] for call in calls]:
        raise ValueError('Original APK returned missing, duplicate or reordered GET lifecycle results')
    checks = []
    for call, result in zip(calls, raw['results']):
        if not result['ok']:
            checks.append({'id': call['id'], 'status': 'oracle-error', 'error': result['error'],
                           'evidence_kind': 'original_apk_only'})
            continue
        errors = observation_errors(call, result['value'])
        checks.append({'id': call['id'], 'status': 'mismatch' if errors else 'original-apk-pass',
                       'errors': errors, 'actual': result['value'], 'evidence_kind': 'original_apk_only'})
    return checks


def write_json(path, value):
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent, delete=False) as temporary:
        temporary.write(json.dumps(value, indent=2, ensure_ascii=False) + '\n')
    Path(temporary.name).replace(path)


def fingerprints():
    harness = ['Helpers/SonyAPK/' + name for name in ('get_reply.py', 'GetReplyOracle.java', 'OracleRunner.java', 'runtime.py')]
    inspected = sorted({item['test'].split(':')[0] for item in PRODUCTION_COMPARISONS}
                       | {'Sources/SonyCommandQueue.swift', 'Sources/SonyHeadphonesController.swift'})
    return {group: {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in paths}
            for group, paths in [('harness_sha256', harness), ('production_inspection_sha256', inspected)]}


def self_test():
    calls = evidence_calls()
    assert len(calls) == 12 and len({call['id'] for call in calls}) == 12
    call = calls[0]
    value = {'generation': 1, 'scenario': 'reply_before_ack', 'wrapper': 'k70.v0', 'method': 'b0', 'return_value': 1,
             'snapshots': {'initial': expected_state(True, 1), 'before_ack': expected_state(True, 0),
                           'finished': expected_state(False, 0, True)},
             'connection_closed': 0, 'transport_closed': 0, 'diagnostics': [],
             'requests': [{'type': 12, 'sequence': 0, 'payload': [0xE6, 1]}],
             'events': [{'event': 'input_reply', 'payload': [0xE7, 1, 0, 1], 'sequence': 0, 'unrelated': False, 'late': False},
                        {'event': 'input_ack', 'sequence': 1}]}
    assert observation_errors(call, value) == []
    corrupt = deepcopy(value)
    corrupt['snapshots']['before_ack']['worker_finished'] = True
    assert observation_errors(call, corrupt)
    corrupt = deepcopy(value)
    corrupt['events'].reverse()
    assert observation_errors(call, corrupt)
    raw = {'apk_sha256': APK_SHA256, 'class_loader': 'dalvik.system.DexClassLoader', 'serial': 'emulator-test',
           'results': [{'id': call['id'], 'ok': False, 'error': {'type': 'Watchdog', 'message': 'No completion'}}]}
    assert evaluate(raw, [call])[0]['status'] == 'oracle-error'
    timeout_call = dict(call, scenario='withheld_reply')
    timeout = deepcopy(value)
    timeout.update(scenario='withheld_reply', return_value=None, diagnostics=['NO response: original'],
                   elapsed_after_ack_ns=2_000_000_000,
                   snapshots={'initial': expected_state(True, 1), 'before_reply': expected_state(False, 1),
                              'finished': expected_state(False, 1, True), 'after_late_reply': expected_state(False, 1, True)},
                   events=[{'event': 'input_ack', 'sequence': 1},
                           {'event': 'input_reply', 'payload': [0xE7, 1, 0, 1], 'sequence': 0, 'unrelated': False, 'late': True}])
    assert observation_errors(timeout_call, timeout) == []
    timeout['elapsed_after_ack_ns'] = 80_000_000
    assert observation_errors(timeout_call, timeout)
    print('GET lifecycle receipt self-checks passed')


def main():
    parser = argparse.ArgumentParser(description='Observe original Sony APK GET/reply lifecycle without claiming Swift controller equivalence')
    parser.add_argument('--apk', type=Path)
    parser.add_argument('--serial')
    parser.add_argument('--sdk', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if not args.apk or not args.serial or not args.output:
        parser.error('--apk, --serial and --output are required')
    args.output.mkdir(parents=True, exist_ok=True)
    for name in ('report.json', 'calls.json', 'oracle.json'):
        (args.output / name).unlink(missing_ok=True)
    run = {'run_id': uuid.uuid4().hex, 'started_utc': datetime.now(timezone.utc).isoformat(), 'status': 'running'}
    write_json(args.output / 'run.json', run)
    try:
        hashes = fingerprints()
        calls = evidence_calls()
        write_json(args.output / 'calls.json', calls)
        with APKOracle(args.apk, args.serial, args.sdk) as oracle:
            raw = oracle.run(calls)
        write_json(args.output / 'oracle.json', raw)
        checks = evaluate(raw, calls)
        changed = hashes != fingerprints()
        report = {'schema_version': 1, **run, 'status': 'completed', 'generated_utc': datetime.now(timezone.utc).isoformat(),
                  'apk_sha256': raw['apk_sha256'], 'serial': raw['serial'], 'evidence_kind': 'original_apk_only',
                  'runtime': {key: raw[key] for key in ('class_loader', 'vm_name', 'vm_version', 'android_api')},
                  'call_manifest': calls, 'checks': checks, 'summary': dict(Counter(check['status'] for check in checks)),
                  **hashes, 'changed_during_run': changed,
                  'evidence_sha256': {name: hashlib.sha256((args.output / name).read_bytes()).hexdigest()
                                      for name in ('calls.json', 'oracle.json')},
                  'production_comparison': {'executed': False, 'inspection_refs': PRODUCTION_COMPARISONS},
                  'limits': ['Only original APK wrappers k70.v0.b0 and l70.m1.E0 were executed; no Swift controller adapter was executed.',
                             'Decoder injection starts after the frame envelope; the original parsers, reply predicates, ACK sender and listener lifecycle still execute.',
                             'The original application scheduler and Bluetooth transport are replaced with observation proxies.',
                             'Interruption probes exercise Java worker cancellation, not Android or macOS user-interface cancellation.',
                             'APK reply timeout starts after ACK; Swift uses independent ACK and feature-response ownership with different deadlines.',
                             'No device-feature coverage stage is granted by these original-APK-only observations.']}
        write_json(args.output / 'report.json', report)
        result = 1 if changed or any(check['status'] != 'original-apk-pass' for check in checks) else 0
    except BaseException as error:
        (args.output / 'report.json').unlink(missing_ok=True)
        run.update(status='failed', error=type(error).__name__ + ': ' + str(error), finished_utc=datetime.now(timezone.utc).isoformat())
        write_json(args.output / 'run.json', run)
        raise
    run.update(status='completed', exit_code=result, finished_utc=datetime.now(timezone.utc).isoformat())
    write_json(args.output / 'run.json', run)
    print(json.dumps({'summary': report['summary'], 'production_comparison_executed': False,
                      'report': str(args.output / 'report.json')}))
    return result


if __name__ == '__main__':
    raise SystemExit(main())

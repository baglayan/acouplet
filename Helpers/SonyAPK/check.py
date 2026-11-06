import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import importlib
import json
from pathlib import Path
import subprocess
import tempfile
import uuid

from runtime import APKOracle


ROOT = Path(__file__).resolve().parents[2]
MODULES = ('framing', 'legacy', 'legacy_features', 'legacy_noise', 'modern', 'modern_playback', 'modern_noise', 'common_connection', 'connection_identity', 'queue', 'battery', 'equalizer', 'power', 'legacy_indicators')
SOURCES = [
    'SonyProtocol.swift', 'SonyEqualizer.swift', 'SonyLegacyControls.swift',
    'SonyLegacySoundEffect.swift', 'SonyLegacyOptimizer.swift',
    'SonyPlayback.swift', 'SonyMultipoint.swift', 'SonySystemFeatures.swift',
    'SonyAudioFeatures.swift', 'SonyPowerFeatures.swift', 'SonyConnectionAlerts.swift',
    'SonyConnectionTransition.swift', 'SonyCommonConnection.swift', 'SonyConnectionIdentity.swift', 'SonyCommandQueue.swift', 'SonyLegacyIndicators.swift', 'SonyNoiseControl.swift',
]
ARTIFACTS = ('cases.json', 'calls.json', 'swift.json', 'oracle.json', 'inventory.json')


def write_json(path, value):
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent, delete=False) as temporary:
        temporary.write(json.dumps(value, indent=2, ensure_ascii=False) + '\n')
    Path(temporary.name).replace(path)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()


def fingerprints():
    sources = {name: hashlib.sha256((ROOT / 'Sources' / name).read_bytes()).hexdigest() for name in SOURCES}
    harness = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
               for path in sorted(Path(__file__).parent.iterdir()) if path.suffix in ('.py', '.java', '.swift', '.json')}
    return sources, harness


def compile_adapter(directory, replacement=None):
    source_paths = [ROOT / 'Sources' / name for name in SOURCES]
    if replacement is not None:
        name, old, new = replacement
        path = ROOT / 'Sources' / name
        source = path.read_text()
        if source.count(old) != 1:
            raise ValueError(f'Mutation requires one exact source match: {name}: {old}')
        mutated = directory / name
        mutated.write_text(source.replace(old, new))
        source_paths[source_paths.index(path)] = mutated
    adapters = [Path(__file__).with_name(name) for name in (
        'Adapter.swift', 'LegacyAdapter.swift', 'LegacyFeaturesAdapter.swift',
        'LegacyOptimizerAdapter.swift', 'LegacyNoiseAdapter.swift', 'ModernAdapter.swift', 'ModernPlaybackAdapter.swift', 'ModernNoiseAdapter.swift', 'QueueAdapter.swift',
        'BatteryAdapter.swift', 'EqualizerAdapter.swift', 'PowerAdapter.swift', 'LegacyIndicatorsAdapter.swift', 'CommonConnectionAdapter.swift', 'ConnectionIdentityAdapter.swift',
    )]
    binary = directory / 'adapter'
    command = ['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
               *map(str, source_paths + adapters), '-o', str(binary)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError('Swift adapter compilation failed:\n' + result.stderr)
    return binary


def run_adapter(binary, cases):
    result = subprocess.run([str(binary)], input=json.dumps(cases), capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError('Swift adapter failed:\n' + result.stderr)
    values = json.loads(result.stdout)
    if [item['id'] for item in values] != [case['id'] for case in cases]:
        raise ValueError('Swift adapter returned missing, duplicate or reordered case IDs')
    return {item['id']: item['value'] for item in values}


def compare(cases, modules, values, oracle_results):
    checks = []
    for case in cases:
        errors = [oracle_results[call['id']]['error'] for call in case['calls']
                  if not oracle_results[call['id']]['ok']]
        entry = {'id': case['id'], 'group': case['group'], 'actual': values[case['id']],
                 'coverage_ids': case.get('coverage_ids', []),
                 'oracle_call_ids': [call['id'] for call in case['calls']],
                 'evidence_kind': 'protocol_comparison'}
        if case.get('category') == 'malformed':
            expected = case['expected']
            entry.update(expected=expected, category='boundary', oracle_errors=errors, evidence_kind='boundary',
                         status='boundary-pass' if expected == entry['actual'] else 'mismatch')
        elif errors:
            entry.update(status='oracle-error', errors=errors)
        else:
            decoded = {call['id']: oracle_results[call['id']]['value'] for call in case['calls']}
            expected = modules[case['group']].normalize(case, decoded)
            entry.update(expected=expected, status='pass' if expected == entry['actual'] else 'mismatch')
        checks.append(entry)
    return checks


def registered_inputs(groups):
    modules = {name: importlib.import_module(name) for name in groups}
    cases = [dict(case, group=name) for name, module in modules.items() for case in module.cases()]
    calls = [call for case in cases for call in case['calls']]
    manifest = [{'id': call['id'], 'group': case['group'], 'case_id': case['id'],
                 'evidence_only': False, 'sha256': digest(call)} for case in cases for call in case['calls']]
    for group, module in modules.items():
        for call in getattr(module, 'evidence_calls', lambda: [])():
            calls.append(call)
            manifest.append({'id': call['id'], 'group': group, 'case_id': None,
                             'evidence_only': True, 'sha256': digest(call)})
    if len({case['id'] for case in cases}) != len(cases) or len({call['id'] for call in calls}) != len(calls):
        raise ValueError('Case and oracle call IDs must be unique')
    if not cases:
        raise ValueError('No cases were selected')
    return modules, cases, calls, manifest


def check_mutations(directory, cases, modules, results):
    definitions = []
    if 'framing' in modules:
        definitions.append({
            'name': 'frame escape corruption',
            'replacement': ('SonyProtocol.swift', 'private static let escapeMask: UInt8 = 0xEF',
                            'private static let escapeMask: UInt8 = 0xFF'),
            'case_ids': [case['id'] for case in cases if case['group'] == 'framing'],
        })
    for module in modules.values():
        definitions.extend(getattr(module, 'mutations', lambda: [])())
    if not definitions:
        raise ValueError('No mutations are registered for the selected groups')
    mutations = []
    for definition in definitions:
        case_ids = definition['case_ids']
        selected = [case for case in cases if case['id'] in case_ids]
        if not selected or {case['id'] for case in selected} != set(case_ids):
            raise ValueError('Mutation case selection is empty or contains unregistered cases: ' + definition['name'])
        binary = compile_adapter(directory, definition['replacement'])
        try:
            values = run_adapter(binary, selected)
            checks = compare(selected, modules, values, results)
            rejected_cases = [item['id'] for item in checks if item['status'] not in ('pass', 'boundary-pass')]
            evidence = {'cases': rejected_cases, 'checks': checks}
            rejected = bool(rejected_cases)
        except RuntimeError as error:
            rejected = True
            evidence = {'adapter_failure': str(error)}
        mutations.append({'name': definition['name'], 'replacement': definition['replacement'],
                          'case_ids': case_ids, 'rejected': rejected, 'evidence': evidence})
    return mutations


def execute(args, run):
    import coverage

    source_hashes, harness_hashes = fingerprints()
    modules, cases, calls, call_manifest = registered_inputs(args.groups)
    write_json(args.output / 'cases.json', cases)
    write_json(args.output / 'calls.json', calls)
    with tempfile.TemporaryDirectory(prefix='acouplet-apk-check-') as temporary:
        directory = Path(temporary)
        binary = compile_adapter(directory)
        values = run_adapter(binary, cases)
        write_json(args.output / 'swift.json', values)
        with APKOracle(args.apk, args.serial, args.sdk) as oracle:
            raw = oracle.run(calls)
            write_json(args.output / 'oracle.json', raw)
            inventory = coverage.capture_inventory(oracle)
            write_json(args.output / 'inventory.json', inventory)
        if [item['id'] for item in raw['results']] != [call['id'] for call in calls]:
            raise ValueError('APK returned missing, duplicate or reordered call IDs')
        results = {result['id']: result for result in raw['results']}
        checks = compare(cases, modules, values, results)
        mutations = []
        mutation_skip_reason = None
        if args.check_mutations:
            if any(item['status'] not in ('pass', 'boundary-pass') for item in checks):
                mutation_skip_reason = 'Mutation checking requires a passing baseline'
            else:
                mutations = check_mutations(directory, cases, modules, results)
    summary = dict(Counter(item['status'] for item in checks))
    unsupported = [item for module in modules.values() for item in getattr(module, 'unsupported', lambda: [])()]
    evidence = [dict(item, result=results[item['id']], evidence_kind='original_apk_only')
                for item in call_manifest if item['evidence_only']]
    report = {
        'schema_version': 2, 'run_id': run['run_id'], 'started_utc': run['started_utc'],
        'generated_utc': datetime.now(timezone.utc).isoformat(), 'status': 'completed',
        'apk_sha256': raw['apk_sha256'], 'serial': raw['serial'], 'selected_groups': args.groups,
        'runtime': {key: raw[key] for key in ('vm_name', 'vm_version', 'android_api', 'class_loader')}, 'summary': summary,
        'case_count': len(cases), 'oracle_call_count': len(calls), 'checks': checks,
        'case_manifest': [{'id': case['id'], 'group': case['group'], 'coverage_ids': case.get('coverage_ids', [])} for case in cases],
        'call_manifest': call_manifest, 'evidence': evidence,
        'mutations_requested': args.check_mutations, 'mutation_skip_reason': mutation_skip_reason,
        'mutations': mutations, 'not_covered': unsupported,
        'source_sha256': source_hashes, 'harness_sha256': harness_hashes,
        'evidence_sha256': {name: hashlib.sha256((args.output / name).read_bytes()).hexdigest() for name in ARTIFACTS},
        'limits': ['Protocol serialization and parsing only; no physical headphone firmware or Bluetooth radio.',
                   'Android APK behavior does not verify macOS transport ownership or LDAC stability.',
                   'Original-APK-only evidence has no Swift comparison and is not counted as a pass.',
                   'Unsupported variants are reported separately and are not counted as passes.'],
    }
    report['changed_during_run'] = fingerprints() != (source_hashes, harness_hashes)
    manifest = json.loads(Path(__file__).with_name('features.json').read_text())
    coverage_result = coverage.evaluate(manifest, inventory, [dict(report, report_path=str((args.output / 'report.json').resolve()))])
    write_json(args.output / 'coverage.json', coverage_result)
    write_json(args.output / 'report.json', report)
    print(json.dumps({'summary': summary, 'cases': len(cases), 'report': str(args.output / 'report.json'),
                      'coverage': coverage_result['summary'], 'coverage_complete': coverage_result['complete']}))
    failed = report['changed_during_run'] or any(item['status'] not in ('pass', 'boundary-pass') for item in checks)
    failed = failed or any(not item['rejected'] for item in mutations) or any(not item['result']['ok'] for item in evidence)
    return 1 if failed or coverage_result['errors'] or coverage_result['report_errors'] else 0


def start_run(output, groups):
    output.mkdir(parents=True, exist_ok=True)
    for name in ('report.json', 'coverage.json', *ARTIFACTS):
        (output / name).unlink(missing_ok=True)
    run = {'run_id': uuid.uuid4().hex, 'started_utc': datetime.now(timezone.utc).isoformat(),
           'status': 'running', 'selected_groups': groups}
    write_json(output / 'run.json', run)
    return run


def self_test():
    modules, cases, calls, manifest = registered_inputs(MODULES)
    assert len(cases) == len({case['id'] for case in cases})
    assert [call['id'] for call in calls] == [item['id'] for item in manifest]
    assert all(digest(call) == item['sha256'] for call, item in zip(calls, manifest))
    assert len([item for item in manifest if item['evidence_only']]) == 4
    assert any(case['swift']['op'].startswith('legacy.optimizer') for case in cases)
    with tempfile.TemporaryDirectory() as temporary:
        output = Path(temporary)
        write_json(output / 'report.json', {'summary': {'pass': 1}})
        write_json(output / 'coverage.json', {'complete': True})
        run = start_run(output, ['framing'])
        assert not (output / 'report.json').exists() and not (output / 'coverage.json').exists()
        assert json.loads((output / 'run.json').read_text()) == run
    case = {'id': 'boundary', 'group': 'framing', 'calls': [{'id': 'bad'}],
            'category': 'malformed', 'expected': {'accepted': False}, 'coverage_ids': ['x.parser']}
    checks = compare([case], modules, {'boundary': {'accepted': False}}, {'bad': {'ok': False, 'error': 'invalid'}})
    assert checks[0]['status'] == 'boundary-pass' and checks[0]['evidence_kind'] == 'boundary'
    assert checks[0]['coverage_ids'] == ['x.parser'] and checks[0]['oracle_call_ids'] == ['bad']
    print('Harness self-checks passed')


def main():
    parser = argparse.ArgumentParser(description='Compare Acouplet production protocol code with the original Sony APK')
    parser.add_argument('--apk', type=Path)
    parser.add_argument('--serial')
    parser.add_argument('--sdk', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--groups', nargs='+', choices=MODULES, default=list(MODULES))
    parser.add_argument('--check-mutations', action='store_true')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if not args.apk or not args.serial or not args.output:
        parser.error('--apk, --serial and --output are required')
    run = start_run(args.output, args.groups)
    try:
        result = execute(args, run)
    except BaseException as error:
        for name in ('report.json', 'coverage.json'):
            (args.output / name).unlink(missing_ok=True)
        run.update(status='failed', finished_utc=datetime.now(timezone.utc).isoformat(),
                   error=type(error).__name__ + ': ' + str(error))
        write_json(args.output / 'run.json', run)
        raise
    run.update(status='completed', finished_utc=datetime.now(timezone.utc).isoformat(), exit_code=result)
    write_json(args.output / 'run.json', run)
    return result


if __name__ == '__main__':
    raise SystemExit(main())

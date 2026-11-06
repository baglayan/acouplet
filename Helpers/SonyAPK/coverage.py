import argparse
from collections import Counter
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile

from runtime import APKOracle, APK_SHA256


ROOT = Path(__file__).resolve().parents[2]
ENUMS = {
    'mdr-v1': 'com.sony.songpal.tandemfamily.message.mdr.v1.table1.param.FunctionType',
    'mdr-v2': 'com.sony.songpal.tandemfamily.message.mdr.v2.FunctionType',
    'ble-model': 'com.sony.songpal.ble.client.param.ModelFeature',
}
PROTOCOL_STAGES = {'capability', 'serializer', 'parser'}
APPLICATION_STAGES = {'controller', 'ui'}
ENUM_COUNTS = {'mdr-v1': 39, 'mdr-v2': 201, 'ble-model': 7}
EVIDENCE_FILES = {'cases.json', 'calls.json', 'swift.json', 'oracle.json', 'inventory.json'}


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


def results_by_id(raw):
    results = raw['results']
    if len({item['id'] for item in results}) != len(results):
        raise ValueError('Original APK returned duplicate result IDs')
    failures = [item for item in results if not item['ok']]
    if failures:
        raise ValueError('Original APK enum extraction failed: ' + json.dumps(failures))
    return {item['id']: item['value'] for item in results}


def feature_identity(namespace, table, code):
    return f'{namespace}-t{table}-{code:02x}' if table is not None else f'{namespace}-{code:02x}'


def decoded_inventory(raw_names, raw_details):
    names = results_by_id(raw_names)
    details = results_by_id(raw_details)
    if set(names) != set(ENUMS):
        raise ValueError('Original APK enumeration omitted or added enum classes')
    features = []
    detail_ids = set()
    for namespace, owner in ENUMS.items():
        if len(names[namespace]) != ENUM_COUNTS[namespace]:
            raise ValueError('Original APK enumeration count differs for ' + namespace)
        for item in names[namespace]:
            if item['enum'] != owner:
                raise ValueError('Unexpected original enum class: ' + item['enum'])
            name = item['name']
            identity = namespace + '.' + name
            detail_ids.update((identity, identity + '.byte'))
            if details[identity] != item:
                raise ValueError('Original valueOf() differs from values(): ' + identity)
            code = details[identity + '.byte'] & 255
            if namespace == 'mdr-v2':
                detail_ids.add(identity + '.table')
                table = {'NO_1': 1, 'NO_2': 2, 'INVALID': None}[details[identity + '.table']['name']]
            else:
                table = 1 if namespace == 'mdr-v1' else None
            features.append({
                'id': feature_identity(namespace, table, code), 'namespace': namespace,
                'name': name, 'byte': code, 'capability_table': table,
                'kind': 'sentinel' if name in ('NO_USE', 'OUT_OF_RANGE') else 'device_capability',
            })
    if set(details) != detail_ids:
        raise ValueError('Original APK detail execution omitted or added enum calls')
    if len({feature['id'] for feature in features}) != len(features):
        raise ValueError('Original APK enumeration contains duplicate capability identities')
    return features


def capture_inventory(oracle):
    raw_names = oracle.run([
        {'id': namespace, 'class': owner, 'method': 'values'}
        for namespace, owner in ENUMS.items()
    ])
    names = results_by_id(raw_names)
    calls = []
    for namespace, owner in ENUMS.items():
        for item in names[namespace]:
            identity = namespace + '.' + item['name']
            calls.extend([
                {'id': identity, 'class': owner, 'method': 'valueOf',
                 'types': ['java.lang.String'], 'args': [item['name']]},
                {'id': identity + '.byte', 'class': owner, 'target': identity, 'method': 'byteCode'},
            ])
            if namespace == 'mdr-v2':
                calls.append({'id': identity + '.table', 'class': owner,
                              'target': identity, 'method': 'getTableNumber'})
    raw_details = oracle.run(calls)
    return {
        'schema_version': 1, 'apk_sha256': raw_details['apk_sha256'],
        'runtime': {key: raw_details[key] for key in ('vm_name', 'vm_version', 'android_api', 'class_loader')},
        'serial': raw_details['serial'], 'enum_classes': ENUMS,
        'features': decoded_inventory(raw_names, raw_details),
        'raw_enumeration': raw_names, 'raw_details': raw_details,
    }


def load_module(root, name):
    path = root / 'Helpers' / 'SonyAPK' / (name + '.py')
    spec = importlib.util.spec_from_file_location('sony_coverage_' + name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def artifact_errors(report, root):
    errors = []
    if report.get('schema_version') != 2 or report.get('status') != 'completed':
        errors.append('A completed version 2 execution report is required')
    if report.get('changed_during_run') is not False:
        errors.append('Source stability during the test run was not established')
    if report.get('apk_sha256') != APK_SHA256:
        errors.append('APK hash is missing or does not match the pinned original APK')
    runtime = report.get('runtime')
    if not isinstance(runtime, dict) or runtime.get('class_loader') != 'dalvik.system.DexClassLoader':
        errors.append('Original APK DEX runtime evidence is missing')
    if not report.get('serial', '').startswith('emulator-'):
        errors.append('Report does not identify an Android emulator')
    checks = report.get('checks', [])
    if report.get('case_count') != len(checks):
        errors.append('Case count does not match returned checks')
    if report.get('summary') != dict(Counter(item['status'] for item in checks)):
        errors.append('Summary does not match returned checks')
    current = load_module(root, 'check').fingerprints()
    for field, expected_fingerprints in zip(('source_sha256', 'harness_sha256'), current):
        fingerprints = report.get(field, {})
        if set(fingerprints) != set(expected_fingerprints):
            errors.append(field + ' does not cover the current execution dependencies')
        for name, expected in expected_fingerprints.items():
            if fingerprints.get(name) != expected:
                errors.append('Stale or unavailable evidence source: ' + name)
    return errors


def registered_cases(root):
    result = {}
    runner = load_module(root, 'check')
    for case in runner.registered_inputs(runner.MODULES)[1]:
        result[case['id']] = case
    return result


def registration_errors(report, registered):
    manifest = report.get('case_manifest', [])
    groups = report.get('selected_groups', [])
    known_groups = {item['group'] for item in registered.values()}
    expected = {key: {field: item.get(field, []) for field in ('id', 'group', 'coverage_ids')}
                for key, item in registered.items() if item['group'] in groups}
    declared = {item['id']: {key: item.get(key, []) for key in ('id', 'group', 'coverage_ids')} for item in manifest}
    errors = []
    if not groups or len(set(groups)) != len(groups) or set(groups) - known_groups:
        errors.append('Selected groups are missing, duplicated or unknown')
    if not manifest or len(declared) != len(manifest) or expected != declared:
        errors.append('Case manifest differs from the current registered test cases')
    checks = report.get('checks', [])
    if {item['id'] for item in checks} != set(declared):
        errors.append('Checks omit or add registered test cases')
    for check in checks:
        case = registered.get(check['id'])
        if case is None or check.get('coverage_ids', []) != case.get('coverage_ids', []):
            errors.append('Coverage attribution differs from registered test: ' + check['id'])
        elif check.get('group') != case['group']:
            errors.append('Check group differs from registered test: ' + check['id'])
    return errors


def execution_errors(report, registered, manifest, root):
    errors = []
    if not report.get('report_path'):
        return ['Saved execution artifact path is missing']
    directory = Path(report['report_path']).resolve().parent
    try:
        run = json.loads((directory / 'run.json').read_text())
        if (not report.get('run_id') or run.get('run_id') != report['run_id']
                or run.get('selected_groups') != report.get('selected_groups')
                or run.get('status') not in ('running', 'completed')
                or (Path(report['report_path']).exists() and run.get('status') != 'completed')):
            errors.append('Execution report is not from the current completed run')
    except (OSError, ValueError) as error:
        errors.append('Execution run identity unavailable: ' + str(error))
    fingerprints = report.get('evidence_sha256', {})
    if set(fingerprints) != EVIDENCE_FILES:
        errors.append('Execution artifact fingerprints are incomplete or unknown')
    artifacts = {}
    for name in sorted(EVIDENCE_FILES):
        try:
            data = (directory / name).read_bytes()
            if hashlib.sha256(data).hexdigest() != fingerprints.get(name):
                errors.append('Execution artifact hash differs: ' + name)
            artifacts[name] = json.loads(data)
        except (OSError, ValueError) as error:
            errors.append('Execution artifact unavailable: ' + name + ': ' + str(error))
    if errors:
        return errors
    runner = load_module(root, 'check')
    modules, cases, calls, call_manifest = runner.registered_inputs(report.get('selected_groups', []))
    if artifacts['cases.json'] != cases:
        errors.append('Executed cases differ from current registered inputs and APK calls')
    if artifacts['calls.json'] != calls:
        errors.append('Executed APK calls differ from current registered calls')
    if report.get('call_manifest') != call_manifest:
        errors.append('APK call manifest differs from current registered calls')
    raw = artifacts['oracle.json']
    if (raw.get('apk_sha256') != APK_SHA256 or raw.get('serial') != report.get('serial')
            or any(raw.get(key) != value for key, value in report.get('runtime', {}).items())):
        errors.append('Original APK execution identity differs from the report')
    results = {item['id']: item for item in raw.get('results', [])}
    if (len(results) != len(raw.get('results', [])) or set(results) != {call['id'] for call in calls}
            or report.get('oracle_call_count') != len(calls)):
        errors.append('Original APK execution omitted or duplicated registered calls')
    values = artifacts['swift.json']
    if set(values) != {case['id'] for case in cases}:
        errors.append('Production execution omitted or added case results')
    errors.extend(inventory_errors(manifest, artifacts['inventory.json']))
    if not errors:
        expected = runner.compare(cases, modules, values, results)
        if report.get('checks') != expected:
            errors.append('Reported checks differ from replayed production and original APK results')
    return errors


def inventory_errors(manifest, inventory):
    errors = []
    if manifest.get('apk', {}).get('sha256') != APK_SHA256 or inventory.get('apk_sha256') != APK_SHA256:
        errors.append('Inventory APK hash does not match the pinned original APK')
    if inventory.get('runtime', {}).get('class_loader') != 'dalvik.system.DexClassLoader':
        errors.append('Inventory was not extracted through the original APK DEX loader')
    if not inventory.get('serial', '').startswith('emulator-'):
        errors.append('Inventory does not identify an Android emulator')
    if inventory.get('enum_classes') != ENUMS:
        errors.append('Inventory did not enumerate every required original APK enum')
    keys = ('id', 'namespace', 'name', 'byte', 'capability_table', 'kind')
    expected = [tuple(item[key] for key in keys) for item in manifest['features']]
    actual = [tuple(item[key] for key in keys) for item in inventory.get('features', [])]
    if (len({item[0] for item in expected}) != len(expected)
            or len({item[0] for item in actual}) != len(actual)):
        errors.append('Duplicate capability entries')
    if Counter(item['namespace'] for item in inventory.get('features', [])) != ENUM_COUNTS:
        errors.append('Inventory does not contain the pinned 247 enum entries and 244 capabilities')
    if sum(item['kind'] == 'device_capability' for item in inventory.get('features', [])) != 244:
        errors.append('Inventory device capability denominator differs from the pinned APK')
    missing = sorted(set(actual) - set(expected))
    extra = sorted(set(expected) - set(actual))
    if missing or extra:
        errors.append('Manifest differs from original APK enumeration: ' + json.dumps({'missing': missing, 'extra': extra}))
    for field in ('raw_enumeration', 'raw_details'):
        raw = inventory.get(field)
        if raw is None or raw.get('apk_sha256') != APK_SHA256:
            errors.append('Original enum execution evidence missing: ' + field)
        elif any(not item.get('ok') for item in raw.get('results', [])):
            errors.append('Original enum execution failed: ' + field)
        elif (raw.get('serial') != inventory.get('serial')
              or any(raw.get(key) != value for key, value in inventory.get('runtime', {}).items())):
            errors.append('Original enum execution identity differs from the inventory: ' + field)
    if inventory.get('raw_enumeration') and inventory.get('raw_details'):
        try:
            original = decoded_inventory(inventory['raw_enumeration'], inventory['raw_details'])
            if original != inventory.get('features'):
                errors.append('Captured features differ from original values(), byteCode() or getTableNumber() results')
        except (KeyError, TypeError, ValueError) as error:
            errors.append('Original enum execution evidence is invalid: ' + str(error))
    return errors


def evaluate(manifest, inventory, reports, root=ROOT, registration=None):
    errors = inventory_errors(manifest, inventory)
    inventory_match = not errors
    for feature in manifest['features']:
        stages = PROTOCOL_STAGES | APPLICATION_STAGES
        if feature['namespace'] == 'ble-model':
            stages = {'capability', 'parser', 'controller'}
        elif feature['id'] == 'mdr-v2-t2-21':
            stages = {'capability', 'controller', 'ui'}
        expected = {feature['id'] + '.' + stage for stage in stages} if feature['kind'] != 'sentinel' else set()
        if set(feature['required_coverage_ids']) != expected or len(feature['required_coverage_ids']) != len(expected):
            errors.append('Required verification stages are missing or duplicated: ' + feature['id'])
    known_ids = {coverage_id for feature in manifest['features'] for coverage_id in feature['required_coverage_ids']}
    registered = registered_cases(root) if registration is None else registration
    required_cases = {coverage_id: {case['id'] for case in registered.values() if coverage_id in case.get('coverage_ids', [])}
                      for coverage_id in known_ids}
    passed = {coverage_id: [] for coverage_id in known_ids}
    failed = {coverage_id: [] for coverage_id in known_ids}
    rejected = {coverage_id: [] for coverage_id in known_ids}
    report_errors = []
    for index, report in enumerate(reports):
        origin = report.get('report_path', f'report-{index}')
        invalid = artifact_errors(report, root)
        invalid.extend(registration_errors(report, registered))
        if not invalid:
            invalid.extend(execution_errors(report, registered, manifest, root))
        check_ids = [item['id'] for item in report.get('checks', [])]
        if len(check_ids) != len(set(check_ids)):
            invalid.append('Duplicate check IDs')
        if invalid:
            report_errors.append({'report': origin, 'errors': invalid})
        for check in report.get('checks', []):
            for coverage_id in check.get('coverage_ids', []):
                if coverage_id not in known_ids:
                    errors.append('Unknown coverage ID: ' + coverage_id)
                    continue
                evidence = {'report': origin, 'case_id': check['id'], 'status': check['status']}
                if invalid or not inventory_match:
                    rejected[coverage_id].append(dict(evidence, reason='Invalid or stale evidence artifact'))
                elif coverage_id.rsplit('.', 1)[1] not in PROTOCOL_STAGES:
                    rejected[coverage_id].append(dict(evidence, reason='This protocol runner does not execute controller or UI behavior'))
                elif check['status'] not in ('pass', 'boundary-pass'):
                    failed[coverage_id].append(evidence)
                elif check['status'] == 'boundary-pass':
                    passed[coverage_id].append(dict(evidence, boundary_only=True))
                else:
                    passed[coverage_id].append(evidence)
    rows = []
    stage_counts = Counter()
    for feature in manifest['features']:
        if feature['kind'] == 'sentinel':
            continue
        stages = {}
        for coverage_id in feature['required_coverage_ids']:
            observed = {item['case_id'] for item in passed[coverage_id]}
            missing_cases = required_cases[coverage_id] - observed
            matched_original = any(not item.get('boundary_only') for item in passed[coverage_id])
            state = 'failing' if failed[coverage_id] else 'exercised' if matched_original and not missing_cases else 'partial' if observed else 'unverified'
            stages[coverage_id.rsplit('.', 1)[1]] = {
                'state': state, 'evidence': passed[coverage_id] + failed[coverage_id],
                'rejected_evidence': rejected[coverage_id],
                'registered_case_count': len(required_cases[coverage_id]),
                'missing_case_ids': sorted(missing_cases),
            }
            stage_counts[state] += 1
        values = [stage['state'] for stage in stages.values()]
        status = 'failing' if 'failing' in values else 'partial' if any(value in ('exercised', 'partial') for value in values) else 'unverified'
        rows.append({
            'id': feature['id'], 'name': feature['name'], 'generation': feature['generation'],
            'table': feature['capability_table'], 'namespace': feature['namespace'],
            'verification_status': status, 'stages': stages,
            'verification_gaps': ['Complete capability-specific schema, state and optional-subcommand obligations are not yet enumerated.',
                                  'This runner does not execute application controller or UI behavior.'],
            'missing_coverage_ids': [value for value in feature['required_coverage_ids'] if stages[value.rsplit('.', 1)[1]]['state'] != 'verified'],
        })
    verification_counts = dict(Counter(row['verification_status'] for row in rows))
    complete = inventory_match and not errors and not report_errors and all(row['verification_status'] == 'verified' for row in rows)
    return {
        'schema_version': 2, 'apk_sha256': APK_SHA256, 'inventory_match': inventory_match,
        'complete': complete, 'errors': errors, 'report_errors': report_errors,
        'summary': {'total': len(rows), 'verification': verification_counts, 'stage_counts': dict(stage_counts),
                    'verified_percent': round(100 * verification_counts.get('verified', 0) / len(rows), 2) if rows else 0},
        'features': rows,
        'limits': manifest['scope']['qualifications'] + [
            'An exercised stage means its currently registered cases passed; it does not establish exhaustive schema coverage.',
            'Full feature verification requires concrete schema/state obligations and application controller/UI execution; this runner only supplies protocol comparisons.',
            'Malformed-input boundary passes do not count as original-APK semantic equivalence.',
            'No physical headphone firmware, Bluetooth radio, acoustic output or hardware safety behavior was verified.',
        ],
    }


def self_test():
    runner = load_module(ROOT, 'check')
    sources, harness = runner.fingerprints()
    runtime = {'class_loader': 'dalvik.system.DexClassLoader', 'vm_name': 'unit-fixture',
               'vm_version': 'unit-fixture', 'android_api': 33}
    report = {'schema_version': 2, 'status': 'completed', 'apk_sha256': APK_SHA256,
              'runtime': runtime, 'serial': 'emulator-unit-fixture',
              'changed_during_run': False, 'case_count': 0, 'summary': {}, 'checks': [],
              'source_sha256': sources, 'harness_sha256': harness}
    assert artifact_errors(report, ROOT) == []
    incomplete = copy.deepcopy(report)
    incomplete['source_sha256'].pop(next(iter(sources)))
    assert artifact_errors(incomplete, ROOT)
    incomplete = copy.deepcopy(report)
    incomplete['harness_sha256'] = {}
    assert artifact_errors(incomplete, ROOT)
    incomplete = copy.deepcopy(report)
    incomplete['source_sha256'][next(iter(sources))] = 'stale'
    assert artifact_errors(incomplete, ROOT)
    assert artifact_errors({}, ROOT)
    registered = {'a': {'id': 'a', 'group': 'legacy', 'coverage_ids': ['x.parser']},
                  'b': {'id': 'b', 'group': 'legacy', 'coverage_ids': ['x.parser']}}
    registration = {'case_manifest': list(registered.values()), 'selected_groups': ['legacy'],
                    'checks': list(registered.values())}
    assert registration_errors(registration, registered) == []
    incomplete = copy.deepcopy(registration)
    incomplete['checks'].pop()
    assert registration_errors(incomplete, registered)
    incomplete['case_manifest'].pop()
    assert registration_errors(incomplete, registered)
    incomplete = copy.deepcopy(registration)
    incomplete['selected_groups'].append('invented')
    assert registration_errors(incomplete, registered)
    manifest = json.loads(Path(__file__).with_name('features.json').read_text())
    names, details = [], []
    for namespace, owner in ENUMS.items():
        values = []
        for feature in manifest['features']:
            if feature['namespace'] != namespace:
                continue
            value = {'enum': owner, 'name': feature['name']}
            identity = namespace + '.' + feature['name']
            values.append(value)
            details.extend([{'id': identity, 'ok': True, 'value': value},
                            {'id': identity + '.byte', 'ok': True, 'value': feature['byte']}])
            if namespace == 'mdr-v2':
                table = {1: 'NO_1', 2: 'NO_2', None: 'INVALID'}[feature['capability_table']]
                details.append({'id': identity + '.table', 'ok': True, 'value': {'name': table}})
        names.append({'id': namespace, 'ok': True, 'value': values})
    identity = dict(runtime, serial=report['serial'], apk_sha256=APK_SHA256)
    raw_names, raw_details = dict(identity, results=names), dict(identity, results=details)
    inventory = {'apk_sha256': APK_SHA256, 'runtime': runtime, 'serial': report['serial'],
                 'enum_classes': ENUMS, 'features': decoded_inventory(raw_names, raw_details),
                 'raw_enumeration': raw_names, 'raw_details': raw_details}
    assert inventory_errors(manifest, inventory) == []
    scoped = evaluate(manifest, inventory, [], registration={})
    assert scoped['errors'] == []
    advisory = next(row for row in scoped['features'] if row['id'] == 'mdr-v2-t2-21')
    assert set(advisory['stages']) == {'capability', 'controller', 'ui'}
    standby = next(row for row in scoped['features'] if row['id'] == 'mdr-v2-t2-20')
    assert set(standby['stages']) == PROTOCOL_STAGES | APPLICATION_STAGES
    for feature_id, stage in [('mdr-v2-t2-21', 'capability'), ('mdr-v2-t2-21', 'ui'), ('mdr-v2-t2-20', 'serializer')]:
        incomplete = copy.deepcopy(manifest)
        feature = next(row for row in incomplete['features'] if row['id'] == feature_id)
        feature['required_coverage_ids'].remove(feature_id + '.' + stage)
        assert evaluate(incomplete, inventory, [], registration={})['errors']
    incomplete = copy.deepcopy(inventory)
    incomplete['raw_details']['results'].pop()
    assert inventory_errors(manifest, incomplete)
    incomplete = copy.deepcopy(inventory)
    incomplete['features'].pop()
    assert inventory_errors(manifest, incomplete)
    modules, cases, calls, call_manifest = runner.registered_inputs(['queue'])
    values = {case['id']: {'unit_fixture': case['id']} for case in cases}
    raw = dict(identity, results=[{'id': call['id'], 'ok': True, 'value': values.get(call['id'], {})} for call in calls])
    results = {item['id']: item for item in raw['results']}
    checks = runner.compare(cases, modules, values, results)
    report.update(run_id='unit-fixture', selected_groups=['queue'], case_count=len(cases),
                  oracle_call_count=len(calls), checks=checks,
                  summary=dict(Counter(item['status'] for item in checks)), call_manifest=call_manifest,
                  case_manifest=[{'id': case['id'], 'group': case['group'], 'coverage_ids': case.get('coverage_ids', [])} for case in cases])
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        report['report_path'] = str(directory / 'report.json')
        write_json(directory / 'run.json', {'run_id': report['run_id'], 'status': 'completed', 'selected_groups': ['queue']})
        artifacts = {'cases.json': cases, 'calls.json': calls, 'swift.json': values,
                     'oracle.json': raw, 'inventory.json': inventory}
        for name, value in artifacts.items():
            write_json(directory / name, value)
        report['evidence_sha256'] = {name: hashlib.sha256((directory / name).read_bytes()).hexdigest() for name in EVIDENCE_FILES}
        registered = {case['id']: case for case in cases}
        assert execution_errors(report, registered, manifest, ROOT) == []
        forged = copy.deepcopy(report)
        forged['runtime'] = None
        result = evaluate(manifest, inventory, [forged], registration=registered)
        assert result['report_errors'] == [{'report': report['report_path'],
                                            'errors': ['Original APK DEX runtime evidence is missing']}]
        forged = copy.deepcopy(report)
        forged['checks'][0]['evidence_kind'] = 'application_behavior'
        assert execution_errors(forged, registered, manifest, ROOT)
        forged = copy.deepcopy(report)
        forged['checks'][0]['status'] = 'mismatch'
        assert execution_errors(forged, registered, manifest, ROOT)
        forged = copy.deepcopy(report)
        forged['run_id'] = 'older-run'
        assert execution_errors(forged, registered, manifest, ROOT)
        write_json(directory / 'swift.json', {})
        assert execution_errors(report, registered, manifest, ROOT)
        report['evidence_sha256']['swift.json'] = hashlib.sha256((directory / 'swift.json').read_bytes()).hexdigest()
        assert execution_errors(report, registered, manifest, ROOT)
    for feature in manifest['features']:
        feature['schema_audit'] = {'status': 'complete'}
    result = evaluate(manifest, inventory, [], registration={})
    assert result['summary']['total'] == 244 and result['summary']['verified_percent'] == 0
    assert not result['complete'] and result['summary']['verification'] == {'unverified': 244}
    assert feature_identity('mdr-v2', 2, 0xFF) == 'mdr-v2-t2-ff'
    assert feature_identity('ble-model', None, 0) == 'ble-model-00'
    print('Coverage self-checks passed')


def main():
    parser = argparse.ArgumentParser(description='Audit original-APK verification coverage')
    parser.add_argument('--manifest', type=Path, default=Path(__file__).with_name('features.json'))
    parser.add_argument('--inventory', type=Path)
    parser.add_argument('--apk', type=Path)
    parser.add_argument('--serial')
    parser.add_argument('--sdk', type=Path)
    parser.add_argument('--report', type=Path, action='append', default=[])
    parser.add_argument('--output', type=Path)
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.output is None:
        parser.error('--output is required')
    args.output.mkdir(parents=True, exist_ok=True)
    if args.inventory:
        inventory = json.loads(args.inventory.read_text())
    else:
        if not args.apk or not args.serial:
            parser.error('Supply --inventory or both --apk and --serial')
        with APKOracle(args.apk, args.serial, args.sdk) as oracle:
            inventory = capture_inventory(oracle)
        write_json(args.output / 'inventory.json', inventory)
    reports = []
    for path in args.report:
        path = path / 'report.json' if path.is_dir() else path
        reports.append(dict(json.loads(path.read_text()), report_path=str(path.resolve())))
    result = evaluate(json.loads(args.manifest.read_text()), inventory, reports)
    write_json(args.output / 'coverage.json', result)
    print(json.dumps({'summary': result['summary'], 'complete': result['complete'],
                      'coverage': str(args.output / 'coverage.json')}))
    return 0 if result['complete'] else 1


if __name__ == '__main__':
    raise SystemExit(main())

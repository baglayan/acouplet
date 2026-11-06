import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import importlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PROTOCOL_STAGES = ('capability', 'serializer', 'parser')
CATEGORY_NAMES = {
    'alert': 'Alerts', 'audio': 'Audio quality', 'common': 'Device status', 'eqebb': 'Equalizer and bass',
    'general_setting': 'Device settings', 'log': 'Device logs', 'ncasm': 'Noise control',
    'opt': 'Noise optimizer', 'play': 'Playback', 'sense': 'Adaptive sound', 'sports': 'Activity tracking',
    'system': 'System settings', 'updt': 'Firmware updates', 'vpt': 'Surround sound',
    'peripheral': 'Paired devices', 'peri': 'Paired devices', 'voice_guidance': 'Voice guidance',
    'lea': 'LE Audio', 'power': 'Power and charging', 'party': 'Speaker features',
    'safe_listening': 'Safe listening', 'sar_auto_play': 'Auto Play', 'ble-model': 'Advertised features',
}
FEATURE_NAMES = {
    'BATTERY_LEVEL': 'Battery level', 'LEFT_RIGHT_BATTERY_LEVEL': 'Left and right battery levels',
    'CRADLE_BATTERY_LEVEL': 'Case battery level', 'BATTERY_LEVEL_WITH_THRESHOLD': 'Battery level with low-battery threshold',
    'LEFT_RIGHT_BATTERY_LEVEL_WITH_THRESHOLD': 'Left and right battery levels with low-battery thresholds',
    'CRADLE_BATTERY_LEVEL_WITH_THRESHOLD': 'Case battery level with low-battery threshold',
    'NC_OPTIMIZER': 'Noise-cancelling optimizer', 'NOISE_CANCELLING_AND_AMBIENT_SOUND_MODE': 'Noise cancelling and ambient sound',
    'NOISE_CANCELLING': 'Noise cancelling', 'AMBIENT_SOUND_MODE': 'Ambient sound', 'PRESET_EQ': 'Equalizer presets',
    'NOISE_CANCELLING_ONOFF': 'Noise cancelling on/off',
    'NOISE_CANCELLING_ONOFF_AND_AMBIENT_SOUND_MODE_ONOFF': 'Noise cancelling and ambient sound on/off',
    'NOISE_CANCELLING_DUAL_SINGLE_OFF_AND_AMBIENT_SOUND_MODE_ONOFF': 'Noise cancelling with wind reduction; ambient sound on/off',
    'NOISE_CANCELLING_ONOFF_AND_AMBIENT_SOUND_MODE_LEVEL_ADJUSTMENT': 'Noise cancelling and adjustable ambient sound',
    'NOISE_CANCELLING_DUAL_SINGLE_OFF_AMBIENT_SOUND_MODE_LEVEL_ADJUSTMENT': 'Noise cancelling with wind reduction; adjustable ambient sound',
    'AMBIENT_SOUND_MODE_ONOFF': 'Ambient sound on/off',
    'AMBIENT_SOUND_MODE_LEVEL_ADJUSTMENT': 'Adjustable ambient sound',
    'MODE_NC_ASM_NOISE_CANCELLING_DUAL_AUTO_AMBIENT_SOUND_MODE_LEVEL_ADJUSTMENT': 'Automatic wind reduction and ambient sound',
    'AMBIENT_SOUND_CONTROL_MODE_SELECT': 'Noise-control button mode cycle',
    'MODE_NC_ASM_NOISE_CANCELLING_DUAL_SINGLE_AMBIENT_SOUND_MODE_LEVEL_ADJUSTMENT': 'Noise modes with wind reduction and ambient sound',
    'MODE_NC_ASM_NOISE_CANCELLING_DUAL_AMBIENT_SOUND_MODE_LEVEL_ADJUSTMENT': 'Noise modes with adjustable ambient sound',
    'MODE_NC_NCSS_ASM_NOISE_CANCELLING_DUAL_AMBIENT_SOUND_MODE_LEVEL_ADJUSTMENT_WITH_TEST_MODE': 'Voice-spotlight and noise-control demo',
    'MODE_NC_ASM_NOISE_CANCELLING_DUAL_AMBIENT_SOUND_MODE_LEVEL_ADJUSTMENT_NOISE_ADAPTATION': 'Adaptive noise cancelling and ambient sound',
    'PRESET_EQ_NONCUSTOMIZABLE': 'Equalizer presets (fixed)', 'EBB': 'Bass boost', 'VPT': 'Virtual surround sound',
    'CONNECTION_MODE': 'Connection preference', 'CONNECTION_MODE_WITH_LDAC_STATUS': 'Connection preference and LDAC availability',
    'SOURCE_SWITCH_CONTROL': 'Switch audio source', 'PLAYBACK_CONTROLLER': 'Playback controls',
    'POWER_SAVING_MODE_ON_OFF': 'Power saving', 'BT_STANDBY': 'Bluetooth standby',
    'AUTO_STANDBY': 'Automatic standby', 'CHARGE_IN_USE': 'Charging during use',
    'FW_UPDATE': 'Firmware updates', 'CODEC_INDICATOR': 'Current audio codec',
    'PAIRING_DEVICE_MANAGEMENT_CLASSIC_BT': 'Paired Bluetooth devices',
    'PAIRING_DEVICE_MANAGEMENT_WITH_BLUETOOTH_CLASS_OF_DEVICE_CLASSIC_BT': 'Paired Bluetooth devices with device types',
    'PAIRING_DEVICE_MANAGEMENT_WITH_BLUETOOTH_CLASS_OF_DEVICE_CLASSIC_LE': 'Paired Classic and LE devices with device types',
}


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def fingerprint(root=ROOT):
    here = root / 'Helpers/SonyAPK'
    paths = {path for directory in (root / 'Sources', root / 'Tests', here)
             for path in directory.rglob('*') if path.suffix in ('.swift', '.py', '.java', '.json')}
    bindings = json.loads((here / 'implementation_routes.json').read_text())['features']
    paths.update(root / route['path'] for feature in bindings.values() for route in feature['routes'])
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(str(path.relative_to(root)).encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def implementation_results(observed, root=ROOT):
    bindings = json.loads((root / 'Helpers/SonyAPK/implementation_routes.json').read_text())['features']
    if set(bindings) != set(observed):
        raise ValueError('Implementation bindings and executed capability inventory differ')
    sources = {route['path']: (root / route['path']).read_text()
               for feature in bindings.values() for route in feature['routes']}
    results = {}
    for identity, feature in bindings.items():
        probe = observed[identity]
        runtime_evidence = feature.get('runtime_evidence', 'exposed')
        details = [dict(part='protocol', label=route['model'], path=route['source'],
                        symbol=route['symbol'], present=route[runtime_evidence]) for route in probe['routes']]
        routes = [dict(route, present=route['anchor'] in sources[route['path']]) for route in feature['routes']]
        details += [dict(part=route['part'], label=route['part'].capitalize(), path=route['path'],
                         symbol=route['anchor'], present=route['present']) for route in routes]
        wont_implement = feature.get('wont_implement_operations', [])
        details += [dict(part=operation, label=operation.replace('_', ' ').capitalize(), status='wont_implement')
                    for operation in wont_implement]
        missing = []
        for operation in feature['required_operations']:
            if operation in wont_implement:
                continue
            references = [route for route in routes if operation in route['operations']]
            present = bool(references) and all(route['present'] for route in references)
            if not present:
                missing.append(operation.replace('_', ' '))
                details.append(dict(part=operation, label=operation.replace('_', ' ').capitalize(), present=False))
        any_present = probe[runtime_evidence] or any(route['present'] for route in routes)
        protocol_present = probe[runtime_evidence] or not feature.get('runtime_required', True)
        complete = any_present and protocol_present and not missing and all(route['present'] for route in routes)
        result = 'available' if complete else 'partial' if any_present else 'missing'
        limitations = list(feature['limitations']) if result == 'partial' else []
        if result == 'partial' and not protocol_present:
            limitations.append('No feature query generated by the current capability dispatch.' if runtime_evidence == 'exposed'
                               else 'The current capability dispatch does not recognize this feature.')
        if missing and result == 'partial':
            limitations.append('Missing: ' + ', '.join(missing) + '.')
        results[identity] = dict(result=result, details=details, limitations=limitations)
    return results


def progress(coverage=None, report=None, implementation=None):
    manifest = json.loads((HERE / 'features.json').read_text())
    definitions = {item['id']: item for item in manifest['features'] if item['kind'] == 'device_capability'}
    rows = {item['id']: item for item in coverage['features']} if coverage else {}
    categories = {}
    features = []
    feature_checks = {}
    for check in report['checks'] if report else []:
        for identity in {value.rsplit('.', 1)[0] for value in check.get('coverage_ids', [])}:
            feature_checks.setdefault(identity, []).append(check)
    for identity, definition in definitions.items():
        row = rows.get(identity, {})
        category = definition['apk']['protocol_group'] or definition['namespace']
        family = category.split('-', 3)[-1] if category.startswith('mdr-') else category
        category_label = CATEGORY_NAMES.get(family, family.replace('_', ' ').capitalize())
        stages = {item.rsplit('.', 1)[1]: row.get('stages', {}).get(item.rsplit('.', 1)[1], {}).get('state', 'unverified')
                  for item in definition['required_coverage_ids']}
        exercised = sum(stages.get(stage) in ('exercised', 'verified') for stage in PROTOCOL_STAGES)
        entry = categories.setdefault(category, dict(name=category, total=0, exercised=0,
                                                     protocol_exercised=0, protocol_total=0))
        entry['total'] += 1
        entry['exercised'] += exercised > 0
        entry['protocol_exercised'] += exercised
        entry['protocol_total'] += sum(stage in stages for stage in PROTOCOL_STAGES)
        failures = sorted({check['case_id'] for value in row.get('stages', {}).values()
                           if value['state'] == 'failing' for check in value['evidence']
                           if check.get('status') not in ('pass', 'boundary-pass')})
        checks = feature_checks.get(identity, [])
        failed = sum(check['status'] not in ('pass', 'boundary-pass') for check in checks)
        passed = sum(check['status'] == 'pass' for check in checks)
        name = definition['name']
        display_name = FEATURE_NAMES.get(name, name.replace('_', ' ').capitalize())
        protocol = f'MDR {definition["generation"]}' if definition['generation'] else 'Bluetooth LE'
        support = implementation.get(identity, {}) if implementation is not None else {}
        features.append(dict(id=identity, name=name, display_name=display_name, category=category,
                             category_label=category_label, protocol=protocol, stages=stages,
                             status=row.get('verification_status', 'unverified'), failed_cases=failures,
                             test_result='fail' if failed else 'pass' if passed else 'untested',
                             test_count=len(checks), passed_tests=passed,
                             implementation_result=support.get('result'),
                             implementation_details=support.get('details', []),
                             limitations=support.get('limitations', [])))
    total = len(features)
    exercised = sum(value['exercised'] for value in categories.values())
    protocol_exercised = sum(value['protocol_exercised'] for value in categories.values())
    protocol_total = sum(value['protocol_total'] for value in categories.values())
    checks = Counter(item['status'] for item in report['checks']) if report else Counter()
    results = Counter(item['test_result'] for item in features)
    support_counts = Counter(item['implementation_result'] for item in features)
    return dict(implementation_ready=implementation is not None,
                summary=dict(total=total,
                             available=support_counts['available'], partial=support_counts['partial'], missing=support_counts['missing'],
                             implementation_percent=round(100 * support_counts['available'] / total, 1) if implementation is not None else None,
                             checked=total-results['untested'], passing=results['pass'], failing=results['fail'],
                             untested=results['untested'], tested_percent=round(100 * (total-results['untested']) / total, 1),
                             exercised_features=exercised, exercised_percent=round(100 * exercised / total, 1),
                             protocol_exercised=protocol_exercised, protocol_total=protocol_total,
                             protocol_percent=round(100 * protocol_exercised / protocol_total, 1),
                             passed=checks['pass'], boundary_passed=checks['boundary-pass'],
                             failed=sum(count for status, count in checks.items() if status not in ('pass', 'boundary-pass'))),
                categories=sorted(categories.values(), key=lambda item: item['name']), features=features)


class Verification:
    def __init__(self, args):
        self.args = args
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.requested = threading.Event()
        self.requested.set()
        self.state = dict(progress(), running=False, phase='Waiting for first run', started_at=None,
                          finished_at=None, error=None, receipt_valid=False, output_path=str(args.output))
        self.worker = threading.Thread(target=self.watch, daemon=True)

    def update(self, **values):
        with self.lock:
            self.state.update(values)

    def snapshot(self):
        with self.lock:
            return dict(self.state)

    def run(self):
        args = self.args
        args.output.mkdir(parents=True, exist_ok=True)
        self.update(**progress(), running=True, phase='Scanning Acouplet features',
                    started_at=timestamp(), finished_at=None, error=None, receipt_valid=False)
        import implementation as inventory
        observed = importlib.reload(inventory).collect(ROOT, args.output / 'implementation-models.json')
        implementation = implementation_results(observed)
        (args.output / 'implementation.json').write_text(json.dumps(implementation, indent=2) + '\n')
        self.update(**progress(implementation=implementation), phase='Compiling Acouplet protocol checks')
        command = [sys.executable, str(HERE / 'check.py'), '--apk', str(args.apk), '--serial', args.serial,
                   '--output', str(args.output), '--check-mutations']
        with (args.output / 'latest.log').open('w') as log:
            process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
            while process.poll() is None:
                if self.stop.wait(1):
                    process.send_signal(signal.SIGINT)
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                    return
                if (args.output / 'oracle.json').exists():
                    self.update(phase='Checking deliberate faults and calculating coverage')
                elif (args.output / 'swift.json').exists():
                    self.update(phase='Executing the original Sony APK')
        run = json.loads((args.output / 'run.json').read_text())
        if run['status'] != 'completed':
            raise RuntimeError(run.get('error', 'Verification did not finish'))
        report = json.loads((args.output / 'report.json').read_text())
        coverage = json.loads((args.output / 'coverage.json').read_text())
        errors = coverage['errors'] + [str(item) for item in coverage['report_errors']]
        if errors:
            raise RuntimeError('\n'.join(errors))
        self.update(**progress(coverage, report, implementation), receipt_valid=True,
                    phase='Checks passed' if process.returncode == 0 else 'Checks found failures',
                    error=None if process.returncode == 0 else 'Open the failing feature rows and latest.log for details.')

    def watch(self):
        previous = None
        while not self.stop.is_set():
            attempted = False
            try:
                current = fingerprint()
                if current != previous or self.requested.is_set():
                    attempted = True
                    previous = current
                    self.requested.clear()
                    self.run()
                    if fingerprint() != current:
                        self.update(**progress(), receipt_valid=False, phase='Code changed; rerunning checks')
                self.update(running=False)
            except Exception as error:
                self.update(running=False, receipt_valid=False, phase='Verification failed',
                            error=str(error))
            if attempted:
                self.update(finished_at=timestamp())
            self.stop.wait(2)


def self_test():
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        (root / 'Helpers/SonyAPK').mkdir(parents=True)
        (root / 'Sources').mkdir()
        source = root / 'Sources/Feature.swift'
        source.write_text('func readState() {}')
        binding = {'routes': [{'part': 'controller', 'path': 'Sources/Feature.swift',
                              'anchor': 'func readState()', 'operations': ['read_state']}],
                   'required_operations': ['read_state'], 'limitations': []}
        path = root / 'Helpers/SonyAPK/implementation_routes.json'
        path.write_text(json.dumps({'features': {'feature': binding}}))
        probe = {'feature': {'recognized': True, 'exposed': True, 'routes': []}}
        assert implementation_results(probe, root)['feature']['result'] == 'available'
        binding['required_operations'] += ['transfer_firmware', 'install_firmware']
        binding['wont_implement_operations'] = ['transfer_firmware', 'install_firmware']
        path.write_text(json.dumps({'features': {'feature': binding}}))
        result = implementation_results(probe, root)['feature']
        assert result['result'] == 'available'
        assert {item['part'] for item in result['details'] if item.get('status') == 'wont_implement'} == {
            'transfer_firmware', 'install_firmware'}
        binding['required_operations'] += ['read_update_identity', 'transfer_language', 'install_language']
        path.write_text(json.dumps({'features': {'feature': binding}}))
        result = implementation_results(probe, root)['feature']
        assert result['result'] == 'partial'
        assert {item['part'] for item in result['details'] if item.get('present') is False} == {
            'read_update_identity', 'transfer_language', 'install_language'}
        binding['required_operations'] = ['read_state', 'transfer_firmware', 'install_firmware']
        path.write_text(json.dumps({'features': {'feature': binding}}))
        probe['feature']['exposed'] = False
        assert implementation_results(probe, root)['feature']['result'] == 'partial'
        source.write_text('')
        assert implementation_results(probe, root)['feature']['result'] == 'missing'
        probe['feature']['exposed'] = True
        assert implementation_results(probe, root)['feature']['result'] == 'partial'
        source.write_text('func readState() {}')
        binding['required_operations'].append('write_state')
        path.write_text(json.dumps({'features': {'feature': binding}}))
        assert implementation_results(probe, root)['feature']['result'] == 'partial'
        (root / 'PreferencePane').mkdir()
        interface = root / 'PreferencePane/Feature.swift'
        interface.write_text('func displayState() {}')
        binding['routes'].append({'part': 'interface', 'path': 'PreferencePane/Feature.swift',
                                  'anchor': 'func displayState()', 'operations': ['display_state']})
        path.write_text(json.dumps({'features': {'feature': binding}}))
        previous = fingerprint(root)
        interface.write_text('')
        assert fingerprint(root) != previous
        source.write_text('func recognizeCapability() {}')
        interface.write_text('func displayAdvice() {}')
        binding = {'routes': [
            {'part': 'model', 'path': 'Sources/Feature.swift',
             'anchor': 'func recognizeCapability()', 'operations': ['recognize_capability']},
            {'part': 'interface', 'path': 'PreferencePane/Feature.swift',
             'anchor': 'func displayAdvice()', 'operations': ['display_advice']}],
            'required_operations': ['recognize_capability', 'display_advice'],
            'runtime_evidence': 'recognized', 'limitations': []}
        path.write_text(json.dumps({'features': {'feature': binding}}))
        probe['feature']['exposed'] = False
        assert implementation_results(probe, root)['feature']['result'] == 'available'
        interface.write_text('')
        assert implementation_results(probe, root)['feature']['result'] == 'partial'
        interface.write_text('func displayAdvice() {}')
        probe['feature']['recognized'] = False
        assert implementation_results(probe, root)['feature']['result'] == 'partial'
        probe['feature']['recognized'] = True
        source.write_text('')
        assert implementation_results(probe, root)['feature']['result'] == 'partial'
        probe['feature']['recognized'] = False
        interface.write_text('')
        assert implementation_results(probe, root)['feature']['result'] == 'missing'
    print('Implementation classification self-checks passed')


def main():
    parser = argparse.ArgumentParser(description='Run the local APK verification dashboard and rerun checks on source changes')
    parser.add_argument('--apk', type=Path)
    parser.add_argument('--serial')
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--port', type=int, default=8766)
    parser.add_argument('--output', type=Path, default=ROOT / '.build/sony-apk-live')
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not args.apk or not args.serial:
        parser.error('--apk and --serial are required')
    args.output = args.output.resolve()
    verification = Verification(args)
    hosts = {f'127.0.0.1:{args.port}', f'localhost:{args.port}'}

    class Handler(BaseHTTPRequestHandler):
        def respond(self, code, content, content_type):
            self.send_response(code)
            self.send_header('Content-Type', content_type)
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(content)))
            self.end_headers()
            self.wfile.write(content)

        def do_GET(self):
            if self.headers.get('Host') not in hosts:
                self.send_error(403)
            elif self.path == '/':
                self.respond(200, (HERE / 'web.html').read_bytes(), 'text/html; charset=utf-8')
            elif self.path == '/api/status':
                self.respond(200, json.dumps(verification.snapshot()).encode(), 'application/json')
            else:
                self.send_error(404)

        def do_POST(self):
            if self.headers.get('Host') not in hosts or self.headers.get('Origin') not in {f'http://{host}' for host in hosts}:
                self.send_error(403)
            elif self.path == '/api/run':
                verification.requested.set()
                self.respond(202, b'{"queued":true}', 'application/json')
            else:
                self.send_error(404)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    verification.worker.start()
    print(f'APK verification: http://127.0.0.1:{args.port}', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        verification.stop.set()
        verification.worker.join(timeout=15)
        server.server_close()


if __name__ == '__main__':
    main()

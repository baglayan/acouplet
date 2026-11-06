import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


SOURCES = (
    'SonyProtocol.swift', 'SonyLegacyControls.swift', 'SonyLegacySoundEffect.swift',
    'SonyLegacyOptimizer.swift', 'SonyLegacyIndicators.swift', 'SonyEqualizer.swift', 'SonyPlayback.swift',
    'SonyMultipoint.swift', 'SonySystemFeatures.swift', 'SonyAudioFeatures.swift',
    'SonyPowerFeatures.swift', 'SonyConnectionAlerts.swift', 'SonyEarTipFit.swift',
    'SonyHeadGesturePractice.swift', 'SonyTouchAssignments.swift', 'SonyVoiceGuidance.swift',
    'SonySoundPressure.swift', 'SonyWearingStatus.swift', 'SonyFirmwareUpdate.swift',
    'SonyNoiseControl.swift',
)


def noise_dispatch(source):
    patterns = {
        'mapping': r'    private static let asmByFunction: \[\(function: UInt8, type: UInt8\)\] = \[\n.*?^    \]',
        'selection': r'^        let supported = Self\.asmByFunction\.first\(where: \{ functions\.contains\(\$0\.function\) \}\)$',
        'initialization': r'^        noiseControl = supported\.map \{ .* \}$',
        'toggle': r'^        noiseToggle = .* \? SonyNoiseToggle\(\) : nil$',
        'test': r'^        noiseTest = supported\?\.type == .* \? SonyNoiseTest\(\) : nil$',
        'sequence': r'    private struct InitialFeatureReadSequence \{\n.*?^    \}',
        'request': r'    private func requestNoiseControl\(_ type: UInt8\) \{\n.*?^    \}',
    }
    fragments = {}
    for name, pattern in patterns.items():
        matches = list(re.finditer(pattern, source, re.MULTILINE | re.DOTALL if name in ('mapping', 'sequence', 'request') else re.MULTILINE))
        if len(matches) != 1:
            raise ValueError(f'Expected one production noise {name} declaration, got {len(matches)}')
        fragments[name] = matches[0].group()
    return ('struct ImplementationNoiseDispatch {\n'
            + fragments['mapping'] + '\n'
            + fragments['sequence'] + '\n'
            + '    struct Read { let timedOut: Bool }\n'
            + '    var noiseControlRead: Read?\n'
            + '    struct ReadTimeout { let work: Bool? }\n'
            + '    private var noiseReadTimeouts: [[UInt8]: ReadTimeout] = [:]\n'
            + '    private var noiseControlReadSequence: InitialFeatureReadSequence?\n'
            + '    var noiseControlSawValidChanging = false\n'
            + '    var noiseControl: SonyNoiseControl?\n'
            + '    var noiseToggle: SonyNoiseToggle?\n'
            + '    var noiseTest: SonyNoiseTest?\n'
            + '    var queries: [[UInt8]] = []\n'
            + '    mutating func send(_ payload: [UInt8]) { queries.append(payload) }\n'
            + fragments['request'].replace('private func ', 'private mutating func ', 1) + '\n'
            + '    mutating func collect(_ functions: Set<UInt8>) -> UInt8? {\n'
            + fragments['selection'] + '\n' + fragments['initialization'] + '\n' + fragments['toggle'] + '\n'
            + fragments['test'] + '\n'
            + '        if let supported { requestNoiseControl(supported.type) }\n'
            + '        return supported?.type\n    }\n}\n')


def fingerprints(root):
    paths = [root / 'Sources' / name for name in (*SOURCES, 'SonyHeadphonesController.swift')]
    paths += [root / 'Helpers/SonyAPK' / name for name in ('ImplementationAdapter.swift', 'implementation.py', 'features.json')]
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}


def collect(root, output_path):
    root = Path(root).resolve()
    output_path = Path(output_path)
    manifest = json.loads((root / 'Helpers/SonyAPK/features.json').read_text())
    features = [{key: entry[key] for key in ('id', 'namespace', 'capability_table', 'byte')}
                for entry in manifest['features'] if entry['kind'] != 'sentinel']
    identifiers = [entry['id'] for entry in features]
    if len(identifiers) != len(set(identifiers)):
        raise ValueError('Capability inventory has duplicate IDs')
    source_hashes = fingerprints(root)
    with tempfile.TemporaryDirectory(prefix='acouplet-implementation-probe-') as temporary:
        directory = Path(temporary)
        dispatch = directory / 'ImplementationNoiseDispatch.swift'
        dispatch.write_text(noise_dispatch((root / 'Sources/SonyHeadphonesController.swift').read_text()))
        binary = directory / 'implementation-probe'
        command = ['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                   *[str(root / 'Sources' / name) for name in SOURCES], str(dispatch),
                   str(root / 'Helpers/SonyAPK/ImplementationAdapter.swift'), '-o', str(binary)]
        compiler = subprocess.run(command, capture_output=True, text=True, timeout=120)
        if compiler.returncode:
            raise RuntimeError('Implementation probe compilation failed:\n' + compiler.stderr)
        execution = subprocess.run([str(binary)], input=json.dumps({'features': features}),
                                   capture_output=True, text=True, timeout=30)
        if execution.returncode:
            raise RuntimeError('Implementation probe execution failed:\n' + execution.stderr)
        rows = json.loads(execution.stdout)
    if [row['id'] for row in rows] != identifiers:
        raise ValueError('Implementation probe returned missing, duplicate or reordered capability IDs')
    if fingerprints(root) != source_hashes:
        raise ValueError('Implementation sources changed during collection')
    result = {row['id']: row for row in rows}
    artifact = {
        'schema_version': 1, 'generated_utc': datetime.now(timezone.utc).isoformat(),
        'evidence_kind': 'compiled_capability_probe', 'features': result,
        'source_sha256': source_hashes, 'compiler_command': command,
        'scope': 'Capability-driven production model initialization and query generation, plus compiled controller noise dispatch.',
        'limits': [
            'Recognized means a production model flag or selector accepted the advertised capability.',
            'Exposed means a model query was generated; it does not establish app wiring, UI visibility, writability or behavioral correctness.',
            'All model surfaces applicable to each protocol generation and table are probed independently for every inventory capability.',
            'Ear-tip selection is also probed with its required measurement capability and only additional queries are attributed to selection.',
            'Firmware identity queries support update availability lookup; firmware transfer is not established.',
            'Controller-only routes other than noise require separate application binding evidence.',
            'BLE ModelFeature has no production integration-bit decoder; general BLE transport support is not evidence for those bits.',
            'No physical headphones, Bluetooth transport, APK oracle, app bundle or network is used.',
        ],
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(artifact, indent=2) + '\n')
    return result



def check_mutation(root, baseline):
    root = Path(root).resolve()
    with tempfile.TemporaryDirectory(prefix='acouplet-implementation-mutation-') as temporary:
        mutated = Path(temporary)
        (mutated / 'Sources').mkdir()
        (mutated / 'Helpers/SonyAPK').mkdir(parents=True)
        for name in (*SOURCES, 'SonyHeadphonesController.swift'):
            shutil.copy2(root / 'Sources' / name, mutated / 'Sources' / name)
        for name in ('ImplementationAdapter.swift', 'implementation.py', 'features.json'):
            shutil.copy2(root / 'Helpers/SonyAPK' / name, mutated / 'Helpers/SonyAPK' / name)
        for name, before, after in (
            ('SonyAudioFeatures.swift', 'static let codecFunction: UInt8 = 0x12', 'static let codecFunction: UInt8 = 0x13'),
            ('SonyHeadphonesController.swift', '(0x6D, 0x19), ', ''),
            ('SonyHeadphonesController.swift', 'noiseToggle = functions.contains(0x69) ? SonyNoiseToggle() : nil',
             'noiseToggle = false ? SonyNoiseToggle() : nil'),
            ('SonyHeadphonesController.swift', 'noiseTest = supported?.type == 0x18 ? SonyNoiseTest() : nil',
             'noiseTest = supported?.type == 0xFE ? SonyNoiseTest() : nil'),
            ('SonyPowerFeatures.swift', 'else if powerSavingMode == nil { powerSavingMode = SonyPowerSwitch(inquiryType: 0x06) }',
             'else if powerSavingMode == nil { powerSavingMode = nil }'),
            ('SonyPowerFeatures.swift', 'else if bluetoothStandby == nil { bluetoothStandby = SonyPowerSwitch(inquiryType: 0x0D) }',
             'else if bluetoothStandby == nil { bluetoothStandby = nil }'),
            ('SonyPowerFeatures.swift', 'else if autoStandby == nil { autoStandby = SonyAutoStandby() }',
             'else if autoStandby == nil { autoStandby = nil }'),
            ('SonyPowerFeatures.swift', 'supportsChargeInUse = supportedFunctions2.contains(0x21)', 'supportsChargeInUse = false'),
        ):
            path = mutated / 'Sources' / name
            source = path.read_text()
            if source.count(before) != 1:
                raise ValueError(f'Mutation requires one source match: {name}: {before}')
            path.write_text(source.replace(before, after))
        manifest_path = mutated / 'Helpers/SonyAPK/features.json'
        manifest = json.loads(manifest_path.read_text())
        for entry in manifest['features']:
            entry['implementation'] = {'status': 'deliberately_untrusted'}
        for namespace, table in (('mdr-v1', 1), ('mdr-v2', 1), ('mdr-v2', 2)):
            manifest['features'].append({'id': f'empty-{namespace}-{table}', 'namespace': namespace,
                                         'capability_table': table, 'byte': 0, 'kind': 'device_capability'})
        manifest_path.write_text(json.dumps(manifest))
        changed = collect(mutated, mutated / 'result.json')
        for before, after in (('mdr-v2-t1-12', 'mdr-v2-t1-13'),):
            if not (baseline[before]['exposed'] and not baseline[after]['exposed']
                    and not changed[before]['exposed'] and changed[after]['exposed']):
                raise AssertionError(f'Runtime capability result did not follow production source mutation: {before} -> {after}')
        if not baseline['mdr-v2-t1-6d']['exposed'] or changed['mdr-v2-t1-6d']['exposed']:
            raise AssertionError('Removed production noise capability retained an implementation route')
        if not baseline['mdr-v2-t1-69']['exposed'] or changed['mdr-v2-t1-69']['exposed']:
            raise AssertionError('Removed production noise button-cycle capability retained an implementation route')
        baseline_test = [route for route in baseline['mdr-v2-t1-6c']['routes'] if route['model'] == 'SonyNoiseTest']
        changed_test = [route for route in changed['mdr-v2-t1-6c']['routes'] if route['model'] == 'SonyNoiseTest']
        if not baseline_test or changed_test or not changed['mdr-v2-t1-6c']['exposed']:
            raise AssertionError('Noise test capability did not follow its production gate independently of ordinary noise controls')
        removed_power = ('mdr-v2-t1-26', 'mdr-v2-t1-2d', 'mdr-v2-t2-20', 'mdr-v2-t2-21')
        for identifier in removed_power:
            if not baseline[identifier]['recognized'] or baseline[identifier]['exposed'] != (identifier != 'mdr-v2-t2-21'):
                raise AssertionError(f'Expected a query control or a command-free advisory: {identifier}')
            if changed[identifier]['recognized'] or changed[identifier]['exposed'] or changed[identifier]['routes']:
                raise AssertionError(f'Removed production power capability retained an implementation route: {identifier}')
        for identifier, row in changed.items():
            if identifier.startswith('empty-'):
                if row['recognized'] or row['exposed'] or row['routes']:
                    raise AssertionError(f'Unsupported capability received an unconditional model route: {identifier}')
            elif identifier not in ('mdr-v2-t1-12', 'mdr-v2-t1-13', 'mdr-v2-t1-69', 'mdr-v2-t1-6c', 'mdr-v2-t1-6d', *removed_power):
                if row != baseline[identifier]:
                    raise AssertionError(f'Unrelated capability changed after source/manifest mutation: {identifier}')
    return {'production_mutations_observed': 8, 'empty_capabilities_rejected': 3,
            'manifest_status_ignored': True}


def main():
    parser = argparse.ArgumentParser(description='Probe current production capability models independently of APK correctness tests')
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--self-check', action='store_true')
    arguments = parser.parse_args()
    features = collect(arguments.root, arguments.output)
    checks = check_mutation(arguments.root, features) if arguments.self_check else None
    print(json.dumps({'self_check': checks, 'features': len(features), 'recognized': sum(item['recognized'] for item in features.values()),
                      'exposed': sum(item['exposed'] for item in features.values()), 'output': str(arguments.output)}))


if __name__ == '__main__':
    main()

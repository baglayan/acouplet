from pathlib import Path
import argparse, json, re, runpy, subprocess

distribution = runpy.run_path(str(Path(__file__).with_name('check-distribution.py')))


def notarize(app, profile, evidence_dir, keychain=None):
    driver = app / 'Contents/Helpers/AcoupletLDACOutput.driver'
    _, _, signature = distribution['command'](['/usr/bin/codesign', '--display', '--verbose=4', str(driver)])
    team = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', signature.decode(errors='replace'), re.MULTILINE)
    checks = distribution['inspect_installer'](app, team[1] if team else None)
    if not all(checks.values()):
        raise ValueError('LDAC installer validation failed: ' + ', '.join(key for key, passed in checks.items() if not passed))
    installer = app / 'Contents/Resources/Acouplet LDAC Output.pkg'
    arguments = ['--keychain-profile', profile]
    if keychain: arguments += ['--keychain', str(keychain)]
    evidence_dir.mkdir(parents=True, exist_ok=True)
    result = json.loads(subprocess.check_output(['/usr/bin/xcrun', 'notarytool', 'submit', str(installer), *arguments, '--wait', '--output-format', 'json']))
    (evidence_dir / 'installer-notary-result.json').write_text(json.dumps(result, indent=2) + '\n')
    subprocess.run(['/usr/bin/xcrun', 'notarytool', 'log', result['id'], *arguments, str(evidence_dir / 'installer-notary-log.json')], check=True)
    if result['status'] != 'Accepted':
        raise RuntimeError('LDAC driver installer notarization was not accepted.')
    subprocess.run(['/usr/bin/xcrun', 'stapler', 'staple', str(installer)], check=True)
    subprocess.run(['/usr/bin/xcrun', 'stapler', 'validate', str(installer)], check=True)
    subprocess.run(['/usr/sbin/spctl', '--assess', '--type', 'install', str(installer)], check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=Path)
    parser.add_argument('--profile', required=True)
    parser.add_argument('--evidence-dir', type=Path, required=True)
    parser.add_argument('--keychain', type=Path)
    args = parser.parse_args()
    notarize(args.app, args.profile, args.evidence_dir, args.keychain)

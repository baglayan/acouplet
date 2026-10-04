from pathlib import Path
import subprocess
import sys

helpers = Path(sys.argv[1]) / 'Contents/Helpers'
for name, arguments in [
    ('LDACSignaling', ['--discover']),
    ('LDACMediaTransport', ['--media', '--pcm-fd', '3']),
    ('SonyAudioConnection', []),
]:
    result = subprocess.run([str(helpers / name), *arguments], capture_output=True, text=True, timeout=15)
    assert result.returncode == 2, (name, result.returncode, result.stderr)
    assert 'BEFORE' not in result.stdout, name

for name in ['LDACSignaling', 'LDACMediaTransport']:
    subprocess.run([str(helpers / name), '--self-test'], check=True, timeout=15)

print('LDAC helpers reject missing device addresses before Bluetooth access; offline self-checks passed.')

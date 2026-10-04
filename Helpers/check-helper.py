from pathlib import Path
import json, os, select, signal, subprocess, sys, tempfile, time, uuid

binary = str(Path(sys.argv[1]).resolve())
identifier, marker = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()


def sample(**updates):
    part = {'level': 40, 'isCharging': False, 'observedAt': time.time()}
    value = {'identifier': identifier, 'address': '02:00:00:00:00:19', 'controlSession': 1,
             'left': part, 'right': part.copy()}
    value.update(updates)
    return json.dumps(value) + '\n'


def child():
    return subprocess.Popen([binary, '--model', identifier, marker], stdin=subprocess.PIPE,
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)


def submitted(process, line):
    process.stdin.write(line)
    process.stdin.flush()
    assert select.select([process.stderr], [], [], 3)[0], 'helper did not acknowledge model input'
    reply = process.stderr.readline()
    assert 'NATIVE_BATTERY MODEL create=0x00000000 set=0x00000000 notify=0' in reply, reply


assert subprocess.run([binary, '--self-test'], check=True).returncode == 0
for publishes in (False, True):
    process = child()
    if publishes: submitted(process, sample())
    process.stdin.close()
    assert process.wait(timeout=3) == 0
    output = process.stderr.read()
    assert 'parent EOF' in output and 'release=' not in output, output
print('graceful EOF before/after model publication: passed')

for invalid in ('[]\n', sample(identifier=str(uuid.uuid4())), sample(right={'level': 0, 'isCharging': False, 'observedAt': time.time()})):
    process = child()
    output = process.communicate(invalid, timeout=3)[1]
    assert process.returncode == 2 and 'MODEL' not in output and 'release=' not in output, output
process = child()
line = sample()
submitted(process, line)
output = process.communicate(line, timeout=3)[1]
assert process.returncode == 2 and 'MODEL' not in output, output
print('invalid identity, unavailable part and replay stop without publication: passed')

process = child()
part = {'level': 40, 'isCharging': False, 'observedAt': time.time() - 19}
submitted(process, sample(left=part, right=part.copy()))
assert process.wait(timeout=28) == 0
output = process.stderr.read()
assert 'parent EOF' not in output and 'release=' not in output, output
process.stdin.close()
print('independent reading expiry stops with parent and pipe still alive: passed')

parent_source = '''import json, os, subprocess, sys, time
child = subprocess.Popen(sys.argv[1:5], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=open(sys.argv[5], 'w'))
print(child.pid, flush=True)
if sys.argv[6] == 'publish':
    child.stdin.write(sys.argv[7].encode()); child.stdin.flush()
time.sleep(30)
'''
with tempfile.TemporaryDirectory(prefix='acouplet-battery-eof-') as directory:
    for publishes in (False, True):
        log = Path(directory) / ('published.log' if publishes else 'empty.log')
        parent = subprocess.Popen([sys.executable, '-c', parent_source, binary, '--model', identifier, marker, str(log),
                                   'publish' if publishes else 'empty', sample()], stdout=subprocess.PIPE, text=True)
        try:
            assert select.select([parent.stdout], [], [], 3)[0], 'parent did not spawn child'
            child_pid = int(parent.stdout.readline())
            if publishes:
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline and 'NATIVE_BATTERY MODEL' not in log.read_text(): time.sleep(0.02)
                assert 'NATIVE_BATTERY MODEL' in log.read_text()
            parent.kill()
            assert parent.wait(timeout=3) == -signal.SIGKILL
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline and 'NATIVE_BATTERY exit=0' not in log.read_text(): time.sleep(0.02)
            output = log.read_text()
            assert 'parent EOF' in output and 'NATIVE_BATTERY exit=0' in output and 'release=' not in output, output
        finally:
            if parent.poll() is None: parent.kill(); parent.wait(timeout=3)
print('verified parent SIGKILL before/after model publication closes child stdin: passed')
print('model-only checks complete; no IOPS calls')

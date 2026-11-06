import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import uuid


APK_SHA256 = "58837826f5f145cd0ad9689a298d2bfe9702f4d51d6d4e67d41440175ec0892c"


class APKOracle:
    def __init__(self, apk_path, serial, sdk_path=None):
        self.apk_path = Path(apk_path).resolve()
        self.serial = serial
        self.sdk_path = Path(sdk_path or os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk"))
        self.adb = self.sdk_path / "platform-tools/adb"
        self.remote = "/data/local/tmp/sony-apk-oracle-" + uuid.uuid4().hex
        self.temporary = None
        self.remote_created = False

    def adb_run(self, *arguments, timeout=120):
        return subprocess.run(
            [str(self.adb), "-s", self.serial, *arguments],
            check=True, capture_output=True, text=True, timeout=timeout,
        ).stdout

    def __enter__(self):
        digest = hashlib.sha256(self.apk_path.read_bytes()).hexdigest()
        if digest != APK_SHA256:
            raise ValueError(f"APK SHA256 mismatch: expected {APK_SHA256}, got {digest}")
        if not self.serial.startswith("emulator-") or self.adb_run("shell", "getprop ro.kernel.qemu").strip() != "1":
            raise ValueError("The original-APK oracle requires an Android emulator")
        self.temporary = tempfile.TemporaryDirectory(prefix="sony-apk-oracle-")
        try:
            self.directory = Path(self.temporary.name)
            classes = self.directory / "classes"
            classes.mkdir()
            platform = self.sdk_path / "platforms/android-33/android.jar"
            subprocess.run([
                "javac", "--release", "8", "-classpath", str(platform), "-d", str(classes),
                *map(str, sorted(Path(__file__).parent.glob("*.java"))),
            ], check=True, capture_output=True, text=True, timeout=120)
            subprocess.run([
                str(self.sdk_path / "build-tools/36.0.0/d8"), "--lib", str(platform),
                "--min-api", "26", "--output", str(self.directory),
                *map(str, classes.glob("*.class")),
            ], check=True, capture_output=True, text=True, timeout=120)
            self.adb_run("shell", "mkdir " + shlex.quote(self.remote))
            self.remote_created = True
            self.adb_run("push", str(self.apk_path), self.remote + "/base.apk")
            self.adb_run("push", str(self.directory / "classes.dex"), self.remote + "/runner.dex")
            remote_digest = self.adb_run("shell", "sha256sum " + shlex.quote(self.remote + "/base.apk")).split()[0]
            if remote_digest != APK_SHA256:
                raise ValueError("The APK copied to the emulator does not match the pinned SHA256")
            self.adb_run("shell", "chmod 444 " + shlex.quote(self.remote + "/base.apk"))
        except BaseException:
            self.close()
            raise
        return self

    def run(self, calls):
        request = self.directory / "request.json"
        request.write_text(json.dumps({"calls": calls}), encoding="utf-8")
        self.adb_run("push", str(request), self.remote + "/request.json")
        command = (
            "CLASSPATH=" + shlex.quote(self.remote + "/runner.dex") + " app_process /system/bin OracleRunner "
            + shlex.quote(self.remote + "/base.apk") + " " + shlex.quote(self.remote + "/request.json")
        )
        output = self.adb_run("shell", command)
        prefix = "SONY_APK_ORACLE_RESULT="
        lines = [line[len(prefix):] for line in output.splitlines() if line.startswith(prefix)]
        if len(lines) != 1:
            raise RuntimeError("Expected one oracle result, received: " + output)
        result = json.loads(lines[0])
        result["apk_sha256"] = APK_SHA256
        result["serial"] = self.serial
        return result

    def close(self):
        try:
            if self.remote_created:
                self.adb_run("shell", "rm -rf " + shlex.quote(self.remote))
                self.remote_created = False
        finally:
            if self.temporary is not None:
                self.temporary.cleanup()
                self.temporary = None

    def __exit__(self, exception_type, exception, traceback):
        self.close()


def main():
    parser = argparse.ArgumentParser(description="Invoke original Sony APK classes on an Android emulator")
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--sdk", type=Path)
    parser.add_argument("--input", required=True, type=Path)
    arguments = parser.parse_args()
    request = json.loads(arguments.input.read_text(encoding="utf-8"))
    with APKOracle(arguments.apk, arguments.serial, arguments.sdk) as oracle:
        print(json.dumps(oracle.run(request["calls"]), indent=2))


if __name__ == "__main__":
    main()

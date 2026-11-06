# Sony original-APK verification

A small local program compares Acouplet's production Swift protocol code with the original Sony Sound Connect 13.3.0 APK on an Android emulator. Its browser interface compares Sony's device-feature inventory with Acouplet's current implementation and shows APK test results separately. It does not install Acouplet, install the Sony app, or deploy a website.

## Run the local program

These commands use the existing checkout, APK, Xcode, Java, Android SDK, and running `emulator-5556`. The SDK needs platform `android-33`, build tools `36.0.0`, and `platform-tools/adb`.

```sh
cd /Users/meric/Development/acouplet/apk-verification
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
export JAVA_HOME=/Library/Java/JavaVirtualMachines/zulu-11.jdk/Contents/Home
export PATH="$JAVA_HOME/bin:$PATH"

python3 Helpers/SonyAPK/serve.py \
  --apk '/Users/meric/Library/Application Support/XM5 Control/Research/SoundConnect/13.3.0-130305109/base.apk' \
  --serial emulator-5556 \
  --port 8766 \
  --output .build/sony-apk-live
```

Open <http://127.0.0.1:8766>. The interface refreshes every two seconds. **Run tests** requests a new execution. Leave the server running to see current progress and validated results; stop it with Control-C. No frontend build, framework, or external asset is needed.

The pinned APK SHA-256 is `58837826f5f145cd0ad9689a298d2bfe9702f4d51d6d4e67d41440175ec0892c`. A different APK is rejected. The default Android SDK path is `/Users/meric/Library/Android/sdk` on this machine. The oracle rejects physical Android devices.

## Read the comparison

Each row is one device capability declared by the original APK. There are 244 non-sentinel entries across MDR 1, MDR 2 and BLE ModelFeature. The same feature can have separate protocol variants; generation, table and byte identify each row.

- **Available:** the current capability probe and all registered application operations are present.
- **Partial:** some implementation exists, but an operation or interface is missing. Expand the row to see which part.
- **Missing:** neither the probe nor the registered application routes finds a usable implementation.

Firmware transfer and installation are marked **Won’t be implemented** in each firmware row. These two operations are excluded from implementation completion; firmware version and update information remain in scope. Firmware rows stay in the denominator, and language transfer and installation remain required where registered.

The percentage is Available / 244. Partial entries are counted separately, without assigning them an arbitrary percentage. The APK-check column reports actual original-DEX comparisons independently. A feature can be available without those comparisons yet, or have passing protocol tests while its application interface is missing.

`implementation.py` compiles and runs Acouplet's production capability models for every inventory entry. It also extracts and compiles the controller's actual noise-control dispatch. `implementation_routes.json` binds each feature to its required application operations and exact controller/interface entry points. The server rechecks those bindings against current source. Controller-only features have explicit capability gates. No stored implementation status or model-chat output determines the results.

New implementations need their production entry points registered in the bindings, just as new checks need registration. Missing bindings cannot establish that no code exists anywhere. A runtime capability flag alone is insufficient: it must generate a query or have an application operation. The bindings describe implementation presence, not correctness of every branch or successful operation on every headphone. The separate APK checks test behavior; hardware compatibility still requires hardware evidence.

The program reruns when source, harness or binding files change. Failed compilation and stale evidence are shown as errors, not as missing features. Results overwrite the previous local run in `.build/sony-apk-live`; they do not accumulate indefinitely. No headphones, Bluetooth radio or sound is used by this program.

## Run the harness directly

To create a saved receipt without the local server:

```sh
python3 Helpers/SonyAPK/check.py \
  --apk '/Users/meric/Library/Application Support/XM5 Control/Research/SoundConnect/13.3.0-130305109/base.apk' \
  --serial emulator-5556 \
  --sdk /Users/meric/Library/Android/sdk \
  --output .build/sony-apk-resume/full
```

Default groups are `framing`, `legacy`, `legacy_features`, `modern`, `modern_playback`, `modern_noise`, `common_connection`, `connection_identity`, `queue`, `battery`, `equalizer`, `power`, `legacy_indicators`, and `legacy_noise`. Add `--groups legacy legacy_features` for a subset or `--check-mutations` for registered deliberate source mutations after a passing baseline. A subset can establish only the obligations its cases cover.

The output directory contains `run.json`, `report.json`, `coverage.json`, the original APK inventory, inputs, Swift results, and APK results. Reusing a directory removes the previous report and evidence artifacts at the start of a new run. Choose another directory to preserve an earlier receipt. Failed runs record their error in `run.json`.

Revalidate a saved receipt against current source and registered cases without a running emulator:

```sh
python3 Helpers/SonyAPK/coverage.py \
  --inventory .build/sony-apk-resume/full/inventory.json \
  --report .build/sony-apk-resume/full \
  --output .build/sony-apk-resume/full
```

`--report` accepts a run directory or `report.json` path and may be repeated. Coverage exits with status 1 while full feature verification remains incomplete, even when all supplied protocol comparisons pass.

Harness self-checks do not execute the APK or physical hardware:

```sh
python3 Helpers/SonyAPK/check.py --self-test
python3 Helpers/SonyAPK/coverage.py --self-test
python3 Helpers/SonyAPK/serve.py --self-test
python3 Helpers/SonyAPK/implementation.py --output .build/sony-apk-live/implementation-models.json --self-check
```

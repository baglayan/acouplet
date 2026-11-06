from pathlib import Path
import base64, hashlib, importlib.util, json, os, plistlib, shutil, subprocess, tempfile

packaging = Path(__file__).resolve().parent
root = packaging.parent
spec = importlib.util.spec_from_file_location('artwork', packaging / 'prepare-no-sony-artwork.py')
artwork = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artwork)
roles = ('hero', 'left', 'right', 'caseImage', 'openCase')
evidence = json.loads((root / 'Tests/Fixtures/SonyArtworkEvidence.json').read_text())
metadata_path = root / 'Resources/SonyArtworkCatalog.json'
metadata = json.loads(metadata_path.read_text())
assert metadata['sourceSHA256'] == evidence['sourceSHA256']
device_names = {name: catalog_name for catalog_name, entry in evidence['models'].items()
                for name in entry.get('deviceNames', [catalog_name])}

protocol = (root / 'Sources/SonyProtocol.swift').read_text()
model = protocol.split('enum SonyDeviceModel:', 1)[1].split('\nstruct SonyProtocolInfo:', 1)[0]
color = protocol.split('struct SonyDeviceColor:', 1)[1].split('\nstruct SonyDeviceInformation:', 1)[0]
source = 'import AppKit\nenum SonyDeviceModel:' + model + '\nstruct SonyDeviceColor:' + color + '''
func fields(_ artwork: SonyProductArtwork?) -> [String: String] {
    guard let artwork else { return [:] }
    return ["hero": artwork.hero, "left": artwork.left, "right": artwork.right,
            "caseImage": artwork.caseImage, "openCase": artwork.openCase].compactMapValues { $0 }
}

let names = try! JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let bundle = Bundle(path: CommandLine.arguments[2])!
let resolved = Dictionary(uniqueKeysWithValues: names.map { ($0, SonyDeviceModel(name: $0).rawValue) })
var models: [String: Any] = [:]
var loaded: Set<String> = []
for model in SonyDeviceModel.allCases {
    var colors: [String: [String: String]] = [:]
    for value in UInt16(0)...255 {
        let images = fields(model.productArtwork(for: SonyDeviceColor(rawValue: UInt8(value))))
        if !images.isEmpty { colors[String(value)] = images }
    }
    let vectors = [model.symbol, model.leftSymbol, model.rightSymbol, model.caseSymbol, model.filledCaseSymbol].compactMap { $0 }
    let photos = colors.values.flatMap { $0.values }
    for name in vectors + photos where loaded.insert(name).inserted {
        assert(bundle.image(forResource: name) != nil, "Unresolved bundled image: " + name)
    }
    models[model.rawValue] = ["colors": colors, "default": fields(model.productArtwork(for: nil))]
}
let result: [String: Any] = ["resolved": resolved, "models": models, "loaded": loaded.sorted()]
print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
'''


def check_mapping(result, photos):
    resolved = result['resolved']
    assert 'unknown' not in resolved.values(), resolved
    assert len(set(resolved.values())) == len(device_names)
    assert set(resolved.values()) == set(metadata['models']) == set(result['models']) - {'unknown'}
    assert result['models']['unknown'] == {'colors': {}, 'default': {}}
    expected_assets = set(artwork.mini_icons)
    for name, catalog_name in device_names.items():
        raw = resolved[name]
        entry = metadata['models'][raw]
        expected_colors = evidence['models'][catalog_name]['colors']
        assert entry['catalogName'] == catalog_name, (raw, catalog_name)
        assert set(entry['colors']) == set(expected_colors), (raw, set(entry['colors']) ^ set(expected_colors))
        for color, url in expected_colors.items():
            assert entry['colors'][color]['sourceImageURL'] == url, (raw, color)
        expected = {color: {role: images[role] for role in roles if images.get(role)}
                    for color, images in entry['colors'].items()} if photos else {}
        assert result['models'][raw]['colors'] == expected, raw
        assert result['models'][raw]['default'] == expected.get('0', {}), raw
        expected_assets.update(name for images in expected.values() for name in images.values())
    assert set(result['loaded']) == expected_assets


def compile_catalog(catalog, destination):
    bundle = destination / 'Artwork.bundle'
    resources = bundle / 'Contents/Resources'
    resources.mkdir(parents=True, exist_ok=True)
    (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'dev.baglayan.artwork-check',
                                                               'CFBundlePackageType': 'BNDL'}))
    result = subprocess.run(['/usr/bin/xcrun', 'actool', '--compile', str(resources), '--platform', 'macosx',
                             '--minimum-deployment-target', '27.0', '--target-device', 'mac',
                             '--output-format', 'human-readable-text', str(catalog)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert (resources / 'Assets.car').is_file()
    return bundle


with tempfile.TemporaryDirectory(prefix='acouplet-artwork-catalog-check-') as directory:
    temporary = Path(directory)
    names = temporary / 'device-names.json'
    names.write_text(json.dumps(list(device_names)))
    check = temporary / 'main.swift'
    check.write_text(source)
    fixture = temporary / 'Photographs.xcassets'
    fixture.mkdir()
    contents = {'images': [{'filename': 'photo.png', 'idiom': 'universal'}], 'info': {'version': 1, 'author': 'xcode'}}
    png = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=')
    for name in artwork.required_photographs(root / 'Resources/Assets.xcassets'):
        folder = fixture / (name + '.imageset')
        folder.mkdir()
        (folder / 'Contents.json').write_text(json.dumps(contents))
        (folder / 'photo.png').write_bytes(png)
    binaries = {}
    for photos in (True, False):
        catalog = temporary / ('Photos.xcassets' if photos else 'Vectors.xcassets')
        artwork.prepare(root / 'Resources/Assets.xcassets', catalog, fixture if photos else None)
        for public in (False, True):
            output = temporary / f'photos-{photos}-public-{public}'
            output.mkdir()
            bundle = compile_catalog(catalog, output)
            if photos:
                shutil.copy2(metadata_path, output / metadata_path.name)
            flags = ([] if photos else ['-D', 'ACOUPLET_NO_SONY_ARTWORK']) + (['-D', 'ACOUPLET_PUBLIC_APIS_ONLY'] if public else [])
            binary = output / 'check-model'
            subprocess.run(['/usr/bin/xcrun', 'swiftc', '-swift-version', '6', '-D', 'DEBUG', *flags,
                            str(check), '-o', str(binary)], check=True)
            result = json.loads(subprocess.check_output([str(binary), str(names), str(bundle)]))
            check_mapping(result, photos)
            binaries[(photos, public)] = binary
    external = os.environ.get('ACOUPLET_SONY_ARTWORK_DIR')
    photographs = Path(external) if external else root.parent / 'private/sony-artwork/Assets.xcassets'
    if external or photographs.is_dir():
        catalog = temporary / 'External.xcassets'
        artwork.prepare(root / 'Resources/Assets.xcassets', catalog, photographs)
        for public in (False, True):
            binary = binaries[(True, public)]
            bundle = compile_catalog(catalog, binary.parent)
            result = json.loads(subprocess.check_output([str(binary), str(names), str(bundle)]))
            check_mapping(result, True)
        manifest_path = photographs.parent / 'manifest.json'
        if manifest_path.is_file():
            manifest = json.loads(manifest_path.read_text())
            assert manifest['catalog']['sourceSHA256'] == evidence['sourceSHA256']
            mappings = {(entry['catalogName'], str(entry['color']), entry['hero'], entry['imageURL'])
                        for entry in manifest['catalog']['mappings']}
            expected = {(entry['catalogName'], color, images['hero'], images['sourceImageURL'])
                        for entry in metadata['models'].values() for color, images in entry['colors'].items()}
            assert mappings == expected
            for entry in manifest['files']:
                path = photographs / entry['path']
                assert hashlib.sha256(path.read_bytes()).hexdigest() == entry['sha256'], path
        print('Real external photographs compiled and resolved in private/public API modes')
    else:
        print('External photographs unavailable; deterministic complete catalog compiled and resolved')

print(f'Independent official catalog coverage: {len(device_names)} models, '
      f'{sum(len(evidence["models"][name]["colors"]) for name in device_names.values())} model/color pairs; '
      'all 256 color bytes, artwork/public build flags and bundled image resolution passed')

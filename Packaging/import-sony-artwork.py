from pathlib import Path
import argparse, concurrent.futures, hashlib, json, re, struct, subprocess, tempfile, urllib.request, zlib

root = Path(__file__).resolve().parent.parent
asset_fields = ('hero', 'left', 'right', 'caseImage', 'openCase')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_png(data):
    if len(data) > 20 * 1024 * 1024 or data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('Expected a PNG image smaller than 20 MiB')
    offset = 8
    while offset + 12 <= len(data):
        size = struct.unpack('>I', data[offset:offset + 4])[0]
        end = offset + size + 12
        chunk = data[offset + 4:end - 4]
        if end > len(data) or zlib.crc32(chunk) != struct.unpack('>I', data[end - 4:end])[0]:
            raise ValueError('Invalid PNG chunk')
        if offset == 8:
            if chunk[:4] != b'IHDR' or size != 13:
                raise ValueError('Missing PNG header')
            width, height = struct.unpack('>II', chunk[4:12])
            if not 0 < width <= 8192 or not 0 < height <= 8192:
                raise ValueError('Unsupported image dimensions')
        if chunk[:4] == b'IEND':
            if size != 0 or end != len(data):
                raise ValueError('Invalid PNG end')
            return
        offset = end
    raise ValueError('Truncated PNG image')


def download(item):
    name, url = item
    with urllib.request.urlopen(url, timeout=30) as response:
        if response.url != url:
            raise ValueError('Catalog image redirected to a different URL')
        data = response.read(20 * 1024 * 1024 + 1)
    validate_png(data)
    return name, data


def inspect_catalog(catalog_path, metadata):
    if digest(catalog_path) != metadata['sourceSHA256']:
        raise ValueError('The catalog does not match the metadata source snapshot')
    rows = json.loads(catalog_path.read_text())['data']['HPC']['getAllCloudModelInfos']
    catalog = {}
    for row in rows:
        name, color = row['model_name'], str(int(row['model_color_id'], 16))
        url = row['sca_image_image_url']
        if not re.fullmatch(r'https://hpc-image\.data-gateway\.seeds\.services/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\.png', url):
            raise ValueError('Unexpected catalog image URL')
        if color in catalog.setdefault(name, {}):
            raise ValueError('Duplicate catalog model/color pair')
        catalog[name][color] = url
    if len(rows) > 512 or set(catalog) != {entry['catalogName'] for entry in metadata['models'].values()}:
        raise ValueError('Metadata must cover the bounded catalog model set exactly')
    downloads, mappings, required = {}, [], set()
    for entry in metadata['models'].values():
        name, colors = entry['catalogName'], entry['colors']
        if set(colors) != set(catalog[name]):
            raise ValueError(f'Incomplete colors for {name}')
        for color, artwork in colors.items():
            url = catalog[name][color]
            if artwork['sourceImageURL'] != url:
                raise ValueError(f'Incorrect source image for {name} color {color}')
            for field in asset_fields:
                if field in artwork:
                    asset = artwork[field]
                    if not re.fullmatch(r'[A-Za-z0-9]+', asset):
                        raise ValueError('Invalid asset name')
                    required.add(asset)
            hero = artwork['hero']
            imported = hero.startswith('SonyCatalog')
            if imported:
                if hero != 'SonyCatalog' + Path(url).stem.replace('-', ''):
                    raise ValueError('Imported hero name does not match its source image')
                downloads[hero] = url
            mappings.append(dict(catalogName=name, color=int(color), imageURL=url, hero=hero,
                                 verification='official-catalog-download' if imported else 'existing-verified-finish'))
    return downloads, mappings, required


def image_bounds(paths, split=False):
    with tempfile.TemporaryDirectory(prefix='acouplet-artwork-bounds-') as directory:
        binary = Path(directory) / 'bounds'
        subprocess.run(['/usr/bin/xcrun', 'swiftc', '-O', str(root / 'Packaging/sony-artwork-bounds.swift'),
                        '-o', str(binary)], check=True, capture_output=True)
        result = subprocess.run([str(binary)] + (['--split'] if split else []), input=json.dumps([str(path) for path in paths]),
                                text=True, capture_output=True, check=True)
        return json.loads(result.stdout)


def validate_bounds(metadata, bounds, update=False):
    for model in metadata['models'].values():
        for artwork in model['colors'].values():
            if artwork['hero'] in bounds:
                if update:
                    artwork['heroBounds'] = bounds[artwork['hero']]
                elif artwork.get('heroBounds') != bounds[artwork['hero']]:
                    raise ValueError(f'Incorrect visible bounds for {artwork["hero"]}')
            elif 'heroBounds' in artwork:
                raise ValueError('Existing photographs must retain their original framing')


def validate_side_bounds(metadata, bounds, update=False):
    for model, source in metadata['sideSources'].items():
        if source['physicalLeft'] != 'screen-right':
            raise ValueError(f'Unsupported documented side order for {model}')
        for artwork in metadata['models'][model]['colors'].values():
            parts = bounds[artwork['hero']]
            expected = ({'left': artwork['hero'], 'right': artwork['hero'],
                         'leftBounds': parts[1], 'rightBounds': parts[0]} if len(parts) == 2 else {})
            for field in ('left', 'right', 'leftBounds', 'rightBounds'):
                if update:
                    if field in expected:
                        artwork[field] = expected[field]
                    else:
                        artwork.pop(field, None)
                elif artwork.get(field) != expected.get(field):
                    raise ValueError(f'Incorrect side crop for {model} {artwork["hero"]}')


def run(catalog_path, artwork_dir, download_missing, update_bounds=False):
    artwork_dir = artwork_dir.resolve()
    if artwork_dir.is_relative_to(root):
        raise ValueError('Sony photographs must remain outside the source repository')
    assets = artwork_dir / 'Assets.xcassets'
    if assets.is_symlink() or assets.resolve().is_relative_to(root):
        raise ValueError('The external asset catalog must not link into the source repository')
    manifest_path = artwork_dir / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    metadata = json.loads((root / 'Resources/SonyArtworkCatalog.json').read_text())
    downloads, mappings, required = inspect_catalog(catalog_path, metadata)
    for entry in manifest['files']:
        path = assets / entry['path']
        if not path.resolve().is_relative_to(assets.resolve()) or path.is_symlink() or digest(path) != entry['sha256']:
            raise ValueError(f'Existing artwork changed: {entry["path"]}')
    missing = [(name, url) for name, url in downloads.items() if not (assets / (name + '.imageset')).exists()]
    if missing and not download_missing:
        raise ValueError(f'{len(missing)} official images missing; run with --download to import them')
    if missing:
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
            images = list(executor.map(download, missing))
        for name, data in images:
            folder = assets / (name + '.imageset')
            folder.mkdir()
            (folder / (name + '.png')).write_bytes(data)
            contents = {'images': [{'filename': name + '.png', 'idiom': 'universal'}],
                        'info': {'author': 'xcode', 'version': 1}}
            (folder / 'Contents.json').write_text(json.dumps(contents, indent=2) + '\n')
    for name in required:
        folder = assets / (name + '.imageset')
        if folder.is_symlink():
            raise ValueError(f'Linked image set: {name}')
        contents = json.loads((folder / 'Contents.json').read_text())
        images = [image['filename'] for image in contents['images'] if 'filename' in image]
        if not images:
            raise ValueError(f'No image for {name}')
        for filename in images:
            path = folder / filename
            if path.is_symlink() or path.parent != folder or path.suffix.lower() != '.png':
                raise ValueError(f'Invalid image path for {name}')
            validate_png(path.read_bytes())
    bounds = image_bounds([assets / (name + '.imageset') / (name + '.png') for name in downloads])
    validate_bounds(metadata, bounds, update=update_bounds)
    side_names = {artwork['hero'] for name in metadata['sideSources'] for artwork in metadata['models'][name]['colors'].values()}
    side_bounds = image_bounds([assets / (name + '.imageset') / (name + '.png') for name in sorted(side_names)], split=True)
    validate_side_bounds(metadata, side_bounds, update=update_bounds)
    if update_bounds:
        (root / 'Resources/SonyArtworkCatalog.json').write_text(json.dumps(metadata, indent=2) + '\n')
    updated = dict(manifest, imageSets=sorted(path.name for path in assets.glob('*.imageset')),
                   files=[{'path': path.relative_to(assets).as_posix(), 'sha256': digest(path)}
                          for path in sorted(assets.rglob('*')) if path.is_file()],
                   catalog={'sourceSHA256': metadata['sourceSHA256'], 'mappings': mappings})
    if download_missing:
        manifest_path.write_text(json.dumps(updated, indent=2) + '\n')
    elif updated != manifest:
        raise ValueError('External manifest is incomplete or stale; run with --download to refresh it')
    print(f'Verified {len(metadata["models"])} models, {len(mappings)} model/color pairs and {len(required)} required assets; imported {len(missing)} official images')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Check external Sony artwork offline against the saved official catalog; optionally download missing catalog PNGs.')
    parser.add_argument('--catalog', type=Path, required=True)
    parser.add_argument('--artwork-dir', type=Path, required=True, help='External directory containing Assets.xcassets and manifest.json')
    parser.add_argument('--download', action='store_true', help='Fetch only missing image URLs from the verified catalog snapshot and refresh the external manifest')
    parser.add_argument('--update-bounds', action='store_true', help='Derive whole-image visible bounds from imported PNGs and update metadata')
    args = parser.parse_args()
    run(args.catalog, args.artwork_dir, args.download, args.update_bounds)

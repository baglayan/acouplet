from pathlib import Path
import importlib.util, struct, tempfile, zlib

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('artwork_import', root / 'Packaging/import-sony-artwork.py')
artwork = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artwork)


def rejects_png(data):
    try:
        artwork.validate_png(data)
    except ValueError:
        return
    raise AssertionError('Invalid downloaded image was accepted')


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))


png = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(b'\x00\x00\x00\x00\x00')) + chunk(b'IEND', b''))
artwork.validate_png(png)
for invalid in (b'<html>Server error</html>', png[:-1], png + b'extra', png[:45] + b'\x01' + png[46:]):
    rejects_png(invalid)
rejects_png(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 8193, 1, 8, 6, 0, 0, 0)) + chunk(b'IEND', b''))
with tempfile.TemporaryDirectory(prefix='acouplet-import-check-') as directory:
    external = Path(directory)
    (external / 'Assets.xcassets').symlink_to(root / 'Resources/Assets.xcassets')
    try:
        artwork.run(external / 'unused.json', external, True)
    except ValueError:
        pass
    else:
        raise AssertionError('External symlink allowed photographs into the source repository')
with tempfile.TemporaryDirectory(prefix='acouplet-bounds-check-') as directory:
    folder = Path(directory)
    images = []
    for name, visible in [('asymmetric', {(x, y): 255 for y in range(2) for x in range(1, 4)}),
                          ('partial', {(3, 2): 1}),
                          ('vertical', {(0, 1): 255, (4, 2): 1}),
                          ('horizontal', {(2, 0): 255, (3, 0): 255, (4, 0): 255, (0, 3): 255, (1, 3): 255, (2, 3): 255}),
                          ('crossing', {(0, 0): 255, (1, 1): 255, (2, 2): 255, (3, 3): 255, (4, 3): 255})]:
        rows = b''.join(b'\x00' + b''.join(bytes([255, 255, 255, visible.get((x, y), 0)])
                                           for x in range(5)) for y in range(4))
        data = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 5, 4, 8, 6, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))
        path = folder / (name + '.png')
        path.write_bytes(data)
        images.append(path)
    measured = artwork.image_bounds(images)
    assert measured['asymmetric'] == {'x': 0.2, 'y': 0, 'width': 0.6, 'height': 0.5}, measured
    assert measured['partial'] == {'x': 0.6, 'y': 0.5, 'width': 0.2, 'height': 0.25}, measured
    parts = artwork.image_bounds(images, split=True)
    assert parts['vertical'] == [{'x': 0, 'y': 0.25, 'width': 0.2, 'height': 0.25},
                                 {'x': 0.8, 'y': 0.5, 'width': 0.2, 'height': 0.25}], parts
    assert parts['horizontal'] == [{'x': 0, 'y': 0.75, 'width': 0.6, 'height': 0.25},
                                   {'x': 0.4, 'y': 0, 'width': 0.6, 'height': 0.25}], parts
    assert parts['crossing'] == []
    side_entry = {'hero': 'vertical'}
    side_metadata = {'sideSources': {'model': {'physicalLeft': 'screen-right'}},
                     'models': {'model': {'colors': {'0': side_entry}}}}
    artwork.validate_side_bounds(side_metadata, parts, update=True)
    assert side_entry['leftBounds']['x'] == 0.8 and side_entry['rightBounds']['x'] == 0
    artwork.validate_side_bounds(side_metadata, parts)
    side_entry['hero'] = 'crossing'
    artwork.validate_side_bounds(side_metadata, parts, update=True)
    assert side_entry == {'hero': 'crossing'}
    entry = {'hero': 'asymmetric'}
    metadata = {'models': {'model': {'colors': {'0': entry}}}}
    artwork.validate_bounds(metadata, measured, update=True)
    artwork.validate_bounds(metadata, measured)
    entry['heroBounds'] = dict(entry['heroBounds'], y=0.5)
    try:
        artwork.validate_bounds(metadata, measured)
    except ValueError:
        pass
    else:
        raise AssertionError('Incorrect display bounds were accepted')
print('Importer validates image integrity, exact alpha bounds and physical-side crop order; overlapping silhouettes are not split')

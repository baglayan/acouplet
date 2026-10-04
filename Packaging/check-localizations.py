from pathlib import Path
from collections import Counter
import json, re, subprocess, sys


def placeholders(value):
    return Counter(re.findall(r'%(?:\d+\$)?[-+#0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hlLzjt])?[@diuoxXfFeEgGaAcCsSp%]', value))


def check_catalog(root):
    catalog = json.loads((root / 'Resources/Localizable.xcstrings').read_text())
    assert catalog['sourceLanguage'] == 'en'
    for key, entry in catalog['strings'].items():
        english = entry['localizations']['en']['stringUnit']['value']
        turkish = entry['localizations']['tr']['stringUnit']['value']
        assert turkish, 'Empty Turkish translation: ' + key
        assert placeholders(english) == placeholders(turkish), 'Changed placeholders: ' + key
        assert entry['localizations']['tr']['stringUnit']['state'] == 'translated', key
    for path in (root / 'Sources').glob('*.swift'):
        source = path.read_text()
        for literal in re.findall(r'(?:String\(localized:|(?:Text|Button|Label|Toggle|Picker|LabeledContent|Section|TextField|GroupBox|\.help|\.accessibilityLabel|\.alert)\()\s*("(?:\\[nrt"\\]|[^"\\])*")', source):
            key = json.loads(literal)
            assert key in catalog['strings'], str(path) + ': missing key ' + key
    return catalog


def check_bundle(app, catalog):
    resources = app / 'Contents/Resources'
    for language in ['en', 'tr']:
        path = resources / (language + '.lproj') / 'Localizable.strings'
        actual = json.loads(subprocess.check_output(['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(path)]))
        for key, entry in catalog['strings'].items():
            expected = entry['localizations'][language]['stringUnit']['value']
            assert actual.get(key) == expected, language + ': missing or incorrect bundled translation: ' + key


def check_extraction(directory, catalog):
    paths = list(directory.glob('*.stringsdata'))
    assert paths, 'No native string extraction files in ' + str(directory)
    keys = set()
    for path in paths:
        data = json.loads(path.read_text())
        for entry in data['tables'].get('Localizable', []):
            key = entry['key']
            keys.add(key)
            assert key in catalog['strings'], str(path) + ': missing native extracted key ' + key
    assert keys, 'Native extraction contained no localized strings'
    print('Native compiler extraction coverage: passed (' + str(len(keys)) + ' keys)')


if __name__ == '__main__':
    catalog = check_catalog(Path(__file__).resolve().parents[1])
    if len(sys.argv) > 1:
        check_bundle(Path(sys.argv[1]), catalog)
    if len(sys.argv) > 2:
        check_extraction(Path(sys.argv[2]), catalog)
    print('English fallback, Turkish coverage and format placeholders: passed (' + str(len(catalog['strings'])) + ' keys)')

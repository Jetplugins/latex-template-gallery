"""Validate gallery inventory without requiring a TeX installation."""
from pathlib import Path, PurePosixPath
root = Path(__file__).resolve().parent / 'gallery'
ids = (root / 'index.txt').read_text().splitlines()
assert ids and len(ids) == len(set(ids))
for id in ids:
    assert id and '/' not in id and id not in ('.', '..')
    folder = root / id
    fields = dict(line.split('=', 1) for line in (folder / 'template.properties').read_text().splitlines() if '=' in line and not line.startswith('#'))
    files = (folder / 'files.txt').read_text().splitlines()
    assert fields['entry'] in files and len(files) == len(set(files))
    for name in files + fields['previews'].split(','):
        assert not PurePosixPath(name).is_absolute() and '..' not in name.split('/') and '\\' not in name
    for name in files:
        assert (folder / 'files' / name).is_file(), name
    for name in fields['previews'].split(','):
        assert (folder / name).is_file(), name
print(f'Validated {len(ids)} templates')

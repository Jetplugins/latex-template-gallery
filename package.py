"""Build deterministic versioned gallery assets. Usage: python3 package.py 1.0.0"""
import hashlib
import json
from pathlib import Path
import sys
import zipfile

root = Path(__file__).resolve().parent
version = sys.argv[1]
output = root / 'dist'
output.mkdir(exist_ok=True)
with zipfile.ZipFile(output / 'gallery.zip', 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for path in sorted((root / 'gallery').rglob('*')):
        if path.is_file():
            entry = zipfile.ZipInfo(path.relative_to(root / 'gallery').as_posix(), (1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, path.read_bytes())
content = (output / 'gallery.zip').read_bytes()
(output / 'manifest.json').write_text(json.dumps(dict(version=version, formatVersion=1, size=len(content), sha256=hashlib.sha256(content).hexdigest()), indent=2) + '\n')
print((output / 'manifest.json').read_text())

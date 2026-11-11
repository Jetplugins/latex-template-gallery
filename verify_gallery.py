#!/usr/bin/env python3
"""Compile bundled gallery starters and optionally regenerate PNG previews.

Requires a TeX Live installation (pdflatex, lualatex, bibtex) and pdftoppm.
All compilation output is isolated in a temporary directory.
"""
import argparse
import hashlib
import re
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent / 'gallery'
PERMISSIVE_LICENSES = {'MIT', 'Apache-2.0', 'BSD-2-Clause', 'BSD-3-Clause', 'ISC', '0BSD', 'CC0-1.0', 'Unlicense'}

def audit(template, metadata):
    if metadata['license'] not in PERMISSIVE_LICENSES:
        raise RuntimeError(f'{template.name}: template license is not permitted')
    if metadata['revision'].startswith('sha256:'):
        actual_hash = hashlib.sha256((template / 'files' / metadata['entry']).read_bytes()).hexdigest()
        if metadata['revision'] != 'sha256:' + actual_hash:
            raise RuntimeError(f'{template.name}: original starter content hash is stale')
    manifest = set(template.joinpath('files.txt').read_text().splitlines())
    actual = {str(p.relative_to(template / 'files')) for p in template.joinpath('files').rglob('*') if p.is_file()}
    if manifest != actual or not {'main.tex', 'UPSTREAM-LICENSE.txt', 'STARTER-LICENSE.txt', 'TEMPLATE-README.txt'} <= manifest:
        raise RuntimeError(f'{template.name}: incomplete file/license manifest')
    for name in manifest:
        path = Path(name)
        if path.is_absolute() or '..' in path.parts or '\\' in name:
            raise RuntimeError(f'{template.name}: unsafe asset path')
        asset = template / 'files' / path
        if asset.suffix in {'.tex', '.cls', '.sty', '.lua', '.txt'}:
            if re.search(r'GNU (?:LESSER |AFFERO )?GENERAL PUBLIC LICENSE|LaTeX Project Public License|CC-BY-SA', asset.read_text(), re.I):
                raise RuntimeError(f'{template.name}: excluded license declaration in {name}')
    if any(Path(name).suffix in {'.otf', '.ttf'} for name in manifest) and not any(name.endswith('-OFL.txt') for name in manifest):
        raise RuntimeError(f'{template.name}: bundled fonts need their OFL notices')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--previews', action='store_true')
    parser.add_argument('--pdf-directory', type=Path, help='Keep compiled PDFs for visual inspection')
    parser.add_argument('--template', action='append', help='Only verify these template IDs')
    parser.add_argument('--audit-only', action='store_true', help='Check licenses and manifests without TeX')
    args = parser.parse_args()
    ids = ROOT.joinpath('index.txt').read_text().splitlines()
    if len(ids) != len(set(ids)) or set(ids) != {p.name for p in ROOT.iterdir() if p.is_dir()}:
        raise RuntimeError('Catalog must enumerate every bundled template directory exactly once')
    if args.template and not set(args.template) <= set(ids):
        parser.error('Unknown template ID')
    for template_id in ids:
        if args.template and template_id not in args.template:
            continue
        template = ROOT / template_id
        metadata = dict(line.split('=', 1) for line in template.joinpath('template.properties').read_text().splitlines() if '=' in line)
        audit(template, metadata)
        if args.audit_only:
            print(f'{template_id}: license and assets verified')
            continue
        with tempfile.TemporaryDirectory(prefix='latex-gallery-') as temp:
            work = Path(temp)
            shutil.copytree(template / 'files', work, dirs_exist_ok=True)
            engine = metadata['engine']
            commands = [[engine, '-interaction=nonstopmode', '-halt-on-error', '-no-shell-escape', 'main.tex']]
            if (work / 'references.bib').exists():
                commands += [['bibtex', 'main']]
            commands += [[engine, '-interaction=nonstopmode', '-halt-on-error', '-no-shell-escape', 'main.tex']] * 2
            for command in commands:
                result = subprocess.run(command, cwd=work, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
                if result.returncode:
                    log = Path(tempfile.gettempdir()) / f'gallery-{template_id}.log'
                    log.write_bytes(result.stdout)
                    raise RuntimeError(f'{template_id}: {command[0]} failed; see {log}')
            log = (work / 'main.log').read_text(errors='replace')
            if 'There were undefined references' in log or 'There were undefined citations' in log:
                raise RuntimeError(f'{template_id}: unresolved references')
            if args.pdf_directory:
                args.pdf_directory.mkdir(parents=True, exist_ok=True)
                shutil.copy(work / 'main.pdf', args.pdf_directory / (template_id + '.pdf'))
            if args.previews:
                pages = [int(page) for page in metadata.get('previewPages', '1,5' if template_id == 'tufte-book' else '1').split(',')]
                names = []
                for index, page in enumerate(pages):
                    name = 'preview' if index == 0 else 'preview-detail'
                    subprocess.run(['pdftoppm', '-f', str(page), '-l', str(page), '-singlefile', '-scale-to', '1000', '-png', str(work / 'main.pdf'), str(template / name)], check=True, stdout=subprocess.DEVNULL)
                    names.append(name + '.png')
                text = (template / 'template.properties').read_text()
                text = '\n'.join('previews=' + ','.join(names) if line.startswith('previews=') else line for line in text.splitlines()) + '\n'
                (template / 'template.properties').write_text(text)
            print(f'{template_id}: compiled successfully', flush=True)

if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Create a compressed drag-to-Applications image from an explicit production app."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
from dmg_common import checksum, validate_app

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path, help='signed production Dotist.app (never modified)')
parser.add_argument('--output', required=True, type=Path, help='existing output directory; image and checksum must not exist')
args = parser.parse_args()
validate_app(args.app)
output = args.output.resolve(strict=True)
if not output.is_dir():
    raise SystemExit('Output must be an existing directory')
image = output / 'Dotist-arm64.dmg'
sidecar = output / 'Dotist-arm64.dmg.sha256'
if image.exists() or image.is_symlink() or sidecar.exists() or sidecar.is_symlink():
    raise SystemExit('Refusing to overwrite existing DMG or checksum')
# The temporary directory is owned by this process and resides on the output filesystem.
with tempfile.TemporaryDirectory(prefix='.dotist-dmg-', dir=output) as temp:
    temp = Path(temp)
    stage = temp / 'stage'
    stage.mkdir()
    subprocess.run(['ditto', str(args.app), str(stage / 'Dotist.app')], check=True)
    validate_app(stage / 'Dotist.app')
    (stage / 'Applications').symlink_to('/Applications')
    built = temp / 'image.dmg'
    subprocess.run(['hdiutil', 'create', '-ov', '-format', 'UDZO', '-volname', 'Dotist', '-srcfolder', str(stage), str(built)], check=True, stdin=subprocess.DEVNULL)
    digest = checksum(built)
    checksum_file = temp / 'checksum'
    checksum_file.write_text(f'{digest}  {image.name}\n', encoding='ascii')
    # Hard links atomically refuse existing paths, including dangling symlinks.
    os.link(built, image)
    try:
        os.link(checksum_file, sidecar)
    except BaseException:
        image.unlink()
        raise
print(f'Created {image} and {sidecar}')

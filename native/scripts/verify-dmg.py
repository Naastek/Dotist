#!/usr/bin/env python3
"""Verify checksum, image format, read-only mount and app; never launch the app."""
import argparse
from pathlib import Path
import plistlib
import os
import re
import subprocess
import tempfile
from dmg_common import checksum, run, validate_layout

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('image', type=Path, help='Dotist-arm64.dmg; checksum is read from IMAGE.sha256')
parser.add_argument('--version', required=True, help='expected X.Y.Z release version')
args = parser.parse_args()
if args.image.name != 'Dotist-arm64.dmg' or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', args.version):
    raise SystemExit('Expected Dotist-arm64.dmg and a numeric X.Y.Z version')
expected = Path(str(args.image) + '.sha256').read_text(encoding='ascii')
if expected != f'{checksum(args.image)}  {args.image.name}\n':
    raise SystemExit('DMG SHA-256 checksum mismatch')
run('hdiutil', 'verify', str(args.image))
image_info = plistlib.loads(run('hdiutil', 'imageinfo', '-plist', str(args.image)).stdout)
if image_info.get('Format') != 'UDZO':
    raise SystemExit('Expected a compressed read-only UDZO image')
temp = Path(tempfile.mkdtemp(prefix='dotist-dmg-mount-'))
try:
    mount = temp / 'volume'
    mount.mkdir()
    attached = False
    attach_started = False
    try:
        # Always attempt detach after attach begins, including attach failures.
        attach_started = True
        run('hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', str(mount), str(args.image))
        attached = True
        disk = plistlib.loads(run('diskutil', 'info', '-plist', str(mount)).stdout)
        if disk.get('WritableVolume') is not False:
            raise ValueError('Disk image volume is not read-only')
        validate_layout(mount, args.version)
    finally:
        if attach_started:
            result = subprocess.run(['hdiutil', 'detach', str(mount)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode and (attached or mount.is_mount()):
                raise RuntimeError('Failed to detach disk image')
finally:
    # Never recursively remove a mount point if detach fails.
    if not mount.is_mount():
        os.rmdir(mount)
        os.rmdir(temp)
print('DMG checksum, format, read-only layout, signature, architecture and version verified')

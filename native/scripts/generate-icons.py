#!/usr/bin/env python3
"""Regenerate the approved geometric SVG assets with rsvg-convert; package PNG ICNS representations deterministically."""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import struct
import zlib
import tempfile

ROOT = Path(__file__).resolve().parents[2]
LOGO = Path('design-system/logo')


def rgba_png(path):
    """Decode rsvg's noninterlaced RGBA8 PNG using only the standard library."""
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    offset, compressed = 8, bytearray()
    while offset < len(data):
        length = struct.unpack('>I', data[offset:offset + 4])[0]
        kind, payload = data[offset + 4:offset + 8], data[offset + 8:offset + 8 + length]
        if kind == b'IHDR':
            width, height, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', payload)
            assert (depth, color, compression, filtering, interlace) == (8, 6, 0, 0, 0)
        elif kind == b'IDAT':
            compressed.extend(payload)
        offset += length + 12
    raw, stride = zlib.decompress(compressed), width * 4
    previous, pixels = bytearray(stride), bytearray()
    for y in range(height):
        start = y * (stride + 1)
        method, row = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        for x in range(stride):
            left, above, corner = (row[x - 4] if x >= 4 else 0), previous[x], (previous[x - 4] if x >= 4 else 0)
            if method == 0: predictor = 0
            elif method == 1: predictor = left
            elif method == 2: predictor = above
            elif method == 3: predictor = (left + above) // 2
            elif method == 4:
                value = left + above - corner
                distances = [abs(value - p) for p in (left, above, corner)]
                predictor = (left, above, corner)[distances.index(min(distances))]
            else: raise ValueError(f'Unknown PNG filter: {method}')
            row[x] = (row[x] + predictor) & 255
        pixels.extend(row)
        previous = row
    return pixels


def small_icon_chunks(path, rgb_type, alpha_type):
    # macOS decodes 16/32 pt 1x through classic planar RGB + an 8-bit alpha
    # mask. PNG in icp4/icp5 decodes incorrectly on some AppKit/iconutil paths.
    rgba = rgba_png(path)
    rgb = bytearray()
    for channel in range(3):
        values = rgba[channel::4]
        for offset in range(0, len(values), 128):
            literal = values[offset:offset + 128]
            rgb.append(len(literal) - 1)
            rgb.extend(literal)
    return [(rgb_type, bytes(rgb)), (alpha_type, bytes(rgba[3::4]))]


def generate(destination):
    def raster(source, output, size):
        target = destination / output
        target.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['rsvg-convert', '-w', str(size), '-h', str(size),
                        str(ROOT / LOGO / source), '-o', str(target)], check=True)

    raster('dotist-mark.svg', LOGO / 'dotist-mark-512.png', 512)
    for theme in ('light', 'dark'):
        raster(f'app-icon-{theme}.svg', LOGO / f'app-icon-{theme}-1024.png', 1024)
    for suffix, size in (('', 22), ('@2x', 44)):
        raster('menubar-template-22.svg', LOGO / f'menubar-template{suffix}.png', size)
    for size in (16, 22):
        for scale in (1, 2):
            suffix = '@2x' if scale == 2 else ''
            raster(f'menubar-template-{size}.svg', LOGO / f'menubar-template-{size}{suffix}.png', size * scale)
    iconset = destination / 'Dotist.iconset'
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            suffix = '@2x' if scale == 2 else ''
            raster('app-icon-light.svg', Path('Dotist.iconset') / f'icon_{size}x{size}{suffix}.png', size * scale)
    native_icon = destination / 'native/Assets/icon.icns'
    native_icon.parent.mkdir(parents=True, exist_ok=True)
    # Large and Retina representations retain the exact rsvg PNG payload;
    # classic small 1x representations use lossless planar RGB + alpha masks.
    elements = []
    types = ('is32', 'ic11', 'il32', 'ic12', 'ic07', 'ic13', 'ic08', 'ic14', 'ic09', 'ic10')
    files = [iconset / f'icon_{size}x{size}{"@2x" if scale == 2 else ""}.png'
             for size in (16, 32, 128, 256, 512) for scale in (1, 2)]
    for code, file in zip(types, files):
        if code in ('is32', 'il32'):
            elements.extend(small_icon_chunks(file, code, 's8mk' if code == 'is32' else 'l8mk'))
        else:
            elements.append((code, file.read_bytes()))
    chunks = [code.encode('ascii') + struct.pack('>I', len(data) + 8) + data for code, data in elements]
    payload = b''.join(chunks)
    native_icon.write_bytes(b'icns' + struct.pack('>I', len(payload) + 8) + payload)
    # Mirror referenced by the native packager.
    for source, target in (
        (LOGO / 'menubar-template@2x.png', Path('native/Assets/menubar.png')),
    ):
        (destination / target).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(destination / source, destination / target)
    return sorted(p.relative_to(destination) for p in destination.rglob('*')
                  if p.is_file() and iconset not in p.parents)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='compare regenerated bytes without changing assets')
    args = parser.parse_args()
    cache = ROOT / '.cache/logo-integration'
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='icons-', dir=cache) as temporary:
        directory = Path(temporary)
        for relative in generate(directory):
            data = (directory / relative).read_bytes()
            if args.check:
                if not (ROOT / relative).is_file() or (ROOT / relative).read_bytes() != data:
                    raise SystemExit(f'Outdated asset: {relative}')
            else:
                (ROOT / relative).write_bytes(data)
            print(hashlib.sha256(data).hexdigest(), relative)


if __name__ == '__main__':
    main()

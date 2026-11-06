"""Shared validation for the native release disk image."""
import hashlib
import importlib
from pathlib import Path
import plistlib
import re
import subprocess


def run(*args):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def validate_app(app, version=None):
    app = Path(app)
    if app.name != 'Dotist.app' or app.is_symlink() or not app.is_dir():
        raise ValueError('Expected a Dotist.app directory')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    actual = info.get('CFBundleShortVersionString')
    config = importlib.import_module('update-config').update_config()
    if (info.get('CFBundleIdentifier') != 'com.dotist.app' or
            info.get('CFBundleExecutable') != 'dotist' or
            not isinstance(actual, str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', actual) or
            info.get('CFBundleVersion') != actual or (version is not None and actual != version) or
            any(info.get(k) != v for k, v in config.items())):
        raise ValueError('Invalid production identity, version, or update configuration')
    run('codesign', '--verify', '--deep', '--strict', str(app))
    architectures = run('lipo', '-archs', str(app / 'Contents/MacOS/dotist')).stdout.decode().split()
    if architectures != ['arm64']:
        raise ValueError('Expected an arm64-only application executable')
    return actual


def checksum(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def validate_layout(mount, version):
    mount = Path(mount)
    if {p.name for p in mount.iterdir()} != {'Dotist.app', 'Applications'}:
        raise ValueError('Unexpected disk image contents')
    link = mount / 'Applications'
    if not link.is_symlink() or link.readlink() != Path('/Applications'):
        raise ValueError('Applications must be a symlink to /Applications')
    validate_app(mount / 'Dotist.app', version)

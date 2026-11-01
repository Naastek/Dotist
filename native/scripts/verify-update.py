#!/usr/bin/env python3
"""Verify the native appcast, archive signature, bundle and packaging before publication."""
import importlib
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tarfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[2]
assets = Path(sys.argv[1]).resolve()
archive = assets / 'Dotist_darwin_aarch64.app.tar.gz'
namespace = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
item = ET.parse(assets / 'appcast.xml').find('channel/item')
if item is None:
    raise SystemExit('Missing native update item')
enclosure = item.find('enclosure')
if enclosure is None:
    raise SystemExit('Missing native update archive')
version = item.findtext('sparkle:version', namespaces=namespace)
if not version or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version) or item.findtext('sparkle:shortVersionString', namespaces=namespace) != version:
    raise SystemExit('Invalid native version')
expected_url = f'https://github.com/Naastek/Dotist/releases/download/v{version}/{archive.name}'
if enclosure.attrib['url'] != expected_url or int(enclosure.attrib['length']) != archive.stat().st_size:
    raise SystemExit('Update URL or archive length mismatch')
config = importlib.import_module('update-config').update_config()
subprocess.run(['swift', str(root / 'native/scripts/verify-ed25519.swift'), config['SUPublicEDKey'], enclosure.attrib['{' + namespace['sparkle'] + '}edSignature'], str(archive)], check=True)
with tarfile.open(archive) as source:
    info = plistlib.loads(source.extractfile('Dotist.app/Contents/Info.plist').read())
    paths = {entry.name for entry in source.getmembers()}
if info.get('CFBundleIdentifier') != 'com.dotist.app' or info['CFBundleVersion'] != version or info['CFBundleShortVersionString'] != version:
    raise SystemExit('Unexpected native application identity or version')
if any(info.get(k) != v for k, v in config.items()):
    raise SystemExit('The archive changed the native update or platform configuration')
if item.findtext('sparkle:minimumSystemVersion', namespaces=namespace) != config['LSMinimumSystemVersion']:
    raise SystemExit('Minimum macOS version mismatch')
if 'Dotist.app/Contents/MacOS/dotist' not in paths or not any('Sparkle.framework/' in path for path in paths):
    raise SystemExit('Incomplete native application')
if any('/dotist-mcp' in path for path in paths) or (assets / 'latest.json').exists():
    raise SystemExit('Unexpected retired update or sidecar artifacts')
print('Native signature, bundle, version, minimum macOS, URL and archive length verified')

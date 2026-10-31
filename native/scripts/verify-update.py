#!/usr/bin/env python3
"""Verify downloaded release artifacts before making a draft public."""
import importlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tarfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[2]
assets = Path(sys.argv[1]).resolve()
manifest = json.loads((assets / 'latest.json').read_text())
platform = manifest['platforms']['darwin-aarch64']
archive = assets / 'Dotist_darwin_aarch64.app.tar.gz'
ns = {'sparkle':'http://www.andymatuschak.org/xml-namespaces/sparkle'}
item = ET.parse(assets / 'appcast.xml').find('channel/item')
enclosure = item.find('enclosure')
version = manifest['version']
config = importlib.import_module('update-config').update_config()
if item.findtext('sparkle:version', namespaces=ns) != version or item.findtext('sparkle:shortVersionString', namespaces=ns) != version:
    raise SystemExit('Native and legacy update versions differ')
expected_url = f'https://github.com/Naastek/Dotist/releases/download/v{version}/{archive.name}'
if platform['url'] != expected_url or enclosure.attrib['url'] != expected_url or int(enclosure.attrib['length']) != archive.stat().st_size:
    raise SystemExit('Update asset URL or length mismatch')
if (assets / (archive.name + '.sig')).read_text().strip() != platform['signature']:
    raise SystemExit('Legacy signature and manifest differ')
tool = root / '.cache/native-migration/release-tools-target/release/dotist-release-tools'
subprocess.run([str(tool), 'verify', str(archive), str(assets / (archive.name + '.sig'))], check=True, cwd=root)
subprocess.run(['swift', str(root / 'native/scripts/verify-ed25519.swift'), config['SUPublicEDKey'], enclosure.attrib['{' + ns['sparkle'] + '}edSignature'], str(archive)], check=True)
with tarfile.open(archive) as source:
    info = plistlib.loads(source.extractfile('Dotist.app/Contents/Info.plist').read())
    paths = {item.name for item in source.getmembers()}
if info.get('CFBundleIdentifier') != 'com.dotist.app' or not info.get('DotistNative') or info['CFBundleVersion'] != version or info['CFBundleShortVersionString'] != version:
    raise SystemExit('The update does not contain the expected native application')
if any(info.get(k) != value for k, value in config.items()):
    raise SystemExit('The update changed the native update trust configuration')
if 'Dotist.app/Contents/MacOS/dotist-mcp' not in paths or not any('Sparkle.framework/' in p for p in paths):
    raise SystemExit('The native bundle is incomplete')
print('Both signatures, native bundle, versions, URLs and archive length verified')

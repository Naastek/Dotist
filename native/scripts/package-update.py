#!/usr/bin/env python3
"""Package one native Sparkle update; signing material is passed to sign_update on stdin."""
import argparse
import datetime
import importlib
import os
from pathlib import Path
import plistlib
import subprocess
import xml.etree.ElementTree as ET

update_config = importlib.import_module('update-config').update_config
parser = argparse.ArgumentParser()
parser.add_argument('app', type=Path)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--key-file', type=Path)
parser.add_argument('--download-prefix')
args = parser.parse_args()
project = Path(__file__).resolve().parents[2]
info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
config = update_config()
if info.get('CFBundleIdentifier') != 'com.dotist.app' or any(info.get(k) != v for k, v in config.items()):
    raise SystemExit('Expected a native production bundle with the configured minimum macOS and Sparkle trust key')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(args.app)], check=True)
version = info['CFBundleShortVersionString']
if info['CFBundleVersion'] != version:
    raise SystemExit('Display and build versions must match')
key = args.key_file.read_text().strip() if args.key_file else os.environ.get('SPARKLE_SIGNING_PRIVATE_KEY', '').strip()
if not key:
    raise SystemExit('SPARKLE_SIGNING_PRIVATE_KEY is required; use the Sparkle key matching native/app.json')
args.output.mkdir(parents=True, exist_ok=False)
archive = args.output / 'Dotist_darwin_aarch64.app.tar.gz'
subprocess.run(['tar', '-czf', str(archive.resolve()), '-C', str(args.app.parent), args.app.name], check=True)
signer = project / '.cache/native-migration/deps/Sparkle-2.9.6/bin/sign_update'
result = subprocess.run([str(signer), '--ed-key-file', '-', '-p', str(archive.resolve())], input=key, capture_output=True, text=True)
if result.returncode:
    raise SystemExit('Sparkle archive signing failed')
signature = result.stdout.strip()
subprocess.run(['swift', str(project / 'native/scripts/verify-ed25519.swift'), config['SUPublicEDKey'], signature, str(archive)], check=True)
prefix = args.download_prefix or f'https://github.com/Naastek/Dotist/releases/download/v{version}'
url = prefix.rstrip('/') + '/' + archive.name
notes = (project / 'docs/release-notes.md').read_text().strip().replace('**', '')
namespace = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', namespace)
rss = ET.Element('rss', {'version': '2.0'})
channel = ET.SubElement(rss, 'channel')
ET.SubElement(channel, 'title').text = 'Dotist native updates'
item = ET.SubElement(channel, 'item')
ET.SubElement(item, 'title').text = f'Dotist {version}'
ET.SubElement(item, 'pubDate').text = datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S %z')
for name, value in [('version', version), ('shortVersionString', version), ('minimumSystemVersion', info['LSMinimumSystemVersion'])]:
    ET.SubElement(item, '{' + namespace + '}' + name).text = value
ET.SubElement(item, 'description').text = notes
ET.SubElement(item, 'enclosure', {'url': url, 'length': str(archive.stat().st_size), 'type': 'application/octet-stream', '{' + namespace + '}edSignature': signature})
ET.indent(rss)
ET.ElementTree(rss).write(args.output / 'appcast.xml', encoding='utf-8', xml_declaration=True)
print(f'Signed native Sparkle update: {args.output}')

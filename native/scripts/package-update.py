#!/usr/bin/env python3
"""Create both Sparkle and Tauri update metadata for the SAME native archive.

Reads existing signing credentials only from the environment, or --key-dir.
Never stores the decrypted key. Does not upload, publish, or install anything.
"""
import argparse
import datetime
import importlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import xml.etree.ElementTree as ET

update_config = importlib.import_module('update-config').update_config
parser = argparse.ArgumentParser()
parser.add_argument('app', type=Path)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--key-dir', type=Path)
parser.add_argument('--download-prefix')
args = parser.parse_args()
info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
config = update_config()
if info.get('CFBundleIdentifier') != 'com.dotist.app' or not info.get('DotistNative') or any(info.get(k) != v for k, v in config.items()):
    raise SystemExit('Only a native production bundle with the trusted update configuration can be published')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(args.app)], check=True)
version = info['CFBundleShortVersionString']
if info['CFBundleVersion'] != version:
    raise SystemExit('A release must use the same numeric display and build versions')
args.output.mkdir(parents=True, exist_ok=False)
archive = args.output / 'Dotist_darwin_aarch64.app.tar.gz'
subprocess.run(['tar', '-czf', str(archive.resolve()), '-C', str(args.app.parent), args.app.name], check=True)
env = dict(os.environ)
if args.key_dir:
    env['TAURI_SIGNING_PRIVATE_KEY'] = (args.key_dir / 'dotist.key').read_text().strip()
    env['TAURI_SIGNING_PRIVATE_KEY_PASSWORD'] = (args.key_dir / 'password').read_text().strip()
project = Path(__file__).resolve().parents[2]
signer = project / '.cache/native-migration/deps/Sparkle-2.9.6/bin/sign_update'
tool = project / '.cache/native-migration/release-tools-target/release/dotist-release-tools'
result = subprocess.run([str(tool), str(archive.resolve()), str(signer)], env=env, capture_output=True, text=True)
if result.returncode:
    raise SystemExit('Update signing failed: ' + result.stderr)
signatures = json.loads(result.stdout)
if signatures['sparklePublicKey'] != config['SUPublicEDKey']:
    raise SystemExit('The archive signer does not match the embedded update key')
(archive.with_suffix(archive.suffix + '.sig')).write_text(signatures['tauriSignature'])
prefix = args.download_prefix or f'https://github.com/Naastek/Dotist/releases/download/v{version}'
url = prefix.rstrip('/') + '/' + archive.name
now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
notes = (project / 'docs/release-notes.md').read_text().strip().replace('**', '')
(args.output / 'latest.json').write_text(json.dumps({'version':version, 'notes':notes, 'pub_date':now, 'platforms':{'darwin-aarch64':{'signature':signatures['tauriSignature'], 'url':url}}}, ensure_ascii=False, indent=2))
ns = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', ns)
rss = ET.Element('rss', {'version':'2.0'});channel = ET.SubElement(rss, 'channel')
ET.SubElement(channel, 'title').text = 'Dotist native updates'
item = ET.SubElement(channel, 'item');ET.SubElement(item, 'title').text = f'Dotist {version}'
for key, value in [('version', version), ('shortVersionString', version), ('minimumSystemVersion', info['LSMinimumSystemVersion'])]:
    ET.SubElement(item, '{' + ns + '}' + key).text = value
ET.SubElement(item, 'description').text = notes
ET.SubElement(item, 'enclosure', {'url':url, 'length':str(archive.stat().st_size), 'type':'application/octet-stream', '{'+ns+'}edSignature':signatures['sparkleSignature']})
ET.indent(rss)
ET.ElementTree(rss).write(args.output / 'appcast.xml', encoding='utf-8', xml_declaration=True)
(args.output / 'signatures.json').write_text(json.dumps(signatures, indent=2))
print(f'Signed native update assets: {args.output}')

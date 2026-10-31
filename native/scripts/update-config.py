#!/usr/bin/env python3
"""Public native-update configuration derived from the existing trust root."""
import base64
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def update_config():
    config = json.loads((ROOT / 'src-tauri/tauri.conf.json').read_text())['plugins']['updater']
    boxed = base64.b64decode(config['pubkey'], validate=True).decode()
    public = base64.b64decode(boxed.splitlines()[1], validate=True)
    if len(public) != 42 or public[:2] != b'Ed':
        raise ValueError('Expected the existing minisign Ed25519 public key')
    return {
        'SUFeedURL': 'https://github.com/Naastek/Dotist/releases/latest/download/appcast.xml',
        'SUPublicEDKey': base64.b64encode(public[10:]).decode(),
        'SUVerifyUpdateBeforeExtraction': True,
        'SUScheduledCheckInterval': 86400,
        'SUEnableAutomaticChecks': True,
        'SUAllowsAutomaticUpdates': True,
        'DotistNative': True,
    }


if __name__ == '__main__':
    print(json.dumps(update_config()))

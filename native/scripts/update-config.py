#!/usr/bin/env python3
"""Native Sparkle configuration. The public trust key lives in native/app.json."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def update_config():
    config = json.loads((ROOT / 'native/app.json').read_text())
    return {
        'LSMinimumSystemVersion': config['minimumMacOS'],
        'SUFeedURL': config['updateFeed'],
        'SUPublicEDKey': config['updatePublicKey'],
        'SUVerifyUpdateBeforeExtraction': True,
        'SUScheduledCheckInterval': 86400,
        'SUEnableAutomaticChecks': True,
        'SUAllowsAutomaticUpdates': True,
        'DotistNative': True,
    }


if __name__ == '__main__':
    print(json.dumps(update_config()))

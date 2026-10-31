"""Build isolated QA updates with the same signing trust root as production."""
import base64
import importlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time

project = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(project / 'native/scripts'))
config = importlib.import_module('update-config').update_config()
source, root = map(lambda p: Path(p).resolve(), sys.argv[1:3])
if plistlib.loads((source / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier'] != 'dev.codex.dotist-native-qa':
    raise SystemExit('Update tests require an isolated QA application')
server = root / 'update-server'
port = (server / 'port.txt').read_text().strip()
env = dict(os.environ)
if len(sys.argv) > 3:
    credentials = Path(sys.argv[3])
    env.update({
        'TAURI_SIGNING_PRIVATE_KEY': (credentials / 'dotist.key').read_text().strip(),
        'TAURI_SIGNING_PRIVATE_KEY_PASSWORD': (credentials / 'password').read_text().strip(),
    })
tool = project / '.cache/native-migration/release-tools-target/release/dotist-release-tools'
signer = project / '.cache/native-migration/deps/Sparkle-2.9.6/bin/sign_update'
products = root / 'DerivedData/Build/Products'


def absolute_paths(value):
    if isinstance(value, str):
        return value.replace('__TESTROOT__', str(products))
    if isinstance(value, list):
        return [absolute_paths(v) for v in value]
    if isinstance(value, dict):
        return {k: absolute_paths(v) for k, v in value.items()}
    return value


for number, name in enumerate(['check', 'manual', 'tampered', 'automatic', 'cancel', 'skip'], int(time.time())):
    qa = root / f'update-{name}'
    qa.mkdir()
    data = qa / 'data'
    data.mkdir()
    app = qa / 'Dotist-Native-QA.app'
    shutil.copytree(source, app, symlinks=True)
    version = f'0.1.{number}'
    route = server / 'www' / name
    route.mkdir()
    automatic = name in ['automatic', 'cancel', 'skip']
    settings = {
        'theme':'light', 'language':'zh-CN', 'auto_check_updates':automatic,
        'auto_install_updates':automatic, 'show_menubar':False, 'auto_collapse':False,
        'idle_fade':False, 'always_on_top':True, 'toggle_shortcut':'',
        'quick_add_shortcut':'', 'settings_shortcut':'', 'views_shortcut':'',
    }
    (data / 'settings.json').write_text(json.dumps(settings))
    (data / 'update-target.json').write_text(json.dumps({'version':version, 'currentBuild':'0.1.2', 'targetBuild':version}))
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    info.update(config)
    info.update({
        'CFBundleVersion':'0.1.2', 'CFBundleShortVersionString':'0.1.2',
        'SUFeedURL':f'http://127.0.0.1:{port}/{name}/appcast.xml',
        'DotistQATestUpdateFeed':True, 'DotistQATestCheckOnLaunch':automatic,
        'NSAppTransportSecurity':{'NSAllowsLocalNetworking':True},
    })
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True, capture_output=True)
    candidate = root / f'candidate-{name}' / 'Dotist-Native-QA.app'
    candidate.parent.mkdir()
    shutil.copytree(app, candidate, symlinks=True)
    info.update({'CFBundleVersion':version, 'CFBundleShortVersionString':version})
    (candidate / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(candidate)], check=True, capture_output=True)
    archive = route / 'update.tar.gz'
    subprocess.run(['tar', '-czf', str(archive), '-C', str(candidate.parent), candidate.name], check=True)
    signatures = json.loads(subprocess.check_output([str(tool), str(archive), str(signer)], env=env, text=True))
    if name == 'tampered':
        signature = bytearray(base64.b64decode(signatures['sparkleSignature']))
        signature[0] ^= 1
        signatures['sparkleSignature'] = base64.b64encode(signature).decode()
    (route / 'appcast.xml').write_text(f'''<?xml version="1.0"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Isolated Dotist QA</title><item><title>{version}</title><sparkle:version>{version}</sparkle:version><sparkle:shortVersionString>{version}</sparkle:shortVersionString><sparkle:minimumSystemVersion>11.0</sparkle:minimumSystemVersion><enclosure url="http://127.0.0.1:{port}/{name}/{archive.name}" length="{archive.stat().st_size}" type="application/octet-stream" sparkle:edSignature="{signatures['sparkleSignature']}"/></item></channel></rss>''')
    run = plistlib.loads(next(products.glob('DotistUI_*.xctestrun')).read_bytes())
    target = run['DotistUITests']
    target['UITargetAppPath'] = str(app)
    target.setdefault('UITargetAppEnvironmentVariables', {})['DOTIST_DATA_DIR'] = str(data)
    target.setdefault('EnvironmentVariables', {})['DOTIST_UI_DATA'] = str(data)
    (qa / 'run.xctestrun').write_bytes(plistlib.dumps(absolute_paths(run)))
    print('Prepared', name, version, flush=True)

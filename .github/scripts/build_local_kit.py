"""Assemble a supplied kit with a supplied decrypted IPA on a macOS runner.
Input and output artifacts are AES-GCM encrypted because this repository is public.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import zipfile
import requests
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

HEADER = b'SPWENC01'

def run(*args):
    subprocess.run(list(map(str, args)), check=True)

def download(asset_id, target, key):
    repo = os.environ['GITHUB_REPOSITORY']
    response = requests.get(f'https://api.github.com/repos/{repo}/releases/assets/{int(asset_id)}',
                            headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
                                     'Accept': 'application/octet-stream',
                                     'X-GitHub-Api-Version': '2022-11-28'}, timeout=180)
    response.raise_for_status()
    blob = response.content
    if blob[:8] != HEADER:
        raise ValueError('Release asset does not contain an encrypted input')
    target.write_bytes(AESGCM(key).decrypt(blob[8:20], blob[20:], HEADER))

def load_commands(data):
    if data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected a thin 64-bit Mach-O')
    ncmds = struct.unpack_from('<I', data, 16)[0]
    offset = 32
    for _ in range(ncmds):
        command, size = struct.unpack_from('<II', data, offset)
        yield command, data[offset:offset+size]
        offset += size

def decrypted(data):
    found = []
    for command, payload in load_commands(data):
        if command in (0x21, 0x2C):
            found.append(struct.unpack_from('<I', payload, 16)[0])
    if any(found):
        raise ValueError('Main Spotify executable is still encrypted')
    return found

def strings_replaced(value, replacements):
    if isinstance(value, str):
        for old, new in replacements.items():
            value = value.replace(old, new)
        return value
    if isinstance(value, dict):
        return {k: strings_replaced(v, replacements) for k, v in value.items()}
    if isinstance(value, list):
        return [strings_replaced(v, replacements) for v in value]
    return value

def main():
    key = base64.b64decode(os.environ['BUILD_KEY'], validate=True)
    if len(key) != 32:
        raise ValueError('Invalid build encryption key')
    work = Path('work-build')
    out = Path('out')
    work.mkdir(exist_ok=True)
    out.mkdir(exist_ok=True)
    ipa, kit_zip = work/'source.ipa', work/'kit.zip'
    download(os.environ['IPA_ASSET'], ipa, key)
    download(os.environ['KIT_ASSET'], kit_zip, key)
    kit = work/'kit'
    with zipfile.ZipFile(kit_zip) as archive:
        archive.extractall(kit)
    manifest = json.loads((kit/'kit.json').read_text())
    for name, checksum in manifest['integrity'].items():
        if hashlib.sha256((kit/name).read_bytes()).hexdigest() != checksum:
            raise ValueError('Kit integrity failure: ' + name)
    with zipfile.ZipFile(ipa) as archive:
        apps = sorted({name.split('/')[1] for name in archive.namelist()
                       if name.startswith('Payload/') and len(name.split('/')) > 2
                       and name.split('/')[1].endswith('.app')})
        if len(apps) != 1:
            raise ValueError('Expected one main application')
        app_prefix = 'Payload/' + apps[0] + '/'
        host = plistlib.loads(archive.read(app_prefix+'Info.plist'))
        encryption = decrypted(archive.read(app_prefix+host['CFBundleExecutable']))
    if host['CFBundleShortVersionString'] not in manifest['spotifyVersions']:
        raise ValueError('Source Spotify version is not supported by this kit')
    replacements = {'HOST_BUNDLE_ID': host['CFBundleIdentifier'],
                    'HOST_SHORT_VERSION': host['CFBundleShortVersionString'],
                    'HOST_VERSION': host['CFBundleVersion']}
    for name in manifest.get('templates', []):
        path = kit/'files'/name
        contents = plistlib.loads(path.read_bytes())
        path.write_bytes(plistlib.dumps(strings_replaced(contents, replacements)))
    overrides = work/'overrides.plist'
    plist_settings = manifest['infoPlist']
    merged = dict(plist_settings.get('set', {}))
    for name, values in plist_settings.get('union', {}).items():
        merged[name] = list(dict.fromkeys(host.get(name, []) + values))
    for name, value in plist_settings.get('default', {}).items():
        merged[name] = host.get(name, value)
    overrides.write_bytes(plistlib.dumps(merged))
    output = out/f'spoti.pw-{manifest["version"]}-spotify-{host["CFBundleShortVersionString"]}-local-patch.ipa'
    inputs = [kit/'files/Frameworks/SpotifyGlassAppGroups.dylib',
              kit/'files/Frameworks/spotifyglass.dylib',
              kit/'files/PlugIns/SpotifyGlassLiveActivity.appex']
    run('cyan', '-i', ipa, '-o', output, '-f', *inputs, '-l', overrides, '-w', '-s', '--overwrite')
    staging = work/'staging'
    with zipfile.ZipFile(output) as archive:
        archive.extractall(staging)
    app = staging/'Payload'/apps[0]
    for name in manifest.get('remove', []):
        path = app/name
        if path.is_dir():
            shutil.rmtree(path)
        elif path.exists():
            path.unlink()
    widget = app/'PlugIns/WidgetExtension.appex/WidgetExtension'
    if widget.exists():
        run('python3', 'scripts/insert-dylib.py', widget, '@rpath/SpotifyGlassAppGroups.dylib')
        entitlements = subprocess.run(['ldid', '-e', str(widget)], check=True, capture_output=True).stdout
        if entitlements:
            ents = work/'widget-entitlements.plist'
            ents.write_bytes(entitlements)
            run('ldid', '-S'+str(ents), widget)
        else:
            run('ldid', '-S', widget)
    metadata = app/'Metadata.appintents'
    metadata.mkdir(exist_ok=True)
    original_actions = metadata/'extract.actionsdata'
    additions = json.loads((kit/'appintents/extract.actionsdata').read_text())
    if original_actions.exists():
        contents = json.loads(original_actions.read_text())
        contents['actions'] = {**contents.get('actions', {}), **additions['actions']}
    else:
        contents = additions
        shutil.copy2(kit/'appintents/version.json', metadata/'version.json')
    original_actions.write_text(json.dumps(contents))
    main_binary = (app/host['CFBundleExecutable']).read_bytes()
    loads = []
    for command, payload in load_commands(main_binary):
        if command in (0xC, 0x18, 0x80000018, 0x1F):
            string_offset = struct.unpack_from('<I', payload, 8)[0]
            loads.append(payload[string_offset:].split(b'\0')[0].decode())
    for name in manifest['load'][0]['dylibs']:
        if name not in loads:
            raise ValueError('Missing main executable dependency: ' + name)
    actual_dylib = (app/'Frameworks/spotifyglass.dylib').read_bytes()
    expected_dylib = (kit/'files/Frameworks/spotifyglass.dylib').read_bytes()
    if actual_dylib[0x31FD0:0x31FD0+244] != expected_dylib[0x31FD0:0x31FD0+244]:
        raise ValueError('Local patch was not preserved during injection')
    extension = plistlib.loads((app/'PlugIns/SpotifyGlassLiveActivity.appex/Info.plist').read_bytes())
    if extension['CFBundleIdentifier'] != host['CFBundleIdentifier']+'.liveactivity':
        raise ValueError('Live Activity bundle identifier was not substituted')
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in sorted(staging.rglob('*')):
            if path.is_file():
                archive.write(path, path.relative_to(staging).as_posix())
    result = output.read_bytes()
    summary = {'spotify_version': host['CFBundleShortVersionString'], 'kit_version': manifest['version'],
               'main_cryptid': encryption, 'main_loads_verified': manifest['load'][0]['dylibs'],
               'live_activity_included': True, 'widget_patched': widget.exists(),
               'app_intents_added': len(additions['actions']), 'patch_preserved': True,
               'ipa_sha256': hashlib.sha256(result).hexdigest(), 'ipa_size': len(result),
               'signing': 'fakesigned; ordinary sideloading requires signing with an installation certificate',
               'runtime_tested_on_ios': False}
    (out/'build-summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    nonce = os.urandom(12)
    (out/(output.name+'.aes')).write_bytes(HEADER+nonce+AESGCM(key).encrypt(nonce, result, HEADER))
    output.unlink()
    print(json.dumps(summary, indent=2))

if __name__ == '__main__':
    main()

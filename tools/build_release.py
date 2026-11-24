#!/usr/bin/env python3
"""Builds ForeverWEATHER.zip from the repository (the same layout the game mounts: art/, lua/, mod_info/, scripts/,
shaders/, ui/), and optionally checks that every place that names the version agrees with a tag.

  python3 tools/build_release.py                         -> release/ForeverWEATHER.zip (a pre-release build)
  python3 tools/build_release.py --out dist/X.zip        -> another path
  python3 tools/build_release.py --check-version 1.6.0   -> fail unless mod_info, the Lua and the UI all say 1.6.0
                                                          (a tag may carry a suffix: v1.6.1-pre checks 1.6.1)
  python3 tools/build_release.py --final                 -> no pre-release notice in the zip (a tested release)

A pre-release build carries PRERELEASE_README.txt at the root of the zip: it says the build is untested and where to
report bugs. The game ignores the file. The GitHub workflow (.github/workflows/release.yml) uses this same script, so a
local build and the published asset are the same zip. Files are added in sorted order with the timestamp of the last
commit (SOURCE_DATE_EPOCH if set), so the same commit builds the same bytes.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
MOD_DIRS = ['art', 'lua', 'mod_info', 'scripts', 'shaders', 'ui']
SKIP = re.compile(r'(^|/)(\.|__pycache__/)|\.(pyc|orig|rej|swp)$|~$')
ISSUES = 'https://github.com/Blaze-Archi/ForeverWEATHER/issues'


def versions():
    """Every place in the mod that names its version."""
    out = {}
    with open(os.path.join(ROOT, 'mod_info', 'FOREVERWEATHER', 'info.json'), encoding='utf-8') as f:
        out['mod_info/FOREVERWEATHER/info.json'] = json.load(f).get('version_string')
    with open(os.path.join(ROOT, 'lua', 'ge', 'extensions', 'rainPuddles.lua'), encoding='utf-8') as f:
        m = re.search(r"^local VERSION = '([^']+)'", f.read(), re.M)
        out['lua/ge/extensions/rainPuddles.lua'] = m.group(1) if m else None
    with open(os.path.join(ROOT, 'ui', 'ui-vue', 'mods', 'RainPuddles', 'shared', 'constants.js'), encoding='utf-8') as f:
        m = re.search(r'VERSION = "([^"]+)"', f.read())
        out['ui/ui-vue/mods/RainPuddles/shared/constants.js'] = m.group(1) if m else None
    return out


def notice(version):
    return (
        'ForeverWEATHER %s - PRE-RELEASE BUILD\n'
        '==========================================\n\n'
        'This build is UNTESTED. It has not been played and checked in BeamNG.drive yet, so expect bugs:\n'
        'visual glitches, shader errors on some graphics cards or APIs, things that behave differently than\n'
        'described.\n\n'
        'Please report every bug you find in the Issues tab of the repository:\n'
        '  %s\n\n'
        'What helps the most:\n'
        '  - this version (%s) and BeamNG.drive\'s version, DX12 or Vulkan, the graphics card\n'
        '  - the map, the camera (driver\'s seat, chase, free), the weather and the time of day\n'
        '  - what you did and what you saw (a screenshot or a short clip if you can)\n'
        '  - the lines of beamng.log that mention rainPuddles (console: extensions.rainPuddles.scanLog())\n\n'
        'Install: put ForeverWEATHER.zip, still zipped, into <BeamNG user folder>/current/mods/ while the game\n'
        'is closed. Settings: Pause menu > Mods > ForeverWEATHER.\n'
    ) % (version, ISSUES, version)


def commit_time():
    if os.environ.get('SOURCE_DATE_EPOCH'):
        return int(os.environ['SOURCE_DATE_EPOCH'])
    try:
        return int(subprocess.check_output(['git', '-C', ROOT, 'log', '-1', '--format=%ct'], text=True).strip())
    except Exception:
        return int(time.time())


def build(out_path, version, prerelease):
    files = []
    for d in MOD_DIRS:
        for base, dirs, names in os.walk(os.path.join(ROOT, d)):
            dirs.sort()
            for n in sorted(names):
                full = os.path.join(base, n)
                rel = os.path.relpath(full, ROOT).replace(os.sep, '/')
                if not SKIP.search(rel):
                    files.append((rel, full))
    stamp = time.gmtime(max(commit_time(), 315532800))[:6]          # (zip times start in 1980)
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    tmp = out_path + '.tmp'
    with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        def add(rel, data):
            info = zipfile.ZipInfo(rel, stamp)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            z.writestr(info, data)
        for rel, full in files:
            with open(full, 'rb') as f:
                add(rel, f.read())
        if prerelease:
            add('PRERELEASE_README.txt', notice(version).encode('utf-8'))
    os.replace(tmp, out_path)
    return len(files) + (1 if prerelease else 0)


def tag_version(tag):
    """The version a tag names: v1.6.1-pre -> 1.6.1, 1.6.0 -> 1.6.0."""
    return re.split(r'[-+]', tag.strip().lstrip('vV'), maxsplit=1)[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', default=os.path.join(ROOT, 'release', 'ForeverWEATHER.zip'))
    ap.add_argument('--check-version', metavar='X.Y.Z', help='fail unless every version string is this one')
    ap.add_argument('--final', action='store_true', help='a tested release: no pre-release notice in the zip')
    a = ap.parse_args()
    vs = versions()
    found = set(vs.values())
    if None in found or len(found) != 1:
        print('version strings disagree or are missing:', file=sys.stderr)
        for k, v in vs.items():
            print('  %-50s %s' % (k, v), file=sys.stderr)
        return 1
    version = found.pop()
    # 1.6.1: a tag may name the kind of build after the version (v1.6.1-pre, v1.5.2-alpha): the version is what
    # comes before the first '-' or '+'
    if a.check_version and tag_version(a.check_version) != version:
        print('the tag says %s but the mod says %s (mod_info, Lua and UI agree on it)' % (a.check_version, version),
              file=sys.stderr)
        return 1
    n = build(a.out, version, not a.final)
    print('%s: %d files, %.1f KB, version %s%s' % (os.path.relpath(a.out, ROOT), n, os.path.getsize(a.out) / 1024.0,
                                                  version, '' if a.final else ' (pre-release)'))
    return 0


if __name__ == '__main__':
    sys.exit(main())

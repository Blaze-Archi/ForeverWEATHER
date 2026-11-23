#!/usr/bin/env python3
"""Writes the GitHub release notes for a version: the pre-release notice first (untested, report bugs in the Issues
tab), then the version's change log (docs/history/CHANGES_v<version>.md).

  python3 tools/release_notes.py 1.6.0 [--repo owner/name] [--final] > notes.md
"""
import argparse
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('version')
    ap.add_argument('--repo', default=os.environ.get('GITHUB_REPOSITORY') or 'Blaze-Archi/ForeverWEATHER')
    ap.add_argument('--final', action='store_true', help='a tested release: no pre-release notice')
    a = ap.parse_args()
    version = a.version.lstrip('v')
    issues = 'https://github.com/%s/issues' % a.repo
    out = []
    if not a.final:
        out += [
            '> [!WARNING]',
            '> **Pre-release - untested.** This build has not been tested in BeamNG.drive yet. Expect bugs: visual',
            '> glitches, shader errors on some graphics cards or APIs, things that do not behave as described below.',
            '>',
            '> **Please report every bug in the [Issues tab](%s)** (the *Bug report* form asks for what helps: this' % issues,
            '> version, the game\'s version, DX12 or Vulkan, map, camera, weather and time of day, and the `rainPuddles`',
            '> lines of `beamng.log`). The zip carries the same notice (`PRERELEASE_README.txt`).',
            '',
        ]
    path = os.path.join(ROOT, 'docs', 'history', 'CHANGES_v%s.md' % version)
    if os.path.exists(path):
        with open(path, encoding='utf-8') as f:
            body = f.read().strip().splitlines()
        if body and body[0].startswith('# '):
            body = body[1:]                     # the release already has a title
        while body and not body[0].strip():
            body = body[1:]
        out += [line for line in body]
    else:
        out.append('Change log: see the README.')
    out += ['', '---', '**Install:** download `ForeverWEATHER.zip` below and put it, still zipped, into '
            '`<BeamNG user folder>/current/mods/` while the game is closed. Settings: *Pause menu > Mods > ForeverWEATHER*.']
    sys.stdout.write('\n'.join(out).strip() + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())

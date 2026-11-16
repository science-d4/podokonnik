#!/usr/bin/env python3
import os
import plistlib
import re
import subprocess


def main():
    pattern = re.compile(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)')
    with open('Resources/Info.plist', 'rb') as info:
        baseline = plistlib.load(info)['CFBundleShortVersionString']
    if not pattern.fullmatch('v' + baseline):
        raise SystemExit(f'Invalid baseline version: {baseline}')

    commit = os.environ['GITHUB_SHA']
    tags = subprocess.check_output(['git', 'tag', '--list'], text=True).splitlines()
    versions = [(tuple(map(int, match.groups())), tag)
                for tag in tags if (match := pattern.fullmatch(tag))]
    current_tags = set(subprocess.check_output(['git', 'tag', '--points-at', commit], text=True).splitlines())
    matching = sorted(tag for tag in current_tags if pattern.fullmatch(tag))
    if len(matching) > 1:
        raise SystemExit('Multiple version tags point to this commit; resolve manually.')

    if versions:
        latest_tag = max(versions)[1]
        ancestor = subprocess.run(['git', 'merge-base', '--is-ancestor',
                                   f'refs/tags/{latest_tag}^{{commit}}', commit], check=False)
        if ancestor.returncode == 1:
            print(f'Skipping outdated release: {latest_tag} is not an ancestor of {commit}.')
            with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
                output.write('publish=false\n')
            return
        if ancestor.returncode != 0:
            raise SystemExit('Unable to verify release ancestry.')

    if matching:
        tag = matching[0]
    else:
        existing_versions = [tuple(map(int, baseline.split('.')))]
        existing_versions.extend(version for version, _ in versions)
        major, minor, patch = max(existing_versions)
        tag = f'v{major}.{minor}.{patch + 1}'
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'publish=true\ntag={tag}\nversion={tag[1:]}\nexisting={str(bool(matching)).lower()}\n')


if __name__ == '__main__':
    main()

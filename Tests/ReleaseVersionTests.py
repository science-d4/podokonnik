import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'Scripts/select-release-version.py'
FAKE_GIT = '''#!/usr/bin/env python3
import json
import os
import sys

scenario = json.loads(os.environ['RELEASE_TEST_SCENARIO'])
args = sys.argv[1:]
if args == ['tag', '--list']:
    print('\\n'.join(scenario['tags']))
elif args == ['tag', '--points-at', os.environ['GITHUB_SHA']]:
    print('\\n'.join(scenario.get('current_tags', [])))
elif args[:2] == ['merge-base', '--is-ancestor']:
    expected = scenario.get('expected_ancestor')
    if args[2:] != [f'refs/tags/{expected}^{{commit}}', os.environ['GITHUB_SHA']]:
        sys.exit(2)
    sys.exit(scenario['ancestor_result'])
else:
    sys.exit(2)
'''


class ReleaseVersionTests(unittest.TestCase):
    def run_selection(self, scenario):
        with tempfile.TemporaryDirectory(prefix='podokonnik-release-test-') as directory:
            root = Path(directory)
            (root / 'Resources').mkdir()
            with (root / 'Resources/Info.plist').open('wb') as info:
                plistlib.dump({'CFBundleShortVersionString': '1.7.1'}, info)
            fake_git = root / 'git'
            fake_git.write_text(FAKE_GIT)
            fake_git.chmod(0o755)
            output = root / 'output'
            output.touch()
            env = os.environ.copy()
            env.update(PATH=f'{root}{os.pathsep}{env["PATH"]}', GITHUB_SHA='candidate',
                       GITHUB_OUTPUT=str(output), RELEASE_TEST_SCENARIO=json.dumps(scenario))
            result = subprocess.run([sys.executable, str(SCRIPT)], cwd=root, env=env,
                                    text=True, capture_output=True)
            return result, dict(line.split('=', 1) for line in output.read_text().splitlines())

    def test_older_commit_finishing_after_newer_release_is_skipped(self):
        result, output = self.run_selection({'tags': ['v1.7.2', 'v1.7.10'],
                                             'expected_ancestor': 'v1.7.10', 'ancestor_result': 1})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, {'publish': 'false'})

    def test_retry_of_old_tag_after_newer_release_is_skipped(self):
        result, output = self.run_selection({'tags': ['v1.7.2', 'v1.7.10'],
                                             'current_tags': ['v1.7.2'],
                                             'expected_ancestor': 'v1.7.10', 'ancestor_result': 1})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, {'publish': 'false'})

    def test_descendant_gets_next_numeric_version(self):
        result, output = self.run_selection({'tags': ['v1.7.9', 'v1.7.10', 'unrelated'],
                                             'expected_ancestor': 'v1.7.10', 'ancestor_result': 0})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, {'publish': 'true', 'tag': 'v1.7.11',
                                  'version': '1.7.11', 'existing': 'false'})

    def test_latest_commit_retry_reuses_its_tag(self):
        result, output = self.run_selection({'tags': ['v1.7.2'], 'current_tags': ['v1.7.2'],
                                             'expected_ancestor': 'v1.7.2', 'ancestor_result': 0})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, {'publish': 'true', 'tag': 'v1.7.2',
                                  'version': '1.7.2', 'existing': 'true'})

    def test_first_release_uses_baseline(self):
        result, output = self.run_selection({'tags': []})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output['tag'], 'v1.7.2')

    def test_ancestry_error_fails_closed(self):
        result, output = self.run_selection({'tags': ['v1.7.2'],
                                             'expected_ancestor': 'v1.7.2', 'ancestor_result': 128})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output, {})

    def test_multiple_current_version_tags_fail_closed(self):
        result, output = self.run_selection({'tags': ['v1.7.2', 'v1.7.3'],
                                             'current_tags': ['v1.7.2', 'v1.7.3']})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output, {})


if __name__ == '__main__':
    unittest.main()

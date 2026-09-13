#!/usr/bin/env python3
"""Exercise the actual workflow shell against a local Git remote and fake GitHub API."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = yaml.safe_load((ROOT / '.github/workflows/update-checker.yml').read_text())
STEPS = WORKFLOW['jobs']['check']['steps']
DECISION = next(step['run'] for step in STEPS if step.get('id') == 'decision')
DISPATCH = STEPS[-1]['run']


class MonitorTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.work = self.root / 'work'
        self.work.mkdir()
        self.remote = self.root / 'remote.git'
        self.env = dict(os.environ, GITHUB_REPOSITORY='test/firmware',
                        GITHUB_RUN_ID='123', SOURCE_DIGEST='test-digest',
                        MONITOR_STATE_REF=WORKFLOW['env']['MONITOR_STATE_REF'],
                        GITHUB_OUTPUT=str(self.root / 'output'),
                        GITHUB_STEP_SUMMARY=str(self.root / 'summary'),
                        DISPATCH_LOG=str(self.root / 'dispatches'), DAY='2')
        self.run_command('git', 'init', '--bare', '-q', str(self.remote))
        self.run_command('git', 'init', '-q')
        self.run_command('git', 'remote', 'add', 'origin', str(self.remote))
        (self.work / '.source-state').mkdir()
        (self.work / 'scripts').mkdir()
        # Frozen-input validation belongs to source_lock's tests. Here use its
        # real projection with small input fixtures to isolate scheduling/storage.
        (self.work / 'scripts/source_lock.py').write_text(
            f'import sys,json\nsys.path.insert(0, {str(ROOT / "scripts")!r})\n'
            'from source_lock import update_compatibility_projection\n'
            'if sys.argv[1] == "update-projection":\n'
            ' print(json.dumps(update_compatibility_projection(json.load(open(sys.argv[2]))),'
            ' sort_keys=True, ensure_ascii=False, indent=2))\n')
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        self.env['PATH'] = f'{bin_dir}:{self.env["PATH"]}'
        for name, script in {
            'date': 'printf "%s\\n" "$DAY"',
            'gh': '''case "$*" in
  "release download"*)
    [ "${FAIL_RELEASE_DOWNLOAD:-0}" = 0 ] || exit 1
    cp "$RELEASE_LOCK" .source-state/released/source-lock.json ;;
  *dispatches*)
    cat >/dev/null
    [ "${FAIL_DISPATCH:-0}" = 0 ] || exit 1
    echo accepted >> "$DISPATCH_LOG" ;;
  *releases*)
    [ "${FAIL_RELEASE_API:-0}" = 0 ] || exit 1
    printf '%s\\n' "${RELEASE_TAG:-}" ;;
  *) exit 2 ;;
esac''',
        }.items():
            executable = bin_dir / name
            executable.write_text('#!/bin/bash\nset -eu\n' + script + '\n')
            executable.chmod(0o755)
        self.lock = {'profiles': {'device': {'kernel_series': '6.12'}},
                     'openwrt': {'commit': 'a' * 40}}

    def run_command(self, *command, check=True):
        return subprocess.run(command, cwd=self.work, env=self.env, text=True,
                              capture_output=True, check=check)

    def decide(self, check=True):
        (self.work / '.source-state/source-lock.json').write_text(json.dumps(self.lock))
        for name in ('baseline.json',):
            (self.work / '.source-state' / name).unlink(missing_ok=True)
        Path(self.env['GITHUB_OUTPUT']).write_text('')
        result = self.run_command('bash', '-c', DECISION.replace(
            '${{ steps.lock.outputs.source_digest }}', 'test-digest'), check=check)
        self.outputs = dict(line.split('=', 1) for line in
                            Path(self.env['GITHUB_OUTPUT']).read_text().splitlines())
        return result

    def dispatch(self, check=True):
        self.env['STATE_COMMIT'] = self.outputs['state_commit']
        return self.run_command('bash', '-c', DISPATCH, check=check)

    def test_failed_build_does_not_repeat_but_weekly_and_new_boundary_do(self):
        self.decide()
        self.assertEqual(self.outputs['reason'], 'significant')
        self.dispatch()
        # No Release and no successful build: the accepted dispatch is sufficient.
        self.lock['openwrt']['commit'] = 'b' * 40
        self.decide()
        self.assertEqual(self.outputs['dispatch'], 'false')
        self.env['DAY'] = '1'
        self.decide()
        self.assertEqual(self.outputs['reason'], 'weekly')
        self.dispatch()
        self.env['DAY'] = '2'
        self.lock['profiles']['device']['kernel_series'] = '6.18'
        self.decide()
        self.assertEqual(self.outputs['reason'], 'significant')
        self.dispatch()
        self.decide()
        self.assertEqual(self.outputs['dispatch'], 'false')
        files = self.run_command('git', 'ls-tree', '--name-only',
                                 self.outputs['state_commit']).stdout.splitlines()
        self.assertEqual(files, ['compatibility.json'])

    def test_rejected_dispatch_does_not_record_state(self):
        self.decide()
        self.env['FAIL_DISPATCH'] = '1'
        self.assertNotEqual(self.dispatch(check=False).returncode, 0)
        self.assertEqual(self.run_command('git', 'ls-remote', 'origin').stdout, '')
        self.decide()
        self.assertEqual(self.outputs['dispatch'], 'true')

    def test_remote_read_failure_is_not_a_build_trigger(self):
        self.run_command('git', 'remote', 'set-url', 'origin', str(self.root / 'missing'))
        self.assertNotEqual(self.decide(check=False).returncode, 0)
        self.assertNotIn('dispatch', self.outputs)

    def test_release_api_failure_is_not_bootstrap(self):
        self.env['FAIL_RELEASE_API'] = '1'
        self.assertNotEqual(self.decide(check=False).returncode, 0)
        self.assertNotIn('dispatch', self.outputs)

    def test_state_write_conflict_is_visible(self):
        self.decide()
        self.dispatch()
        self.env['DAY'] = '1'
        self.decide()
        self.outputs['state_commit'] = '0' * 40
        self.env['GITHUB_RUN_ID'] = '124'
        self.assertNotEqual(self.dispatch(check=False).returncode, 0)

    def test_bootstrap_uses_release_until_first_dispatch(self):
        release = self.root / 'release.json'
        release.write_text(json.dumps(self.lock))
        self.env.update(RELEASE_TAG='openwrt-test', RELEASE_LOCK=str(release))
        self.decide()
        self.assertEqual(self.outputs['dispatch'], 'false')
        self.lock['profiles']['device']['kernel_series'] = '6.18'
        self.decide()
        self.assertEqual(self.outputs['dispatch'], 'true')
        self.dispatch()
        # Once persisted, the old Release is no longer consulted.
        self.env['FAIL_RELEASE_API'] = '1'
        self.decide()
        self.assertEqual(self.outputs['dispatch'], 'false')

    def test_missing_release_asset_is_not_a_build_trigger(self):
        self.env.update(RELEASE_TAG='openwrt-test', FAIL_RELEASE_DOWNLOAD='1')
        self.assertNotEqual(self.decide(check=False).returncode, 0)
        self.assertNotIn('dispatch', self.outputs)


if __name__ == '__main__':
    unittest.main()

import copy
import tempfile
from pathlib import Path
import unittest
from baseline import reference_metrics
from ci_reference import base_revision, copy_harness, HARNESS
from report import evaluate


class ReferenceTests(unittest.TestCase):
    def setUp(self):
        self.env = dict(schema=3, os='26', arch='arm64', cpu='M1', swift='6',
                        harness='candidate', comparison_session='run-1-1')
        self.budgets = {'load': dict(min_samples=3, max_p95=100, noise_floor=5)}
        self.previous = dict(environment=self.env.copy(), measurement_failures=[],
                             metrics={'load': dict(samples=3, p95=20)}, failures=[])

    def test_relative_gate_uses_same_session_reference(self):
        metrics = reference_metrics(self.previous, self.env, self.budgets)
        self.assertTrue(evaluate([dict(metric='load', value=26)] * 3, self.budgets, metrics)[1])

    def test_slow_reference_never_relaxes_absolute_cap(self):
        self.previous['metrics']['load']['p95'] = 150
        self.previous['failures'] = ['load exceeds absolute budget']
        metrics = reference_metrics(self.previous, self.env, self.budgets)
        self.assertTrue(evaluate([dict(metric='load', value=101)] * 3, self.budgets, metrics)[1])

    def test_rejects_other_runner_attempt_harness_and_environment(self):
        for key in self.env:
            with self.subTest(key=key):
                previous = copy.deepcopy(self.previous)
                previous['environment'][key] = 'different'
                with self.assertRaises(ValueError): reference_metrics(previous, self.env, self.budgets)

    def test_rejects_incomplete_or_invalid_reference(self):
        for patch in ({'measurement_failures': ['timeout']}, {'measurement_failures': None},
                      {'metrics': {}}, {'metrics': {'load': dict(samples=2, p95=20)}},
                      {'metrics': {'load': dict(samples=3, p95=True)}},
                      {'metrics': {'load': dict(samples=3, p95=float('nan'))}}):
            with self.subTest(patch=patch):
                with self.assertRaises(ValueError):
                    reference_metrics({**self.previous, **patch}, self.env, self.budgets)

    def test_pins_event_base_not_candidate_or_moving_branch(self):
        sha = 'a' * 40
        self.assertEqual(base_revision('pull_request', {'pull_request': {'base': {'sha': sha}}}, None), sha)
        self.assertEqual(base_revision('push', {'before': sha}, None), sha)
        self.assertEqual(base_revision('workflow_dispatch', {}, lambda: sha), sha)
        for invalid in ('0' * 40, 'main', 'abc; echo nope'):
            with self.assertRaises(ValueError): base_revision('push', {'before': invalid}, None)

    def test_fixture_copy_preserves_production_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root, base = Path(directory) / 'candidate', Path(directory) / 'base'
            for tree, content in ((root, 'candidate'), (base, 'base')):
                for name in HARNESS:
                    path = tree / name
                    if name == 'tests/performance': path = path / 'run.py'
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(content)
                (tree / 'shell/production.swift').write_text(content)
            copy_harness(root, base)
            self.assertEqual((base / 'tests/performance/run.py').read_text(), 'candidate')
            self.assertEqual((base / 'shell/production.swift').read_text(), 'base')


class RunnerTests(unittest.TestCase):
    def run_fixture(self, root, flags=(), slow=False, crash=False):
        import contextlib
        import io
        import json
        import run
        from unittest.mock import patch
        stage = root / 'stage'
        (stage / 'runtime').mkdir(parents=True, exist_ok=True)
        (stage / 'runtime/VERSION').write_text('fixture')
        output = root / 'output'
        budgets = json.loads(Path(run.__file__).with_name('budgets.json').read_text())

        def measurements(stage, work, output, record):
            for name, budget in budgets.items():
                for _ in range(budget['min_samples']):
                    record(name, budget['max_p95'] * (2 if slow else .1))
            if crash:
                raise TimeoutError('fixture readiness timed out')

        async def noop(*args): pass
        with patch('sys.argv', ['run.py', '--stage', str(stage), '--output', str(output), *flags]), \
             patch.dict(run.os.environ, {}, clear=True), \
             patch.object(run.subprocess, 'check_output', return_value='fixture'), \
             patch.object(run, 'shell_startup', side_effect=measurements), \
             patch.object(run, 'browser_startup', side_effect=noop), \
             patch.object(run, 'backend_workloads', side_effect=noop), \
             patch.object(run, 'offline_upgrade'), patch.object(run, 'command'), \
             contextlib.redirect_stdout(io.StringIO()):
            status = run.main()
        return status, json.loads((output / 'report.json').read_text())

    def test_missing_baseline_fails_but_keeps_absolute_results(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            status, report = self.run_fixture(root, ['--baseline', str(root / 'missing.json')])
            self.assertTrue(status)
            self.assertTrue(report['metrics'])
            self.assertIn('Baseline comparison unavailable', report['baseline'])

    def test_reference_threshold_failure_is_usable_but_timeout_is_not(self):
        for crash in (False, True):
            with self.subTest(crash=crash), tempfile.TemporaryDirectory() as directory:
                status, report = self.run_fixture(Path(directory), ['--reference'], slow=True, crash=crash)
                self.assertEqual(status, crash)
                self.assertTrue(report['failures'])
                self.assertEqual(bool(report['measurement_failures']), crash)

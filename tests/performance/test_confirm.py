import unittest
from unittest.mock import patch
from pathlib import Path
import subprocess

from confirm import ROOT, confirmed_regressions, relative_failures, run


class ConfirmationTests(unittest.TestCase):
    def report(self, **metrics):
        results = {name: dict(p95=p95, limit=limit) for name, (p95, limit) in metrics.items()}
        return dict(metrics=results, measurement_failures=[],
                    baseline='Compared with reference base measured in session pair.',
                    failures=[name + ': too slow' for name, (p95, limit) in metrics.items() if p95 > limit])

    def test_only_repeated_relative_failure_blocks(self):
        with patch('confirm.BUDGETS', {'switch': {'max_p95': 16}, 'startup': {'max_p95': 3000}}):
            first = relative_failures(self.report(switch=(14, 7), startup=(1000, 1500)))
            second = self.report(switch=(5, 8), startup=(1700, 1500))['metrics']
            self.assertEqual(confirmed_regressions(first, second), set())
            self.assertEqual(confirmed_regressions(first, self.report(switch=(11, 8), startup=(1000, 1500))['metrics']), {'switch'})

    def test_absolute_and_incomplete_failure_cannot_be_retried(self):
        with patch('confirm.BUDGETS', {'switch': {'max_p95': 16}}):
            with self.assertRaisesRegex(ValueError, 'absolute budget'):
                relative_failures(self.report(switch=(17, 7)))
            incomplete = self.report(switch=(14, 7))
            incomplete['measurement_failures'] = ['socket timeout']
            with self.assertRaisesRegex(ValueError, 'incomplete'):
                relative_failures(incomplete)


class CheckoutSelectionTests(unittest.TestCase):
    def test_each_measurement_executes_its_own_checkout_harness(self):
        base_root = ROOT / '.performance-base'
        for root, source, reference in [(ROOT, 'candidate-sha', False),
                                        (base_root, 'base-sha', True)]:
            with self.subTest(reference=reference), \
                    patch('confirm.subprocess.check_output', return_value=source + '\n') as revision, \
                    patch('confirm.subprocess.run', return_value=subprocess.CompletedProcess([], 0)) as launch:
                self.assertEqual(run(source, Path('/stage'), Path('/output'),
                                     root=root, reference=reference), 0)
                revision.assert_called_once_with(['git', '-C', str(root.resolve()), 'rev-parse', 'HEAD'], text=True)
                command = launch.call_args.args[0]
                self.assertEqual(command[1], str(root / 'tests/performance/run.py'))
                self.assertEqual(launch.call_args.kwargs['cwd'], root)
                self.assertEqual(launch.call_args.kwargs['env']['BOWSER_PERF_SOURCE'], source)
                self.assertEqual('--reference' in command, reference)

    def test_mislabeled_checkout_is_rejected_before_measurement(self):
        with patch('confirm.subprocess.check_output', return_value='candidate-sha\n'), \
                patch('confirm.subprocess.run') as launch:
            with self.assertRaisesRegex(ValueError, 'expected base-sha'):
                run('base-sha', Path('/base-stage'), Path('/output'))
            launch.assert_not_called()


if __name__ == '__main__':
    unittest.main()

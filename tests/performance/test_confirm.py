import unittest
from unittest.mock import patch

from confirm import confirmed_regressions, relative_failures


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


if __name__ == '__main__':
    unittest.main()

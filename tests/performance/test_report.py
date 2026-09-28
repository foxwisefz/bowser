import unittest
from report import evaluate

class GateTests(unittest.TestCase):
    budgets = {'load': dict(min_samples=3, max_p95=100, noise_floor=5)}
    def rows(self, values): return [dict(metric='load', value=v) for v in values]
    def test_missing_and_short_workloads_fail(self):
        for values in ([], [1, 2]):
            self.assertTrue(evaluate(self.rows(values), self.budgets)[1])
    def test_absolute_budget_and_nearest_rank(self):
        metrics, failures = evaluate(self.rows([1, 2, 101]), self.budgets)
        self.assertEqual(metrics['load']['p50'], 2)
        self.assertEqual(metrics['load']['p95'], 101)
        self.assertTrue(failures)
    def test_failure_preserves_sample_order_without_dropping_outlier(self):
        metrics, failures = evaluate(self.rows([1300, 196, 180, 210, 190]), self.budgets)
        self.assertEqual(metrics['load']['p95'], 1300)
        self.assertIn('1300.00, 196.00, 180.00, 210.00, 190.00', failures[0])
    def test_relative_regression_with_noise_floor(self):
        baseline = {'load': {'p95': 20}}
        self.assertFalse(evaluate(self.rows([23]*3), self.budgets, baseline)[1])
        self.assertTrue(evaluate(self.rows([26]*3), self.budgets, baseline)[1])
    def test_invalid_samples_fail_closed(self):
        for value in (float('nan'), float('inf'), -1, True, '3'):
            with self.assertRaises(ValueError): evaluate(self.rows([value]), self.budgets)
    def test_unknown_metric_fails(self):
        with self.assertRaises(ValueError): evaluate([dict(metric='typo', value=1)], self.budgets)
    def test_complete_run_passes(self):
        self.assertFalse(evaluate(self.rows([1, 2, 3]), self.budgets)[1])

if __name__ == '__main__': unittest.main()

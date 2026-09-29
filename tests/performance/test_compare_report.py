import unittest
from compare_report import EXPECTED, summarize, gate, assess

class ComparisonTests(unittest.TestCase):
    def runs(self):
        return [dict(browser=browser, fixture=[1000,650], visibility='visible', scrollTop=3840,
                     devicePixelRatio=2, client=[983,650], samples=[dict(metric=name,value=value) for name,count in EXPECTED.items() for _ in range(count)])
                for browser,value in [('bowser',10),('safari',5)]]
    def test_complete_over_budget_is_failure_not_incomplete(self):
        budgets = {name: dict(max_ratio=1.25, noise_floor=0) for name in EXPECTED}
        report = assess(self.runs(), 1, budgets)
        self.assertEqual(report['status'], 'FAIL')
        self.assertEqual(len(report['failures']), len(EXPECTED))
        self.assertEqual(report['comparison']['layout_1000_rows_ms']['limit'], 6.25)

    def test_complete_within_budget_passes(self):
        budgets = {name: dict(max_ratio=2, noise_floor=0) for name in EXPECTED}
        report = assess(self.runs(), 1, budgets)
        self.assertEqual(report['status'], 'PASS')
        self.assertFalse(report['failures'])

    def test_missing_or_failed_execution_is_incomplete(self):
        budgets = {name: dict(max_ratio=2, noise_floor=0) for name in EXPECTED}
        for runs, errors in [(self.runs()[:1], []), (self.runs(), ['driver failed'])]:
            report = assess(runs, 1, budgets, errors)
            self.assertEqual(report['status'], 'INCOMPLETE')
            self.assertTrue(report['failures'])

    def test_identical_measurements_compare_ratios(self):
        summary, comparison = summarize(self.runs(), 1)
        self.assertEqual(comparison['layout_1000_rows_ms']['ratio'], 2)
        self.assertEqual(summary['bowser']['scroll_frame_interval_ms']['runs'], 1)
    def test_missing_browser_or_samples_fails(self):
        for missing_browser in (True,False):
            runs=self.runs()
            if missing_browser: runs.pop()
            else: runs[0]['samples'].pop()
            with self.assertRaises(ValueError): summarize(runs,1)
    def test_hidden_clipped_failed_and_mismatched_display_fail(self):
        for key,value in [('visibility','hidden'),('fixture',[100,100]),('error','timeout'),('devicePixelRatio',1),('scrollTop',0),('client',[1000,650])]:
            runs=self.runs(); runs[0][key]=value
            with self.assertRaises(ValueError): summarize(runs,1)
    def test_invalid_numbers_fail(self):
        for value in (float('nan'),float('inf'),-1,True):
            runs=self.runs(); runs[0]['samples'][0]['value']=value
            with self.assertRaises(ValueError): summarize(runs,1)
    def test_zero_safari_value_is_not_infinite_speedup(self):
        runs=self.runs()
        for row in runs[1]['samples']: row['value']=0
        self.assertIsNone(summarize(runs,1)[1]['layout_1000_rows_ms']['ratio'])

class RelativeGateTests(unittest.TestCase):
    def test_noise_floor_and_relative_threshold(self):
        budgets={'metric':dict(max_ratio=1.25,noise_floor=3)}
        self.assertFalse(gate({'metric':dict(bowser=12,safari=10)},budgets))
        self.assertTrue(gate({'metric':dict(bowser=14,safari=10)},budgets))
        self.assertTrue(gate({'metric':dict(bowser=126,safari=100)},budgets))
    def test_missing_metric_fails(self):
        with self.assertRaises(ValueError): gate({}, {'metric':dict(max_ratio=1.25,noise_floor=3)})

if __name__ == '__main__': unittest.main()

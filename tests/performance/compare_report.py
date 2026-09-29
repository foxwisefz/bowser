"""Compare identical in-page clocks; never mix them with internal Bowser timers."""
import math
import statistics

EXPECTED = {'navigation_two_frames_ms': 1, 'dom_content_loaded_ms': 1,
            'layout_1000_rows_ms': 20, 'scroll_frame_interval_ms': 120,
            'scroll_long_frames_percent': 1}


def summarize(runs, expected_runs):
    summary = {}
    for browser in ('bowser', 'safari'):
        selected = [run for run in runs if run['browser'] == browser]
        if len(selected) != expected_runs: raise ValueError(f'{browser}: incomplete runs')
        aggregate = {name: [] for name in EXPECTED}
        for run in selected:
            if run.get('error'): raise ValueError(run['error'])
            if run.get('visibility') != 'visible' or run.get('fixture') != [1000, 650] or run.get('scrollTop') != 3840:
                raise ValueError('Invalid viewport, visibility or scroll distance')
            samples = {name: [] for name in EXPECTED}
            for row in run['samples']:
                value = row['value']
                if row['metric'] not in samples or isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
                    raise ValueError('Invalid measurement')
                samples[row['metric']].append(value)
            for name, values in samples.items():
                if len(values) != EXPECTED[name]: raise ValueError(f'Missing/extra samples: {name}')
                # A run is the replicate; don't pretend 120 adjacent frames are 120 independent runs.
                values.sort()
                aggregate[name].append(values[math.ceil(.95 * len(values))-1])
        summary[browser] = {name: dict(runs=len(values), median_run_p95=statistics.median(values),
                                     min_run_p95=min(values), max_run_p95=max(values))
                            for name, values in aggregate.items()}
    sizes = {tuple(run['client']) for run in runs}
    if len(sizes) != 1: raise ValueError('Browsers used different scrollable content sizes')
    scales = {run['devicePixelRatio'] for run in runs}
    if len(scales) != 1: raise ValueError('Browsers used different display scales')
    comparison = {}
    for name in EXPECTED:
        bowser = summary['bowser'][name]['median_run_p95']; safari = summary['safari'][name]['median_run_p95']
        comparison[name] = dict(bowser=bowser, safari=safari, ratio=bowser/safari if safari else None)
    return summary, comparison


def gate(comparison, budgets):
    """Relative Safari budgets with explicit absolute allowances for timer noise."""
    if set(comparison) != set(budgets): raise ValueError('Incomplete comparison budgets')
    failures = []
    for metric, result in comparison.items():
        budget = budgets[metric]
        limit = max(result['safari'] * budget['max_ratio'], result['safari'] + budget['noise_floor'])
        result['limit'] = limit
        if result['bowser'] > limit:
            failures.append(f'{metric}: Bowser {result["bowser"]:.2f} exceeds Safari-relative limit {limit:.2f}')
    return failures


def assess(runs, expected_runs, budgets, execution_errors=()):
    """Separate missing/invalid evidence from a completed comparison over budget."""
    failures = list(execution_errors)
    summary, comparison = {}, {}
    try:
        summary, comparison = summarize(runs, expected_runs)
        budget_failures = gate(comparison, budgets)
    except ValueError as error:
        failures.append(str(error))
        return dict(status='INCOMPLETE', summary=summary, comparison={}, failures=failures)
    status = 'INCOMPLETE' if execution_errors else 'FAIL' if budget_failures else 'PASS'
    return dict(status=status, summary=summary, comparison=comparison,
                failures=failures + budget_failures)

#!/usr/bin/env python3
"""Confirm a relative regression with a second, reverse-order paired run."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from baseline import reference_metrics
from report import evaluate


ROOT = Path(__file__).resolve().parents[2]
BUDGETS = json.loads((Path(__file__).with_name('budgets.json')).read_text())


def read(path):
    return json.loads(path.read_text())


def relative_failures(report):
    """Return failed metric names, or reject results a retry cannot validate."""
    if report.get('measurement_failures'):
        raise ValueError('candidate measurements were incomplete')
    if not report.get('baseline', '').startswith('Compared with reference '):
        raise ValueError('candidate lacked a compatible reference')
    metrics = report.get('metrics', {})
    if set(metrics) != set(BUDGETS):
        raise ValueError('candidate lacks required metrics')
    for name, result in metrics.items():
        if result['p95'] > BUDGETS[name]['max_p95']:
            raise ValueError(f'{name} exceeds its absolute budget')
    failed = {name for name, result in metrics.items() if result['p95'] > result['limit']}
    if len(report.get('failures', [])) != len(failed):
        raise ValueError('candidate has a failure outside relative budgets')
    return failed


def confirmed_regressions(initial, metrics):
    return initial & {name for name, result in metrics.items() if result['p95'] > result['limit']}


def run(source, stage, output, *, root=ROOT, reference=False, base=None):
    root = root.resolve()
    actual = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != source:
        raise ValueError(f'Benchmark checkout {root} is {actual}, expected {source}')
    environment = {**os.environ, 'BOWSER_PERF_SOURCE': source}
    command = [sys.executable, str(root / 'tests/performance/run.py'),
               '--stage', str(stage), '--output', str(output)]
    if reference:
        command.append('--reference')
    if base:
        command += ['--baseline', str(base)]
    return subprocess.run(command, cwd=root, env=environment).returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--primary', type=Path, required=True)
    parser.add_argument('--candidate-stage', type=Path, required=True)
    parser.add_argument('--base-stage', type=Path, required=True)
    parser.add_argument('--base-source', required=True)
    parser.add_argument('--base-root', required=True, type=Path,
                        help='Checkout of the pinned base, with the candidate harness copied into it')
    parser.add_argument('--output-root', type=Path, required=True)
    args = parser.parse_args()
    primary = read(args.primary)
    try:
        initial = relative_failures(primary)
        if not initial:
            raise ValueError('candidate step failed without a relative regression')
    except ValueError as error:
        print(f'Confirmation unavailable: {error}', file=sys.stderr)
        return 1

    candidate_output = args.output_root / 'performance-confirm'
    base_output = args.output_root / 'performance-base-confirm'
    # The first pair measures base then candidate. Reverse that order to
    # distinguish a revision effect from runner warming and background load.
    candidate_status = run(primary['environment']['source'], args.candidate_stage, candidate_output)
    if candidate_status:
        print('Confirmation candidate missed an absolute budget or measurement.', file=sys.stderr)
        return 1
    base_status = run(args.base_source, args.base_stage, base_output,
                      root=args.base_root, reference=True)
    if base_status:
        print('Confirmation reference measurements were incomplete.', file=sys.stderr)
        return 1

    candidate = read(candidate_output / 'report.json')
    base = read(base_output / 'report.json')
    try:
        reference = reference_metrics(base, candidate['environment'], BUDGETS)
        rows = [json.loads(line) for line in (candidate_output / 'samples.jsonl').read_text().splitlines()]
        metrics, failures = evaluate(rows, BUDGETS, reference)
        repeated = confirmed_regressions(initial, metrics)
        if candidate.get('measurement_failures') or not metrics:
            raise ValueError('confirmation candidate measurements were incomplete')
    except (ValueError, KeyError) as error:
        print(f'Confirmation invalid: {error}', file=sys.stderr)
        return 1

    lines = ['# Performance regression confirmation', '',
             'Both pairs use the same runner and unchanged limits. The second pair measures candidate before base.', '',
             '| Metric | First pair candidate / limit | Second pair candidate / limit |',
             '|---|---:|---:|']
    for name in sorted(initial | {n for n, value in metrics.items() if value['p95'] > value['limit']}):
        first = primary['metrics'][name]
        second = metrics[name]
        lines.append(f'| {name} | {first["p95"]:.2f} / {first["limit"]:.2f} | {second["p95"]:.2f} / {second["limit"]:.2f} |')
    lines += ['', 'FAIL' if repeated else 'PASS',
              'Repeated regressions: ' + (', '.join(sorted(repeated)) if repeated else 'none')]
    summary = '\n'.join(lines) + '\n'
    (args.output_root / 'performance-confirm-summary.md').write_text(summary)
    print(summary)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as file:
            file.write(summary)
    return bool(repeated)


if __name__ == '__main__':
    sys.exit(main())

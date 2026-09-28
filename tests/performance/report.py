"""Strict performance gate: missing workloads never count as a passing run."""
import math


def evaluate(rows, budgets, baseline=None):
    samples = {}
    for row in rows:
        name, value = row['metric'], row['value']
        if name not in budgets or isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
            raise ValueError(f'Invalid performance sample: {row}')
        samples.setdefault(name, []).append(value)
    metrics, failures = {}, []
    for name, budget in budgets.items():
        values = sorted(samples.get(name, []))
        if len(values) < budget['min_samples']:
            failures.append(f'{name}: {len(values)} samples; need {budget["min_samples"]}')
        if not values:
            continue
        p95 = values[math.ceil(len(values) * .95) - 1]
        metrics[name] = dict(samples=len(values), p50=values[math.ceil(len(values) * .5)-1], p95=p95)
        limit = budget['max_p95']
        if baseline and name in baseline:
            old = baseline[name]['p95']
            if not isinstance(old, (int, float)) or not math.isfinite(old) or old < 0:
                raise ValueError(f'Invalid baseline: {name}')
            limit = min(limit, max(old * 1.25, old + budget['noise_floor']))
        metrics[name]['limit'] = limit
        if p95 > limit:
            failures.append(f'{name}: p95 {p95:.2f} exceeds {limit:.2f}; samples in collection order: ' + ', '.join(f'{value:.2f}' for value in samples[name]))
    return metrics, failures

"""Validate a complete reference measurement before applying relative gates."""
import math


def reference_metrics(previous, environment, budgets):
    for key in ('schema', 'os', 'arch', 'cpu', 'swift', 'harness'):
        if previous['environment'].get(key) != environment.get(key):
            raise ValueError(f'Baseline differs in {key}; comparison unavailable')
    session = environment.get('comparison_session')
    if session and previous['environment'].get('comparison_session') != session:
        raise ValueError('Baseline was not measured in this runner session')
    if previous.get('measurement_failures') != []:
        raise ValueError('Baseline measurements are incomplete or failed')
    metrics = previous['metrics']
    for name, budget in budgets.items():
        value = metrics.get(name, {})
        count, p95 = value.get('samples'), value.get('p95')
        if type(count) is not int or count < budget['min_samples']:
            raise ValueError(f'Baseline lacks required samples: {name}')
        if type(p95) not in (int, float) or not math.isfinite(p95) or p95 < 0:
            raise ValueError(f'Invalid baseline p95: {name}')
    # Reference budget violations do not erase measurements. Candidate absolute
    # caps still apply, even when the base is already slower than the cap.
    return metrics

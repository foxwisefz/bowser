"""Pin the CI base revision and reuse identical workloads against both sources."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def base_revision(event_name, event, parent):
    if event_name == 'pull_request':
        revision = event['pull_request']['base']['sha']
    elif event_name == 'push':
        revision = event['before']
    elif event_name == 'workflow_dispatch':
        revision = parent()
    else:
        raise ValueError(f'Unsupported performance event: {event_name}')
    if not re.fullmatch(r'[0-9a-f]{40}', revision) or revision == '0' * 40:
        raise ValueError('A pinned base commit is required for performance comparison')
    return revision


# Copy test inputs only: production sources and build tools stay at the base SHA.
HARNESS = ('tests/performance', 'tests/test_backend_host.py', 'tests/test_apply_update.py',
           'tests/fixtures/handoff_candidate.py',
           'shell/Tests/BowserTests/BrowserPerformanceTests.swift',
           'shell/Tests/BowserTests/BrowserFixtureServer.swift')


def copy_harness(root, destination):
    for name in HARNESS:
        source, target = root / name, destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.is_dir():
            if target.exists():
                shutil.rmtree(target)
            shutil.copytree(source, target, ignore=shutil.ignore_patterns('__pycache__'))
        else:
            shutil.copy2(source, target)


if __name__ == '__main__':
    if len(sys.argv) == 2:
        copy_harness(Path(__file__).resolve().parents[2], Path(sys.argv[1]).resolve())
    else:
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        revision = base_revision(os.environ['GITHUB_EVENT_NAME'], event,
                                 lambda: subprocess.check_output(['git', 'rev-parse', 'HEAD^'], text=True).strip())
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write(f'sha={revision}\n')

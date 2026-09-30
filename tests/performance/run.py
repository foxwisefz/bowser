#!/usr/bin/env python3
"""Disposable release workloads. Never connects to the installed browser."""
import argparse
import asyncio
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import traceback
import uuid
from report import evaluate
from baseline import reference_metrics
from startup_probe import wait_for_tabs

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests'))
ENV = {**os.environ, 'BOWSER_TELEMETRY_DISABLED': '1', 'BOWSER_API_ENDPOINT': 'http://127.0.0.1:1', 'BOWSER_NO_SPAWN': '1'}


def command(args, log, env=None, timeout=1200):
    with log.open('ab') as output:
        subprocess.run(list(map(str, args)), cwd=ROOT, env=env or ENV, stdout=output, stderr=subprocess.STDOUT, check=True, timeout=timeout)


def stop(process):
    if process.poll() is None:
        process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait(timeout=5)


def receive(sock, count):
    data = b''
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk: raise RuntimeError('Startup listener disconnected')
        data += chunk
    return data


def shell_startup(stage, work, output, record):
    bundle = work / 'Performance.app'
    shutil.copytree(stage / 'bundle', bundle)
    info = bundle / 'Contents/Info.plist'
    plist = plistlib.loads(info.read_bytes())
    plist['CFBundleIdentifier'] = 'com.foxwiseai.bowser.performance.' + uuid.uuid4().hex
    plist.pop('BowserRuntimeDirectory', None)
    info.write_bytes(plistlib.dumps(plist))
    # This startup probe measures the native shell; backend has a separate probe.
    embedded = bundle / 'Contents/Resources/runtime'
    if embedded.exists(): shutil.rmtree(embedded)
    command(['codesign', '--force', '--deep', '--sign', '-', bundle], output / 'startup.log')
    for index in range(3):
        home = work / f'startup-{index}'; home.mkdir()
        (home / 'registration.json').write_text(json.dumps(dict(registrationID='performance-fixture', telemetryToken='fixture', request=dict(requestID=str(uuid.uuid4()), email='fixture@example.invalid', termsVersion='fixture', acceptedAt=0))))
        with (output / 'startup.log').open('ab') as log:
            start = time.monotonic()
            process = subprocess.Popen([str(bundle / 'Contents/MacOS/Bowser')], env={**ENV, 'BOWSER_HOME': str(home)}, stdout=log, stderr=log)
            try:
                deadline = start + 15
                with socket.socket(socket.AF_UNIX) as client:
                    while True:
                        if process.poll() is not None: raise RuntimeError('Shell exited before ready')
                        if time.monotonic() > deadline: raise TimeoutError('Shell readiness')
                        try: client.connect(str(home / 'brain.sock')); break
                        except (FileNotFoundError, ConnectionRefusedError): time.sleep(.005)
                    client.settimeout(5)
                    while True:
                        size, = struct.unpack('>I', receive(client, 4))
                        if not 0 < size < 1_000_000: raise RuntimeError('Invalid startup frame')
                        message = json.loads(receive(client, size))
                        if message.get('op') == 'hello':
                            assert message.get('v') == 1 and isinstance(message.get('tabs'), list)
                            record('startup_shell_ready_ms', (time.monotonic() - start)*1000)
                            break
            finally: stop(process)


async def browser_startup(stage, work, output, record):
    import test_backend_host as fixture
    bundle = work / 'Performance.app'
    for count in (1, 100):
        for index in range(3):
            home = work / f'browser-{count}-{index}'; home.mkdir()
            (home / 'app').symlink_to(stage / 'runtime', target_is_directory=True)
            shutil.copy2(work / 'startup-0/registration.json', home / 'registration.json')
            (home / 'session.json').write_text(json.dumps(dict(tabs=[dict(url=f'http://127.0.0.1:1/fixture/{i}', profile='default') for i in range(count)], active=0)))
            with (output / f'browser-{count}-{index}.log').open('ab') as log:
                start = time.monotonic()
                process = subprocess.Popen([str(bundle / 'Contents/MacOS/Bowser')], env={**ENV, 'BOWSER_HOME': str(home)}, stdout=log, stderr=log)
                probes = []
                def observe(begin, end, actual, error):
                    probes.append(dict(start_ms=(begin-start)*1000, end_ms=(end-start)*1000,
                                       duration_ms=(end-begin)*1000, tabs=actual, error=error))
                try:
                    await wait_for_tabs(home / 'agent.sock', count, start + 20,
                                        lambda: process.poll() is not None, observe=observe)
                    record(f'startup_browser_{count}_tabs_ms', (time.monotonic()-start)*1000)
                finally:
                    (output / f'browser-{count}-{index}-probes.json').write_text(json.dumps(probes, indent=2))
                    stop(process)
                    endpoint = home / 'backend/host.sock'
                    if endpoint.exists():
                        await fixture.request(endpoint, dict(op='stop'))
                    if (home / 'brain.log').exists(): shutil.copy2(home / 'brain.log', output / f'browser-{count}-{index}-brain.log')


async def backend_workloads(stage, output, record):
    os.environ['BOWSER_TEST_RELEASE'] = str(stage / 'runtime/brain')
    import test_backend_host as fixture
    fixture.HOST = stage / 'runtime/bin/backend-host'
    for index in range(3):
        test = fixture.ReleaseTests()
        try:
            await test.asyncSetUp()
            record('startup_backend_ready_ms', test.launch_seconds * 1000)
            test.event(); await test.count(1)
            candidate = test.candidate()
            before = len(test.commands)
            start = time.monotonic()
            result = await test.control('update', runtime=str(candidate))
            elapsed = (time.monotonic() - start)*1000
            assert result.get('ok'), result
            record('backend_upgrade_total_ms', elapsed)
            record('backend_upgrade_pause_ms', result['handoff_ms'])
            test.event(); await test.count(2)
            assert test.connections == 1, 'Upgrade replaced the native connection'
            assert not any(c.get('op') in ('navigate', 'reload') for c in test.commands[before:])
        finally:
            if hasattr(test, 'home') and (test.home / 'host.log').exists():
                shutil.copy2(test.home / 'host.log', output / f'backend-{index}.log')
            if hasattr(test, 'process'): await test.asyncTearDown()


def offline_upgrade(stage, output, record):
    import test_apply_update as fixture
    fixture.TOOL = stage / 'runtime/bin/apply-update'
    for index in range(3):
        test = fixture.UpdateTests(); test.setUp()
        try:
            test.require_backup()
            # Fixed persistent-data workload, not a user's profile or a network cache.
            data = test.root / 'fixture-profile'; data.mkdir()
            for number in range(128): (data / str(number)).write_bytes(b'p' * (256*1024))
            start = time.monotonic()
            result = subprocess.run([str(fixture.TOOL), str(test.pending)], capture_output=True, text=True, timeout=30, env=ENV)
            elapsed = (time.monotonic() - start)*1000
            (output / f'offline-{index}.log').write_text(result.stdout + result.stderr)
            assert result.returncode == 0, result.stderr
            assert not test.pending.exists()
            assert json.loads((test.root / 'updates/progress.json').read_text())['phase'] == 'complete'
            snapshots = list((test.root / 'backups').glob('*/snapshot.json'))
            assert len(snapshots) == 1
            snapshot = json.loads(snapshots[0].read_text())
            entry = next(e for e in snapshot['entries'] if Path(e['target']).name == 'fixture-profile')
            assert len(entry['inventory']) == 129  # Directory plus every payload file.
            assert (snapshots[0].parent / entry['payload'] / '127').stat().st_size == 256*1024
            for key in ('runtime', 'bundle'):
                target = Path(test.manifest[key])
                assert (target / 'version').read_text() == 'new'
                assert (target.with_name(target.name + '.previous') / 'version').read_text() == 'old'
            record('offline_upgrade_backup_apply_ms', elapsed)
        finally: test.tearDown()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', type=Path, help='Existing bin/install --stage-only output')
    parser.add_argument('--output', type=Path, required=True, help='New artifact directory')
    parser.add_argument('--baseline', type=Path, help='Complete reference report.json (missing/incompatible reports fail)')
    parser.add_argument('--reference', action='store_true', help='Measure a base revision; budget violations are reported but only measurement failures affect exit status')
    args = parser.parse_args()
    if args.reference and args.baseline:
        parser.error('--reference and --baseline are mutually exclusive')
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=False)
    raw = output / 'samples.jsonl'; raw.touch()
    def record(metric, value):
        with raw.open('a') as file: file.write(json.dumps(dict(metric=metric, value=value)) + '\n')
    metadata = dict(
        schema=3, os=platform.mac_ver()[0], arch=platform.machine(),
        cpu=subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
        swift=subprocess.check_output(['swift', '--version'], text=True).strip(),
        source=os.environ.get('BOWSER_PERF_SOURCE', os.environ.get('GITHUB_SHA', 'local')),
        harness=os.environ.get('BOWSER_PERF_HARNESS'),
        comparison_session=os.environ.get('BOWSER_PERF_SESSION'), timestamp=time.time())
    failures = []
    os.environ.update({key: ENV[key] for key in ('BOWSER_TELEMETRY_DISABLED', 'BOWSER_API_ENDPOINT', 'BOWSER_NO_SPAWN')})
    try:
        with tempfile.TemporaryDirectory(prefix='bp.', dir='/tmp') as directory:
            work = Path(directory)
            stage = args.stage.resolve() if args.stage else None
            if stage is None:
                stage_file = work / 'stage-path'
                command([ROOT / 'bin/install', '--stage-only'], output / 'build.log', {**ENV, 'BOWSER_SIGN_IDENTITY': '-', 'BOWSER_STAGE_FILE': str(stage_file)})
                stage = Path(stage_file.read_text().strip())
            metadata['stage_version'] = (stage / 'runtime/VERSION').read_text().strip()
            shell_startup(stage, work, output, record)
            asyncio.run(browser_startup(stage, work, output, record))
            asyncio.run(backend_workloads(stage, output, record))
            offline_upgrade(stage, output, record)
            for name in ('A', 'B'):
                command([ROOT / 'bin/build-native-toolbar', work / f'{name}.bundle'], output / 'toolbar-build.log', {**ENV, 'BOWSER_SIGN_IDENTITY': '-'})
            home = work / 'swift-home'; home.mkdir()
            try:
                command(['swift', 'test', '-c', 'release', '--package-path', 'shell', '--filter', 'BrowserPerformanceTests', '--xunit-output', output / 'swift-results.xml'], output / 'swift.log', {**ENV, 'BOWSER_HOME': str(home), 'BOWSER_PERF': '1', 'BOWSER_PERF_RESULTS': str(raw), 'BOWSER_PERF_TOOLBAR_A': str(work / 'A.bundle'), 'BOWSER_PERF_TOOLBAR_B': str(work / 'B.bundle')})
            finally:
                if (home / 'diagnostics').exists():
                    shutil.copytree(home / 'diagnostics', output / 'navigation-diagnostics')
    except Exception:
        failures.append(traceback.format_exc())
    measurement_failures = failures.copy()
    baseline = None
    baseline_note = 'Reference measurement; absolute violations reported only.' if args.reference else 'Absolute budgets only; no baseline supplied.'
    metrics = {}
    try:
        budgets = json.loads((Path(__file__).with_name('budgets.json')).read_text())
        rows = [json.loads(line) for line in raw.read_text().splitlines()]
        # Validate sample completeness separately from performance thresholds.
        _, incomplete = evaluate(rows, {name: {**budget, 'max_p95': float('inf')}
                                        for name, budget in budgets.items()})
        measurement_failures += incomplete
        if args.baseline:
            try:
                previous = json.loads(args.baseline.read_text())
                baseline = reference_metrics(previous, metadata, budgets)
                baseline_note = f"Compared with reference {previous['environment']['source']} measured in session {metadata.get('comparison_session') or 'local'}."
            except Exception as error:
                baseline_note = f'Baseline comparison unavailable: {error}. Absolute budgets still enforced.'
                failures.append(baseline_note)
        metrics, gate_failures = evaluate(rows, budgets, baseline)
        failures += gate_failures
    except Exception:
        error = traceback.format_exc()
        measurement_failures.append(error)
        failures.append(error)
    report = dict(environment=metadata, metrics=metrics, failures=failures,
                  measurement_failures=measurement_failures, baseline=baseline_note)
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    heading = '# Browser performance reference' if args.reference else '# Browser performance'
    lines = [heading, '', f"Source: {metadata['source']}", '', baseline_note, '', '| Metric | Samples | p50 | p95 | Max | Limit |', '|---|---:|---:|---:|---:|---:|']
    for name, value in metrics.items():
        lines.append(f'| {name} | {value["samples"]} | {value["p50"]:.2f} | {value["p95"]:.2f} | {value["max"]:.2f} | {value["limit"]:.2f} |')
    status = 'PASS' if not failures else 'FAIL'
    if args.reference:
        status = 'REFERENCE INCOMPLETE' if measurement_failures else 'REFERENCE COMPLETE (candidate gates remain mandatory)'
    lines += ['', status, *failures]
    swift_log = output / 'swift.log'
    if swift_log.exists():
        lines += ['', *[line for line in swift_log.read_text(errors='replace').splitlines()
                        if line.startswith(('Cold navigation sample ', 'Toolbar adoption phases: '))]]
    phases = output / 'samples.phases.jsonl'
    if phases.exists():
        lines += ['', 'Activation and navigation phases:', '```jsonl', phases.read_text().rstrip(), '```']
    summary = '\n'.join(lines) + '\n'; (output / 'summary.md').write_text(summary)
    print(summary)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as file: file.write(summary)
    return bool(measurement_failures if args.reference else failures)

if __name__ == '__main__': sys.exit(main())

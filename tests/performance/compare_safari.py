#!/usr/bin/env python3
"""Same-machine, same-page Safari/Bowser rendering comparison (not native UI latency)."""
import argparse
import http.server
import json
from pathlib import Path
import platform
import plistlib
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import traceback
import urllib.error
import urllib.request
import uuid
from compare_report import summarize, gate
from run import ROOT, ENV, command, stop


class FixtureServer:
    def __init__(self):
        self.results = {}; self.pending = set(); self.condition = threading.Condition()
        owner = self
        page = Path(__file__).with_name('compare.html').read_bytes()
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                if not self.path.startswith('/fixture?'):
                    self.send_error(404); return
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Cache-Control', 'no-store')
                self.send_header('Content-Length', str(len(page)))
                self.end_headers(); self.wfile.write(page)
            def do_POST(self):
                try:
                    size = int(self.headers.get('Content-Length', '0'))
                    if self.path != '/result' or not 0 < size <= 100000: raise ValueError('Invalid body')
                    result = json.loads(self.rfile.read(size))
                    token = result['token']
                    with owner.condition:
                        if token not in owner.pending or token in owner.results: raise ValueError('Unknown/duplicate run')
                        owner.results[token] = result; owner.condition.notify_all()
                    self.send_response(204); self.end_headers()
                except (ValueError, KeyError): self.send_error(400)
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()
    def url(self, token):
        with self.condition: self.pending.add(token)
        return f'http://127.0.0.1:{self.server.server_port}/fixture?token={token}'
    def wait(self, token):
        with self.condition:
            if not self.condition.wait_for(lambda: token in self.results, timeout=30):
                raise TimeoutError('Fixture did not report; keep the desktop unlocked and the test window visible')
            self.pending.remove(token)
            return self.results.pop(token)
    def close(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(timeout=5)


class Safari:
    def __init__(self, output):
        self.output = output; self.session = None; self.process = None
    def request(self, method, path, body=None):
        request = urllib.request.Request(f'http://127.0.0.1:{self.port}{path}', method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={'Content-Type':'application/json'})
        try:
            with urllib.request.urlopen(request, timeout=30) as response: value = json.load(response)['value']
        except urllib.error.HTTPError as error:
            raise RuntimeError(error.read().decode()) from error
        return value
    def __enter__(self):
        with socket.socket() as probe:
            probe.bind(('127.0.0.1',0)); self.port = probe.getsockname()[1]
        self.log = (self.output / 'safaridriver.log').open('ab')
        self.process = subprocess.Popen(['/usr/bin/safaridriver','-p',str(self.port)], stdout=self.log, stderr=self.log)
        try:
            deadline = time.monotonic()+10
            while True:
                try: self.request('GET','/status'); break
                except urllib.error.URLError:
                    if time.monotonic()>deadline or self.process.poll() is not None: raise
                    time.sleep(.05)
            value = self.request('POST','/session',{'capabilities':{'alwaysMatch':{'browserName':'safari'}}})
            self.session = value['sessionId']; self.capabilities = value['capabilities']
            self.request('POST',self.path('/window/rect'),dict(x=30,y=30,width=1200,height=900))
            return self
        except Exception:
            self.__exit__(None,None,None); raise
    def path(self, suffix): return f'/session/{self.session}{suffix}'
    def navigate(self, url): self.request('POST',self.path('/url'),{'url':url})
    def __exit__(self, *args):
        try:
            if self.session: self.request('DELETE',self.path(''))
        finally:
            if self.process: stop(self.process)
            self.log.close()


class Bowser:
    def __init__(self, stage, output):
        self.stage=stage; self.output=output; self.process=None
    def tool(self, tool, **args):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(5); client.connect(str(self.home/'agent.sock'))
            client.sendall(json.dumps(dict(tool=tool,args=args)).encode()+b'\n')
            with client.makefile('rb') as stream: result=json.loads(stream.readline(1_000_000))
        if not result.get('ok'): raise RuntimeError(result)
        return result
    def __enter__(self):
        self.temp=tempfile.TemporaryDirectory(prefix='sc.',dir='/tmp'); self.root=Path(self.temp.name)
        self.home=self.root/'home'; self.home.mkdir()
        bundle=self.root/'BowserCompare.app'; shutil.copytree(self.stage/'bundle',bundle)
        path=bundle/'Contents/Info.plist'; plist=plistlib.loads(path.read_bytes())
        plist['CFBundleIdentifier']='com.foxwiseai.bowser.compare.'+uuid.uuid4().hex
        for key in ('BowserRuntimeDirectory','BowserChannel','BowserDevelopmentCheckout'): plist.pop(key,None)
        path.write_bytes(plistlib.dumps(plist))
        command(['codesign','--force','--deep','--sign','-',bundle],self.output/'bowser.log')
        (self.home/'app').symlink_to(self.stage/'runtime',target_is_directory=True)
        (self.home/'registration.json').write_text(json.dumps(dict(registrationID='compare-fixture',telemetryToken='fixture',request=dict(requestID=str(uuid.uuid4()),email='fixture@example.invalid',termsVersion='fixture',acceptedAt=0))))
        self.log=(self.output/'bowser.log').open('ab')
        self.process=subprocess.Popen([str(bundle/'Contents/MacOS/Bowser')],env={**ENV,'BOWSER_HOME':str(self.home)},stdout=self.log,stderr=self.log)
        try:
            deadline=time.monotonic()+20
            while True:
                if self.process.poll() is not None: raise RuntimeError('Bowser exited before ready')
                if time.monotonic()>deadline: raise TimeoutError('Bowser backend startup')
                try:
                    result=self.tool('list_tabs')
                    # A new blank window is not yet in persisted Session.tabs.
                    # Native protocol webview 0 resolves to its active tab.
                    self.active=result.get('active') or 0
                    break
                except (FileNotFoundError,ConnectionRefusedError): pass
                time.sleep(.02)
            return self
        except Exception:
            self.__exit__(None,None,None); raise
    def navigate(self,url):
        self.tool('page_eval',webview=self.active,js=f'setTimeout(() => location.href = {json.dumps(url)}, 0); null')
    def __exit__(self,*args):
        try:
            if self.process: stop(self.process)
            subprocess.run([str(self.stage/'runtime/bin/backend-host'),'--control',str(self.home),'stop'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
            if (self.home/'brain.log').exists():
                with (self.output/'bowser-brain.log').open('ab') as log: log.write((self.home/'brain.log').read_bytes())
        finally:
            if hasattr(self,'log'): self.log.close()
            self.temp.cleanup()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage',required=True,type=Path,help='bin/install --stage-only output')
    parser.add_argument('--output',required=True,type=Path,help='New artifact directory')
    parser.add_argument('--runs-per-batch',type=int,default=5)
    args=parser.parse_args()
    if args.runs_per_batch<3: parser.error('At least three measured runs per batch are required')
    stage=args.stage.resolve(); output=args.output.resolve(); output.mkdir(parents=True,exist_ok=False)
    runs=[]; failures=[]; server=FixtureServer()
    environment=dict(os=platform.mac_ver()[0],arch=platform.machine(),
        cpu=subprocess.check_output(['sysctl','-n','machdep.cpu.brand_string'],text=True).strip(),
        safari=subprocess.check_output(['/usr/bin/safaridriver','--version'],text=True).strip(),
        bowser=(stage/'runtime/VERSION').read_text().strip(),timestamp=time.time())
    try:
        # ABBA batches reduce browser-order/thermal bias. Each has one unmeasured warmup.
        for batch,browser in enumerate(('safari','bowser','bowser','safari')):
            print(f'Batch {batch+1}: {browser}',flush=True)
            with (Safari(output) if browser=='safari' else Bowser(stage,output)) as client:
                for index in range(args.runs_per_batch+1):
                    token=uuid.uuid4().hex
                    client.navigate(server.url(token))
                    result=server.wait(token)
                    result.update(browser=browser,batch=batch,warmup=index==0)
                    with (output/'raw.jsonl').open('a') as file: file.write(json.dumps(result)+'\n')
                    if result.get('error'): raise RuntimeError(result['error'])
                    if index: runs.append(result)
    except Exception: failures.append(traceback.format_exc())
    finally: server.close()
    summary={}; comparison={}
    try:
        summary,comparison=summarize(runs,args.runs_per_batch*2)
        budgets=json.loads(Path(__file__).with_name('safari-budgets.json').read_text())
        failures.extend(gate(comparison,budgets))
    except Exception: failures.append(traceback.format_exc())
    report=dict(environment=environment,summary=summary,comparison=comparison,failures=failures,
        scope='Identical local-page rendering only. Native cold startup, tab switching and omnibar input latency are not measured.')
    (output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    lines=['# Safari / Bowser comparison','',report['scope'],'',
        'Each value is the median of per-run p95s; 10 runs per browser by default. Lower is better.',
        '', '| Metric | Bowser | Safari | Bowser / Safari |','|---|---:|---:|---:|']
    for name,value in comparison.items():
        ratio=f"{value['ratio']:.2f}×" if value['ratio'] is not None else '—'
        lines.append(f"| {name} | {value['bowser']:.2f} | {value['safari']:.2f} | {ratio} |")
    lines+=['','PASS' if not failures else 'INCOMPLETE',*failures]
    text='\n'.join(lines)+'\n'; (output/'summary.md').write_text(text); print(text)
    return bool(failures)

if __name__=='__main__': raise SystemExit(main())

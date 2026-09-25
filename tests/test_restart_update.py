"""Desktop integration: quit, back up, replace, and relaunch only an isolated fixture."""
import json
import fcntl
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / 'shell/.build/debug/BowserRuntimeTool'

class RestartUpdateTests(unittest.TestCase):
    def test_restart_window_preserves_normal_quit_and_reopens_updated_fixture(self):
        self.exercise()

    def test_restart_does_not_force_quit_when_an_app_refuses(self):
        self.exercise(refuse=True)

    def exercise(self, refuse=False):
        with tempfile.TemporaryDirectory(prefix='bowser-restart.', dir='/tmp') as directory:
            root = Path(directory).resolve()
            app = root/'Fixture.app'
            contents = app/'Contents'
            (contents/'MacOS').mkdir(parents=True)
            info = dict(CFBundleIdentifier='com.bowser.restart-fixture.' + root.name,
                        CFBundleExecutable='Fixture', CFBundleName='Update Test',
                        CFBundlePackageType='APPL', CFBundleVersion='old', LSUIElement=True, RefuseQuit=refuse)
            (contents/'Info.plist').write_bytes(plistlib.dumps(info))
            source = root/'fixture.m'
            source.write_text(r'''
#import <AppKit/AppKit.h>
#import <sys/file.h>
#import <fcntl.h>
void record(NSString *event) {
  NSString *root = [[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent];
  NSString *path = [root stringByAppendingPathComponent:@"events"];
  NSString *line = [NSString stringWithFormat:@"%@:%@:%d\n", event, [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"], getpid()];
  NSFileHandle *f = [NSFileHandle fileHandleForWritingAtPath:path];
  if (!f) { [[NSData data] writeToFile:path atomically:YES]; f = [NSFileHandle fileHandleForWritingAtPath:path]; }
  [f seekToEndOfFile]; [f writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [f closeFile];
}
@interface Delegate : NSObject <NSApplicationDelegate> @end
@implementation Delegate
- (void)applicationDidFinishLaunching:(NSNotification *)n { record(@"launch"); }
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app {
  if ([[[NSBundle mainBundle] objectForInfoDictionaryKey:@"RefuseQuit"] boolValue]) { record(@"refused"); return NSTerminateCancel; }
  record(@"quit"); return NSTerminateNow;
}
@end
int main() { @autoreleasepool {
  NSString *root = [[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent];
  int ownerLock = open([[root stringByAppendingPathComponent:@"backend/owner.lock"] fileSystemRepresentation], O_CREAT | O_RDWR, 0600);
  flock(ownerLock, LOCK_EX);
  NSApplication *app = [NSApplication sharedApplication]; Delegate *d = [Delegate new]; app.delegate = d;
  [app setActivationPolicy:NSApplicationActivationPolicyAccessory]; [app run];
} return 0; }
''')
            subprocess.run(['clang', '-framework', 'AppKit', str(source), '-o', str(contents/'MacOS/Fixture')], check=True, capture_output=True)
            stage = root/'stage'
            shutil.copytree(app, stage/'bundle')
            info['CFBundleVersion'] = 'new'
            (stage/'bundle/Contents/Info.plist').write_bytes(plistlib.dumps(info))
            (stage/'runtime').mkdir(); (root/'runtime').mkdir()
            pending = root/'updates/pending.json'; pending.parent.mkdir()
            pending.write_text(json.dumps(dict(home=str(root), bundle=str(app), runtime=str(root/'runtime'),
                                               stage=str(stage), saved_apps=str(root/'saved-apps'), backup_required=True)))
            (root/'backend').mkdir()
            helper = None
            watcher = None
            try:
                subprocess.run(['/usr/bin/open', '-n', str(app)], check=True)
                deadline = time.monotonic()+10
                while not (root/'events').exists() and time.monotonic()<deadline: time.sleep(.05)
                self.assertTrue((root/'events').exists(), 'Fixture must launch before restart')
                watcher = subprocess.Popen([str(TOOL), 'apply-update', str(pending), '--wait'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                deadline = time.monotonic()+5
                while not (root/'updates/progress.json').exists() and time.monotonic()<deadline: time.sleep(.05)
                self.assertTrue((root/'updates/progress.json').exists(), 'Background watcher must reach its waiting phase')
                time.sleep(.3)
                with (root/'updates/restart.lock').open('a') as restart_lock:
                    try:
                        fcntl.flock(restart_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        self.fail('Background watcher retained the coordinator lock while sleeping')
                    fcntl.flock(restart_lock, fcntl.LOCK_UN)
                helper = subprocess.Popen([str(TOOL), 'apply-update', str(pending), '--restart-ui'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                if refuse:
                    deadline = time.monotonic()+5
                    while 'refused:' not in (root/'events').read_text() and time.monotonic()<deadline: time.sleep(.05)
                    self.assertIn('refused:old:', (root/'events').read_text())
                    self.assertIsNone(helper.poll())
                    self.assertTrue(pending.exists())
                    self.assertEqual(plistlib.loads((contents/'Info.plist').read_bytes())['CFBundleVersion'], 'old')
                    self.assertFalse((root/'backups').exists())
                    return
                try:
                    out, err = helper.communicate(timeout=30)
                except subprocess.TimeoutExpired:
                    self.fail('Coordinator timed out: ' + (root/'events').read_text() + ' progress=' + (root/'updates/progress.json').read_text())
                self.assertEqual(helper.returncode, 0, out+err)
                deadline = time.monotonic()+5
                while 'launch:new:' not in (root/'events').read_text() and time.monotonic()<deadline: time.sleep(.05)
                events = (root/'events').read_text()
                self.assertIn('quit:old:', events)
                self.assertIn('launch:new:', events, 'coordinator=' + out + err + ' files=' + repr(list(root.rglob('events'))))
                self.assertFalse(pending.exists())
                self.assertEqual(json.loads((root/'updates/progress.json').read_text())['phase'], 'complete')
                self.assertEqual(len(list((root/'backups').glob('*/snapshot.json'))), 1)
            finally:
                if watcher:
                    if watcher.poll() is None: watcher.terminate()
                    watcher.communicate(timeout=5)
                if helper:
                    if helper.poll() is None: helper.kill()
                    helper.communicate()
                if (root/'events').exists():
                    for line in (root/'events').read_text().splitlines():
                        try: os.kill(int(line.rsplit(':', 1)[1]), signal.SIGTERM)
                        except ProcessLookupError: pass

if __name__ == '__main__': unittest.main()

"""Test the native updater executable, not an imported duplicate implementation."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / 'shell/.build/debug/BowserRuntimeTool'

class UpdateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Apple kills copied platform binaries, so compile a local sleeper.
        cls.sleeper = Path('/tmp/bu-sleeper')
        subprocess.run(['/usr/bin/cc', '-O2', '-o', str(cls.sleeper), '-x', 'c', '-'],
                       input='#include <unistd.h>\nint main(void){for(;;)pause();}', text=True, check=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='bu.', dir='/tmp')
        self.root = Path(self.temp.name)
        self.pending = self.root / 'updates/pending.json'
        self.pending.parent.mkdir()
        self.manifest = dict(saved_apps=str(self.root/"saved-apps"), home=str(self.root), stage=str(self.root/'stage'), runtime=str(self.root/'runtime'), bundle=str(self.root/'Bowser.app'))
        for key in ('runtime','bundle'):
            target = Path(self.manifest[key]); target.mkdir(); (target/'version').write_text('old')
            source = self.root/'stage'/key; source.mkdir(parents=True); (source/'version').write_text('new')
        self.pending.write_text(json.dumps(self.manifest))

    def tearDown(self): self.temp.cleanup()

    def run_tool(self, *args):
        return subprocess.run([str(TOOL), *map(str,args)], capture_output=True, text=True, timeout=15)

    def test_activation_preserves_previous_pair(self):
        result = self.run_tool('apply-update', self.pending)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(self.pending.exists())
        progress = json.loads((self.pending.parent/'progress.json').read_text())
        self.assertEqual(progress['phase'], 'complete')
        self.assertEqual(progress['stage'], str(self.root/'stage'))
        self.assertEqual(progress['bundle'], self.manifest['bundle'])
        for key in ('runtime','bundle'):
            target = Path(self.manifest[key])
            self.assertEqual((target/'version').read_text(),'new')
            self.assertEqual((target.with_name(target.name+'.previous')/'version').read_text(),'old')

    def test_owner_lock_blocks_activation(self):
        (self.root/'backend').mkdir()
        with open(self.root/'backend/owner.lock','w') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX)
            result = self.run_tool('apply-update',self.pending)
            self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(self.pending.exists())
        self.assertEqual(json.loads((self.pending.parent/'progress.json').read_text())['phase'], 'waiting')
        self.assertEqual((self.root/'runtime/version').read_text(),'old')

    def require_backup(self):
        self.manifest['backup_required'] = True
        self.pending.write_text(json.dumps(self.manifest))
        (self.root/'session.json').write_text('real session')

    def test_offline_update_backs_up_and_restores_only_user_data(self):
        self.require_backup()
        result = self.run_tool('apply-update', self.pending)
        self.assertEqual(result.returncode, 0, result.stderr)
        snapshots = list((self.root/'backups').glob('*/snapshot.json'))
        self.assertEqual(len(snapshots), 1)
        snapshot = snapshots[0].parent
        (self.root/'session.json').write_text('changed session')
        (self.root/'new-profile.json').write_text('new data')
        result = self.run_tool('restore-backup', snapshot)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root/'session.json').read_text(), 'real session')
        self.assertEqual((self.root/'runtime/version').read_text(), 'new')
        self.assertEqual((self.root/'Bowser.app/version').read_text(), 'new')
        self.assertFalse((self.root/'new-profile.json').exists())
        self.assertEqual(len(list((self.root/'backups').glob('*/snapshot.json'))), 2)

    def test_incremental_snapshot_reuses_only_unchanged_file_checksums(self):
        self.require_backup()
        (self.root/'recovery').mkdir()
        (self.root/'recovery/archive').write_text('old recovery archive')
        def update():
            self.pending.write_text(json.dumps(self.manifest))
            result = self.run_tool('apply-update', self.pending)
            self.assertEqual(result.returncode, 0, result.stderr)
            snapshots = sorted((self.root/'backups').glob('*/snapshot.json'), key=lambda p: p.stat().st_mtime_ns)
            doc = json.loads(snapshots[-1].read_text())
            self.assertFalse(any(Path(e['target']).name == 'recovery' for e in doc['entries']))
            return next(e for e in doc['entries'] if Path(e['target']).name == 'session.json')
        first = update()
        self.assertEqual(first['reused_checksums'], 0)
        second = update()
        self.assertEqual(second['reused_checksums'], 1)
        session = self.root/'session.json'
        before = session.stat()
        session.write_text('fake session')  # Same size, restored mtime: ctime must catch it.
        os.utime(session, ns=(before.st_atime_ns, before.st_mtime_ns))
        third = update()
        self.assertEqual(third['reused_checksums'], 0)
        self.assertNotEqual(third['inventory'], first['inventory'])

    def test_webkit_network_cache_is_excluded_but_offline_storage_is_kept(self):
        self.require_backup()
        root = self.root/'WebKit'
        data = root/'com.foxwiseai.bowser/WebsiteDataStore/profile'
        for name in ('NetworkCache', 'Origins/CacheStorage', 'Origins/IndexedDB'):
            (data/name).mkdir(parents=True)
            (data/name/'data').write_text(name)
        self.manifest['home'] = str(root)
        self.pending.write_text(json.dumps(self.manifest))
        result = self.run_tool('apply-update', self.pending)
        self.assertEqual(result.returncode, 0, result.stderr)
        doc = json.loads(next((root/'backups').glob('*/snapshot.json')).read_text())
        entry = next(e for e in doc['entries'] if Path(e['target']).name == 'com.foxwiseai.bowser')
        self.assertFalse(any('NetworkCache' in key for key in entry['inventory']))
        self.assertTrue(any('CacheStorage/data' in key for key in entry['inventory']))
        self.assertTrue(any('IndexedDB/data' in key for key in entry['inventory']))

    def test_legacy_full_snapshot_still_restores_executables(self):
        import hashlib
        self.require_backup()
        self.assertEqual(self.run_tool('apply-update', self.pending).returncode, 0)
        snapshot = next((self.root/'backups').glob('*/snapshot.json')).parent
        doc = json.loads((snapshot/'snapshot.json').read_text())
        doc['format'] = 1
        for key in ('runtime', 'bundle'):
            payload = str(len(doc['entries']))
            (snapshot/payload).mkdir()
            (snapshot/payload/'version').write_text('legacy')
            doc['entries'].append(dict(target=self.manifest[key], payload=payload,
                inventory={'.': 'directory', './version': hashlib.sha256(b'legacy').hexdigest()}))
        (snapshot/'snapshot.json').write_text(json.dumps(doc))
        result = self.run_tool('restore-backup', snapshot)
        self.assertEqual(result.returncode, 0, result.stderr)
        for key in ('runtime', 'bundle'):
            self.assertEqual((Path(self.manifest[key])/'version').read_text(), 'legacy')

    def test_corrupt_backup_refuses_restore_without_changes(self):
        self.require_backup()
        result = self.run_tool('apply-update', self.pending)
        self.assertEqual(result.returncode, 0, result.stderr)
        snapshot = next((self.root/'backups').glob('*/snapshot.json')).parent
        doc = json.loads((snapshot/'snapshot.json').read_text())
        entry = next(e for e in doc['entries'] if e['target'].endswith('/session.json'))
        (snapshot/entry['payload']).write_text('corrupted')
        (self.root/'session.json').write_text('current')
        result = self.run_tool('restore-backup', snapshot)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root/'session.json').read_text(), 'current')
        self.assertEqual((self.root/'runtime/version').read_text(), 'new')

    def test_failed_backup_does_not_activate(self):
        self.require_backup()
        (self.root/'backups').write_text('not a directory')
        result = self.run_tool('apply-update', self.pending)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.pending.exists())
        self.assertEqual((self.root/'runtime/version').read_text(), 'old')
        progress = json.loads((self.pending.parent/'progress.json').read_text())
        self.assertEqual(progress['phase'], 'failed')
        self.assertTrue(progress['error'])

    def test_public_live_opt_in_keeps_backup_and_offline_installs_override_it(self):
        for offline, partial, allowed in [('0', False, True), ('1', False, False), ('0', True, False)]:
            with self.subTest(offline=offline, partial=partial):
                self.pending.unlink(missing_ok=True)
                result = subprocess.run([str(TOOL), 'publish', str(self.pending), str(self.root/'stage'),
                    str(self.root/'runtime'), str(self.root/'Bowser.app'), str(int(partial)), '0', '--live'],
                    env={**os.environ, 'BOWSER_OFFLINE_UPDATE': offline}, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                manifest = json.loads(self.pending.read_text())
                self.assertEqual(manifest['live_allowed'], allowed)
                self.assertTrue(manifest['backup_required'])

    def test_cancel_does_not_discard_an_update_that_may_have_live_components(self):
        self.manifest.update(live_allowed=True, backup_required=True)
        self.pending.write_text(json.dumps(self.manifest))
        result = self.run_tool('cancel-update', self.root)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.pending.exists())
        self.assertTrue((self.root/'stage').exists())

    def test_live_host_refusal_keeps_old_files_and_defers_to_restart(self):
        import socket
        import struct
        import threading
        self.manifest.update(live_allowed=True, backup_required=True)
        self.pending.write_text(json.dumps(self.manifest))
        (self.root/'backend').mkdir()
        (self.root/'stage/runtime/HANDOFF.json').write_text('{"protocol":1,"state_schema":5}')
        endpoint = socket.socket(socket.AF_UNIX)
        endpoint.bind(str(self.root/'backend/host.sock'))
        endpoint.listen()
        endpoint.settimeout(10)
        operations = []
        def reject():
            with endpoint.accept()[0] as peer:
                size = struct.unpack('>I', peer.recv(4))[0]
                operations.append(json.loads(peer.recv(size))['op'])
                payload = json.dumps({'ok': True, 'live_updates': False}).encode()
                peer.sendall(struct.pack('>I', len(payload)) + payload)
        server = threading.Thread(target=reject)
        server.start()
        try:
            with open(self.root/'data-use.lock', 'w') as lock:
                fcntl.flock(lock, fcntl.LOCK_SH)
                result = self.run_tool('apply-update', self.pending)
            server.join(10)
            self.assertFalse(server.is_alive())
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(operations, ['status'])
            manifest = json.loads(self.pending.read_text())
            self.assertNotIn('backend_applied', manifest)
            self.assertIn('restart', manifest['deferred_reason'])
            self.assertEqual((self.root/'runtime/version').read_text(), 'old')
            self.assertFalse((self.root/'backups').exists())
            # Quit finishes the update, still taking the verified backup.
            self.assertEqual(self.run_tool('apply-update', self.pending).returncode, 0)
            self.assertTrue(list((self.root/'backups').glob('*/snapshot.json')))
        finally:
            endpoint.close()

    def test_production_publish_also_requires_verified_backup(self):
        self.pending.unlink()
        result = self.run_tool('publish', self.pending, self.root/'stage', self.root/'runtime', self.root/'Bowser.app', 0, 0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(self.pending.read_text())['backup_required'])

    def test_browser_data_lock_defers_update(self):
        self.require_backup()
        with open(self.root/'data-use.lock', 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_SH)
            result = self.run_tool('apply-update', self.pending)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.pending.exists())
        self.assertFalse((self.root/'backups').exists())

    def spawn_launch(self, marked=True):
        """A launch parked at the gate: runs from the bundle path, holds no locks."""
        import shutil
        waiter = self.root/'Bowser.app/waiter'
        shutil.copy(self.sleeper, waiter)
        process = subprocess.Popen([str(waiter)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        import time
        end = time.monotonic() + 3
        while time.monotonic() < end:
            if str(waiter) in subprocess.run(['/bin/ps', '-axo', 'comm='], capture_output=True, text=True).stdout: break
            time.sleep(0.02)
        if marked:
            waiting = self.root/'launch-waiting'
            waiting.mkdir(exist_ok=True)
            (waiting/str(process.pid)).touch()
        return process

    def test_parked_launch_neither_blocks_nor_dies_with_update(self):
        self.require_backup()
        launch = self.spawn_launch()
        try:
            result = self.run_tool('apply-update', self.pending)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(self.pending.exists())
            self.assertTrue((self.root/'backups').exists())
            self.assertEqual((self.root/'Bowser.app/version').read_text(), 'new')
            self.assertIsNone(launch.poll())
        finally:
            launch.terminate(); launch.wait(timeout=3)

    def test_unmarked_process_from_bundle_still_defers_update(self):
        self.require_backup()
        launch = self.spawn_launch(marked=False)
        try:
            result = self.run_tool('apply-update', self.pending)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(self.pending.exists())
            self.assertEqual((self.root/'Bowser.app/version').read_text(), 'old')
        finally:
            launch.terminate(); launch.wait(timeout=3)

    def test_stale_launch_markers_are_pruned(self):
        self.require_backup()
        waiting = self.root/'launch-waiting'
        waiting.mkdir()
        stale = waiting/'999999'
        stale.touch()
        result = self.run_tool('apply-update', self.pending)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(stale.exists())
        self.assertFalse(self.pending.exists())

    def test_staging_never_attempts_a_live_backend_update(self):
        self.require_backup()
        (self.root/'backend').mkdir()
        (self.root/'backend/host.sock').touch()
        (self.root/'stage/runtime/HANDOFF.json').write_text('{}')
        with open(self.root/'backend/owner.lock', 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            result = self.run_tool('apply-update', self.pending)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('live_attempt_at', json.loads(self.pending.read_text()))
        self.assertFalse((self.root/'backups').exists())

    def test_staging_update_preserves_production_runtime_pointer(self):
        self.require_backup()
        self.manifest['channel'] = 'staging'
        self.pending.write_text(json.dumps(self.manifest))
        (self.root/'backend').mkdir()
        pointer = self.root/'backend/active.json'
        pointer.write_text(json.dumps({'runtime': str(self.root/'prod-runtime')}))
        result = self.run_tool('apply-update', self.pending)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(pointer.read_text())['runtime'], str(self.root/'prod-runtime'))
        snapshot = next((self.root/'backups').glob('*/snapshot.json')).parent
        doc = json.loads((snapshot/'snapshot.json').read_text())
        self.assertFalse(any(Path(e['target']).resolve() == (self.root/'runtime').resolve() for e in doc['entries']))

    def test_production_runtime_pin_refuses_active_backend_and_releases_lock(self):
        runtime = self.root/'prod-runtime/brain/bin'
        runtime.mkdir(parents=True)
        (runtime/'bowser_brain').touch()
        result = self.run_tool('pin-production-runtime', self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        pointer = self.root/'backend/active.json'
        self.assertEqual(json.loads(pointer.read_text())['runtime'], str(self.root/'prod-runtime'))
        with open(self.root/'backend/owner.lock', 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_tool('pin-production-runtime', self.root)
            self.assertNotEqual(result.returncode, 0)

    def test_publish_detects_staging_and_preserves_backup_requirement(self):
        import plistlib
        (self.root/'stage/bundle/Contents').mkdir()
        (self.root/'stage/bundle/Contents/Info.plist').write_bytes(plistlib.dumps({'BowserChannel':'staging'}))
        self.pending.unlink()
        result = self.run_tool('publish', self.pending, self.root/'stage', self.root/'runtime', self.root/'Bowser.app', 0, 0, '--live')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(self.pending.read_text())['backup_required'])
        self.assertFalse(json.loads(self.pending.read_text())['live_allowed'])

    def test_recovery_refuses_running_browser_and_pending_update(self):
        self.require_backup()
        self.assertEqual(self.run_tool('apply-update', self.pending).returncode, 0)
        snapshot = next((self.root/'backups').glob('*/snapshot.json')).parent
        with open(self.root/'data-use.lock', 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_SH)
            self.assertNotEqual(self.run_tool('restore-backup', snapshot).returncode, 0)
        self.pending.write_text(json.dumps(self.manifest))
        self.assertNotEqual(self.run_tool('restore-backup', snapshot).returncode, 0)
        result = self.run_tool('cancel-update', self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.pending.exists())

    def test_failed_second_swap_rolls_back_runtime(self):
        # Missing destination parent makes the second filesystem move fail.
        self.manifest['bundle'] = str(self.root/'absent/Bowser.app')
        self.pending.write_text(json.dumps(self.manifest))
        result=self.run_tool('apply-update',self.pending)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual((self.root/'runtime/version').read_text(),'old')

        self.assertEqual((self.root/'stage/runtime/version').read_text(),'new')
        self.assertEqual((self.root/'stage/bundle/version').read_text(),'new')
        self.assertTrue(self.pending.exists())

    def test_backup_excludes_executables_and_preserves_user_mod_symlinks(self):
        self.require_backup()
        active = self.root/'releases/active'
        active.mkdir(parents=True)
        (active/'version').write_text('last-live-backend')
        (self.root/'backend').mkdir()
        (self.root/'backend/active.json').write_text(json.dumps({'runtime': str(active)}))
        (self.root/'mods').mkdir()
        (self.root/'mods/external').symlink_to('/does-not-exist')
        result = self.run_tool('apply-update', self.pending)
        self.assertEqual(result.returncode, 0, result.stderr)
        snapshot = next((self.root/'backups').glob('*/snapshot.json')).parent
        doc = json.loads((snapshot/'snapshot.json').read_text())
        self.assertFalse(any(Path(e['target']).name in ('runtime', 'Bowser.app', 'releases', 'backend') for e in doc['entries']))
        mods = next(e for e in doc['entries'] if Path(e['target']).resolve() == (self.root/'mods').resolve())
        self.assertEqual(os.readlink(snapshot/mods['payload']/'external'), '/does-not-exist')
        self.assertFalse(any(e['target'].endswith('/stage') for e in doc['entries']))

    def test_partial_updates_preserve_previously_staged_components(self):
        for shell_only in (True,False):
            with self.subTest(shell_only=shell_only):
                old=self.root/('old'+str(shell_only)); new=self.root/('new'+str(shell_only))
                for stage in (old,new):
                    (stage/'runtime/brain').mkdir(parents=True)
                    (stage/'runtime/brain/version').write_text(stage.name)
                (old/'bundle').mkdir(); (old/'bundle/version').write_text('old-shell')
                self.pending.write_text(json.dumps(dict(self.manifest,stage=str(old))))
                result=self.run_tool('publish',self.pending,new,self.manifest['runtime'],self.manifest['bundle'],int(shell_only),int(not shell_only))
                self.assertEqual(result.returncode,0,result.stderr)
                if shell_only: self.assertEqual((new/'runtime/brain/version').read_text(),old.name)
                else: self.assertEqual((new/'bundle/version').read_text(),'old-shell')
                self.assertFalse(old.exists())

    def test_detach_survives_launcher_and_closes_inherited_stdio(self):
        marker=self.root/'finished'
        result=self.run_tool('detach',self.root/'child.log','TEST_VALUE=works','--','/bin/sh','-c','sleep 0.2; printf "$TEST_VALUE" > "$1"','fixture',marker,'--restart-ui')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(result.stdout.strip().isdigit())
        import time
        end=time.monotonic()+3
        while not marker.exists() and time.monotonic()<end: time.sleep(.02)
        self.assertEqual(marker.read_text(),'works')

    def test_refresh_retires_only_this_homes_watcher(self):
        import shutil, time
        homes = [self.root/'first', self.root/'second']
        processes=[]; locks=[]
        try:
            for root in homes:
                (root/'updates').mkdir(parents=True); (root/'backend').mkdir()
                lock=open(root/'backend/owner.lock','w'); fcntl.flock(lock,fcntl.LOCK_EX); locks.append(lock)
                pending=root/'updates/pending.json'
                pending.write_text(json.dumps(dict(self.manifest,home=str(root))))
                executable=root/'updates/apply-update'; shutil.copy2(TOOL,executable)
                processes.append(subprocess.Popen([str(executable),str(pending),'--wait'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL))
                end=time.monotonic()+3
                while not (root/'updates/pending.watcher.lock').exists() and time.monotonic()<end: time.sleep(.02)
                self.assertTrue((root/'updates/pending.watcher.lock').exists())
            result=self.run_tool('apply-update',homes[0]/'updates/pending.json','--refresh-watcher')
            self.assertEqual(result.returncode,0,result.stderr)
            processes[0].wait(timeout=3)
            self.assertIsNone(processes[1].poll())
        finally:
            for process in processes:
                if process.poll() is None: process.terminate()
                process.wait(timeout=3)
            for lock in locks: lock.close()

    def test_mcp_forwards_run_and_site_context_and_returns_images(self):
        import socket, threading
        endpoint=self.root/'agent.sock'
        server=socket.socket(socket.AF_UNIX); server.bind(str(endpoint)); server.listen(1)
        received=[]
        def reply():
            peer,_=server.accept()
            with peer:
                reader=peer.makefile('rb'); received.append(json.loads(reader.readline()))
                peer.sendall(b'{"ok":true,"image":"YWJj","mimeType":"image/png"}\n')
                reader.close()
        thread=threading.Thread(target=reply,daemon=True); thread.start()
        try:
            message=json.dumps(dict(jsonrpc='2.0',id=7,method='tools/call',params=dict(name='page_screenshot',arguments={'webview': 7})))+'\n'
            result=subprocess.run([str(TOOL),'bowser-mcp-bridge'],input=message,text=True,capture_output=True,timeout=5,env={**os.environ,'PATH':'/nonexistent','BOWSER_HOME':str(self.root),'BOWSER_SITE_APP_ID':'fixture','BOWSER_MODSMITH_RUN':'run1'})
            self.assertEqual(result.returncode,0,result.stderr)
            thread.join(timeout=2)
            self.assertEqual(received,[dict(tool='page_screenshot',args=dict(site_app='fixture', webview=7),run='run1')])
            response=json.loads(result.stdout)['result']
            self.assertFalse(response['isError'])
            self.assertEqual(response['content'][1],dict(type='image',data='YWJj',mimeType='image/png'))
        finally: server.close()

    def test_mcp_initialization_and_tool_catalog_without_python(self):
        message='{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n'
        result=subprocess.run([str(TOOL),'bowser-mcp-bridge'],input=message,text=True,capture_output=True,timeout=3,env={**os.environ,'PATH':'/nonexistent'})
        self.assertEqual(result.returncode,0,result.stderr)
        names={tool['name'] for tool in json.loads(result.stdout)['result']['tools']}
        self.assertIn('native_screenshot',names)
        self.assertIn('page_screenshot',names)
        runtime_tools = {tool['name']: tool for tool in json.loads(result.stdout)['result']['tools']}
        agent_tools = {tool['name']: tool for tool in json.loads((ROOT/'beam/priv/ai-tools.json').read_text())}
        self.assertEqual(runtime_tools['page_screenshot'], agent_tools['page_screenshot'])
        self.assertEqual(runtime_tools['ask_user'], agent_tools['ask_user'])
        self.assertEqual(runtime_tools['discover_native_tools'], agent_tools['discover_native_tools'])
        self.assertIn('put_mod',names)

if __name__=='__main__': unittest.main()

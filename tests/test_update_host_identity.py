"""Release restart classification: changes to live components versus host files."""
import importlib.machinery
import importlib.util
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader('host_identity', str(ROOT/'bin/update-host-identity'))
spec = importlib.util.spec_from_loader(loader.name, loader)
identity = importlib.util.module_from_spec(spec)
loader.exec_module(identity)


class HostIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.app = self.root/'Bowser.app'
        self.entitlements = self.root/'entitlements.plist'
        self.entitlements.write_text('sandbox exceptions')
        self.write('Info.plist', plistlib.dumps({'CFBundleVersion': '100', 'CFBundleShortVersionString': '1', 'CFBundleIdentifier': 'bowser', 'BowserLiveUpdates': 1}))
        self.write('MacOS/Bowser', self.macho(1))
        self.write('Resources/runtime/bin/backend-host', self.macho(2))
        self.write('Resources/runtime/HANDOFF.json', b'{"protocol":1,"state_schema":5}')
        self.write('Frameworks/SurfaceKit.dylib', self.macho(3))

    def tearDown(self):
        self.temp.cleanup()

    def write(self, relative, data):
        path = self.app/'Contents'/relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def fingerprint(self):
        return identity.host_identity(self.app, self.entitlements)

    @staticmethod
    def macho(value):
        return struct.pack('<8I', 0xFEEDFACF, 0, 0, 0, 1, 24, 0, 0) + struct.pack('<2I', 0x1B, 24) + bytes([value])*16

    def test_live_components_versions_and_signing_timestamps_do_not_change_host(self):
        before = self.fingerprint()
        for relative in ('Resources/CommandToolbar.bundle/Contents/MacOS/CommandToolbar',
                         'Resources/SurfaceRenderer.bundle/Contents/MacOS/SurfaceRenderer',
                         'Resources/runtime/brain/bin/bowser_brain', 'Resources/runtime/VERSION', '_CodeSignature/CodeResources'):
            self.write(relative, b'new version')
        path = self.app/'Contents/Info.plist'
        info = plistlib.loads(path.read_bytes())
        info.update(CFBundleVersion='200', CFBundleShortVersionString='2', BowserHostIdentity=before, BowserDevelopmentFingerprint='changed-checkout')
        path.write_bytes(plistlib.dumps(info))
        self.write('MacOS/Bowser', self.macho(1) + b'different signature timestamp')
        self.assertEqual(before, self.fingerprint())

    def test_host_helpers_shared_state_and_resources_require_restart(self):
        for relative in ('MacOS/Bowser', 'Resources/runtime/bin/backend-host', 'Frameworks/SurfaceKit.dylib',
                         'Resources/runtime/HANDOFF.json', 'Resources/AppIcon.icns', 'Resources/runtime/bin/bowser'):
            with self.subTest(relative=relative):
                before = self.fingerprint()
                self.write(relative, self.macho(4))
                self.assertNotEqual(before, self.fingerprint())
        before = self.fingerprint()
        self.entitlements.write_text('different exceptions')
        self.assertNotEqual(before, self.fingerprint())

    def test_external_runtime_has_same_host_identity_as_bundled(self):
        import shutil
        before = self.fingerprint()
        runtime = self.root/'runtime'
        shutil.move(self.app/'Contents/Resources/runtime', runtime)
        self.assertEqual(before, identity.host_identity(self.app, self.entitlements, runtime))
        (runtime/'bin/backend-host').write_bytes(self.macho(8))
        self.assertNotEqual(before, identity.host_identity(self.app, self.entitlements, runtime))

    def test_unidentified_code_and_symlinks_fail_closed(self):
        self.write('MacOS/Bowser', struct.pack('<8I', 0xFEEDFACF, 0, 0, 0, 0, 0, 0, 0))
        with self.assertRaises(ValueError): self.fingerprint()
        self.write('MacOS/Bowser', self.macho(1))
        (self.app/'Contents/linked').symlink_to(self.entitlements)
        with self.assertRaises(ValueError): self.fingerprint()


if __name__ == '__main__':
    unittest.main()

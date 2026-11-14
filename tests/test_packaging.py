import pathlib
import plistlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class PackagingTests(unittest.TestCase):
    def test_manifest_identity_and_transport(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / 'Info.plist'
            subprocess.run(['python3', str(ROOT / 'scripts/make_plist.py'), str(path), '0.1.0', '17'], check=True)
            p = plistlib.loads(path.read_bytes())
        self.assertEqual(p['CFBundleIdentifier'], 'com.huowenlong.longblog.macos')
        self.assertEqual(p['CFBundleShortVersionString'], '0.1.0')
        self.assertEqual(p['CFBundleVersion'], '17')
        self.assertEqual(p['LSMinimumSystemVersion'], '14.0')
        self.assertFalse(p['NSAppTransportSecurity']['NSAllowsArbitraryLoads'])

    def test_clean_universal_build(self):
        script = (ROOT / 'scripts/build.sh').read_text()
        self.assertIn('for ARCH in arm64 x86_64', script)
        self.assertIn('lipo "$APP/Contents/MacOS/longBlog" -verify_arch arm64 x86_64', script)
        self.assertIn('rm -rf "$BUILD/obj"', script)
        self.assertIn('codesign --verify --deep --strict', script)
        self.assertIn('hdiutil verify', script)
        self.assertIn('"$BUILD/CoreFixtures"', script)

    def test_actions_limits_permissions_and_real_smoke_test(self):
        workflow = (ROOT / '.github/workflows/macos.yml').read_text()
        self.assertIn('runs-on: macos-15', workflow)
        self.assertIn('timeout-minutes: 30', workflow)
        self.assertIn('--smoke-test --screenshot', workflow)
        self.assertIn('contents: read', workflow)
        self.assertIn('if-no-files-found: error', workflow)
        self.assertIn('pull_request:', workflow)

    def test_offline_licenses_bundled(self):
        for name in ['Marked-LICENSE.md', 'KaTeX-LICENSE.txt', 'Mermaid-LICENSE.txt', 'Boxicons-LICENSE.txt']:
            self.assertGreater((ROOT / 'Resources/Reader/vendor' / name).stat().st_size, 10)

    def test_ai_requests_never_follow_redirects_or_auto_retry(self):
        source = (ROOT / 'Sources/LongBlog/AI/AIWritingService.swift').read_text()
        self.assertIn('completionHandler(nil)', source)
        self.assertIn('URLSessionConfiguration.ephemeral', source)
        self.assertIn('Task.checkCancellation()', source)
        self.assertIn('guard done || stopped', source)
        self.assertIn('throw AIRequestError.tooLarge', source)
        self.assertNotIn('print(key)', source)


if __name__ == '__main__':
    unittest.main()

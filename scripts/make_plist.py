#!/usr/bin/env python3
"""Generate the bundle manifest; no real credentials or deployment endpoints."""
import plistlib
import sys
from pathlib import Path

path, version, build = sys.argv[1:]
manifest = {
    'CFBundleDevelopmentRegion': 'zh_CN',
    'CFBundleLocalizations': ['zh_CN', 'en'],
    'CFBundleExecutable': 'longBlog',
    'CFBundleIdentifier': 'com.huowenlong.longblog.macos',
    'CFBundleName': 'longBlog',
    'CFBundleDisplayName': 'longBlog',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': version,
    'CFBundleVersion': build,
    'CFBundleIconFile': 'AppIcon',
    'NSHighResolutionCapable': True,
    'NSPrincipalClass': 'NSApplication',
    'NSSupportsAutomaticGraphicsSwitching': True,
    'LSMinimumSystemVersion': '14.0',
    'NSHumanReadableCopyright': 'longBlog contributors. Third-party licenses bundled in Resources/Reader/vendor.',
    'NSAppTransportSecurity': {'NSAllowsArbitraryLoads': False},
}
Path(path).write_bytes(plistlib.dumps(manifest, sort_keys=False))

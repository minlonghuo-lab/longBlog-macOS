#!/usr/bin/env python3
"""Fail packaging when the executable, offline reader or licenses are absent."""
import plistlib
import sys
from pathlib import Path

app = Path(sys.argv[1])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'com.huowenlong.longblog.macos'
assert info['LSMinimumSystemVersion'] == '14.0'
assert info['NSAppTransportSecurity']['NSAllowsArbitraryLoads'] is False
resources = app / 'Contents/Resources'
required = ['MacReader/index.html', 'MacReader/reader.js', 'MacReader/reader.css',
            'Reader/reader-mermaid.js', 'Reader/vendor/marked.umd.js', 'Reader/vendor/katex.min.js',
            'Reader/vendor/mermaid.min.js', 'Reader/vendor/Marked-LICENSE.md',
            'Reader/vendor/KaTeX-LICENSE.txt', 'Reader/vendor/Mermaid-LICENSE.txt',
            'Reader/vendor/Boxicons-LICENSE.txt']
for name in required:
    path = resources / name
    assert path.is_file() and path.stat().st_size, name
assert (app / 'Contents/MacOS/longBlog').stat().st_size > 10000
print('Bundle manifest, executable, offline assets and third-party licenses verified.')

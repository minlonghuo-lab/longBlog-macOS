"""Offline reader contracts. Run: python3 -m unittest discover -s tests -p test_reader_contract.py -v

No Python/JS packages or network are required. Node checks execute the REAL bundled
Marked parser and the renderer's pure boundary helpers, not a duplicate implementation.
Native WebKit integration still needs the macOS smoke checklist in READER-PORT.md.
"""
from pathlib import Path
from html.parser import HTMLParser
import json
import re
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
MAC = ROOT / "Resources/MacReader"
SWIFT = ROOT / "Sources/LongBlog/Reader"


class PageParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.elements = []

    def handle_starttag(self, tag, attrs):
        self.elements.append((tag, dict(attrs)))


class ReaderContracts(unittest.TestCase):
    def test_public_api_and_structured_bridge(self):
        view = (SWIFT / "ReaderView.swift").read_text()
        self.assertIn("struct ReaderView: NSViewRepresentable", view)
        self.assertIn("init(markdown: String, baseDirectory: URL? = nil", view)
        self.assertIn("init(html: String, baseDirectory: URL? = nil)", view)
        self.assertIn("case markdown, html", view)
        self.assertIn("callAsyncJavaScript", view)
        self.assertIn('arguments: ["payload": payload]', view)
        self.assertNotIn("evaluateJavaScript", view)
        self.assertNotIn("loadFileURL", view)
        self.assertNotIn("startAccessingSecurityScopedResource", view)
        self.assertIn(".nonPersistent()", view)
        self.assertNotIn("addScriptMessageHandler", view)

    def test_navigation_cancels_network_and_only_hands_off_user_https(self):
        source = (SWIFT / "ReaderView.swift").read_text()
        for required in [".linkActivated", "action.sourceFrame.isMainFrame", "NSWorkspace.shared.open(url)",
                         'url.scheme?.lowercased() == "https"', "url.user == nil", "url.password == nil",
                         "decisionHandler(.cancel)", "createWebViewWith"]:
            self.assertIn(required, source)
        self.assertNotIn("URLSession", source)
        self.assertNotIn("Authorization", source)

    def test_no_follow_rooted_regular_bounded_reads(self):
        source = (SWIFT / "ReaderResources.swift").read_text()
        for required in ["Darwin.openat", "O_NOFOLLOW", "O_DIRECTORY", "O_NONBLOCK", "Darwin.fstat",
                         "S_IFREG", "rootDescriptor", "removingPercentEncoding", 'part != ".."',
                         'part.contains("%")', "c.query == nil", "c.fragment == nil", "validImage",
                         'url.host == articleHost', 'UUID().uuidString.lowercased()',
                         'task.request.httpMethod == "GET"']:
            self.assertIn(required, source)
        self.assertNotIn("URLSession", source)
        self.assertNotIn('"image/svg+xml"', source)
        self.assertNotIn('"video/', source)
        self.assertNotIn('"audio/', source)
        self.assertNotIn("Data(contentsOf:", source)

    def test_csp_and_all_script_assets_are_local(self):
        parser = PageParser()
        parser.feed((MAC / "index.html").read_text())
        csp = next(a["content"] for t, a in parser.elements
                   if t == "meta" and a.get("http-equiv") == "Content-Security-Policy")
        directives = dict((p.strip().split(" ", 1) + [""])[:2] for p in csp.split(";") if p.strip())
        self.assertEqual(directives["default-src"], "'none'")
        self.assertEqual(directives["script-src"], "lbmac-resource://app")
        self.assertNotIn("unsafe-inline", directives["script-src"])
        self.assertNotIn("unsafe-eval", csp)
        for key in ["connect-src", "media-src", "object-src", "frame-src", "worker-src", "base-uri", "form-action"]:
            self.assertEqual(directives[key], "'none'")
        scripts = [a for t, a in parser.elements if t == "script"]
        self.assertEqual(len(scripts), 5)
        for attrs in scripts:
            self.assertIn("src", attrs)
            self.assertNotRegex(attrs["src"], r"^(https?:)?//")
            self.assertTrue((MAC / attrs["src"]).resolve().is_file(), attrs["src"])
        for tag, attrs in parser.elements:
            if tag == "link":
                self.assertTrue((MAC / attrs["href"]).resolve().is_file())

    def test_inert_allowlist_and_safe_library_options(self):
        source = (MAC / "reader.js").read_text()
        for required in ["doc.createElement('template')", "template.content.childNodes", "doc.createElement(tag)",
                         "node.namespaceURI", "drop.has(tag)", "out.referrerPolicy='no-referrer'",
                         "trust:false", "maxExpand:1000", "payload.bodyFormat === 'html'",
                         "content.replaceChildren(clean)", "pre.textContent=payload.body", "Promise.allSettled",
                         "root.LBMermaid.install", "event.isTrusted"]:
            self.assertIn(required, source)
        for unsafe in ["out.innerHTML", "content.innerHTML", "document.write", "eval(", "fetch(", "XMLHttpRequest"]:
            self.assertNotIn(unsafe, source)
        mermaid = (ROOT / "Resources/Reader/reader-mermaid.js").read_text()
        self.assertIn("securityLevel:'strict'", mermaid)
        self.assertIn("htmlLabels:false", mermaid)
        self.assertIn("imageSVG(svg,doc)", mermaid)
        self.assertIn("保留源码", mermaid)

    @unittest.skipUnless(shutil.which("node"), "Node not installed; static contracts still run")
    def test_real_javascript_boundary_and_markdown(self):
        script = r'''
const assert=require('node:assert/strict');
global.marked=require(process.argv[1]+'/Resources/Reader/vendor/marked.umd.js');
const r=require(process.argv[1]+'/Resources/MacReader/reader.js');
const base='lbmac-resource://article-1234-abcd/';
assert.equal(r.localImage('./assets/hello.png',base),base+'assets/hello.png');
assert.equal(r.localImage('/assets/NOTE_1/hello.png',base),base+'assets/hello.png');
assert.equal(r.localImage('/trilium-assets/NOTE_1/hello.png',base),base+'assets/hello.png');
assert.equal(r.localImage('assets/%E4%B8%AD%E6%96%87%20a.jpg',base),base+'assets/%E4%B8%AD%E6%96%87%20a.jpg');
for(const raw of ['../x.png','assets/../x.png','assets/%2e%2e/x.png','assets/%252e%252e/x.png','assets/%2froot.png','assets/%5croot.png','assets//x.png','file:///tmp/a.png','https://host/a.png','//host/a.png','data:image/png,x','blob:x','lbmac-resource://app/a.png','assets/a.svg','assets/a.mp4','assets/a.png?token=1','assets/a.png#x','/etc/a.png','/assets/../../a.png','assets/a%00.png']) assert.equal(r.localImage(raw,base),null,raw);
assert.equal(r.localImage('assets/a.png','lbmac-resource://app/'),null);
assert.equal(r.externalLink('https://example.com/article'),'https://example.com/article');
for(const raw of ['javascript:alert(1)','http://example.com','https://user:pass@example.com','https://example.com:8443','file:///tmp/a','//example.com','data:text/html,x']) assert.equal(r.externalLink(raw),null,raw);
assert.equal(r.mathToken('$x_1 + y$',false).text,'x_1 + y');
assert.equal(r.mathToken('\\[a_b\\]',true).display,true);
assert.equal(r.mathToken('$20 与 $30',false),undefined);
const md='# Title\n\n| A | B |\n|---|---|\n| one | two |\n\n$x_1 < y$\n\n```js\nconst dollar = "$x$";\n```\n\n```mermaid\ngraph TD\n A-->B\n```\n\nTHE_END';
const html=r.markdownHTML(md);
assert.ok(html.includes('<table>'));
assert.ok(html.includes('class="math-tex"'));
assert.ok(html.includes('x_1 &lt; y'));
assert.ok(html.includes('class="language-js"'));
assert.ok(html.includes('class="language-mermaid"'));
assert.ok(html.includes('THE_END'));
assert.equal((html.match(/class="math-tex"/g)||[]).length,1);
const mermaid=require('node:fs').readFileSync(process.argv[1]+'/Resources/Reader/reader-mermaid.js','utf8');
require('node:vm').runInThisContext(mermaid);
assert.equal(global.LBMermaid.validate('graph TD\n A-->B'),'graph TD\n A-->B');
for(const raw of ['%%{init:{}}%%\ngraph TD\n A-->B','graph TD\n click A "https://example.com"','graph TD\n A[<img src=x>]','---\nconfig: x\n---\ngraph TD']) assert.throws(()=>global.LBMermaid.validate(raw));
console.log('URL, traversal, parser, math, code and Mermaid attack contracts passed');
'''
        result = subprocess.run(["node", "-e", script, str(ROOT)], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()

# Bundled KaTeX

Pinned version: **0.19.0**, matching the website's package-lock.json.
Source: https://registry.npmjs.org/katex/-/katex-0.19.0.tgz
Distribution: unmodified dist/katex.min.js, dist/katex.min.css and all 60 dist/fonts files.
License: MIT; complete upstream notice is in KaTeX-LICENSE.txt.
No runtime CDN or remote JavaScript requests are used.

SHA-256:
- katex.min.js: 103a53763cc033bba8d175bf3f0ba597c3505c9b6747dd3f2c7bc2a6bfcc8ae7
- katex.min.css: d4ab5b8ee16989b070cdb0ea24bd6ad48fc8df1b787f280f29d3ae4f959f2c00

Preserve the fonts/ directory relative to the stylesheet when bundling.

# Bundled Mermaid

Pinned version: **12.2.0** (matches the website's current dependency).
Source: https://registry.npmjs.org/mermaid/-/mermaid-12.2.0.tgz
Distribution: **unmodified** upstream `dist/mermaid.min.js`, standalone IIFE;
no esbuild step, ESM imports, runtime chunks, CDN or remote renderer required.
Exact JS size: **5,494,801 bytes**.
SHA-256: `a8a6a6f805b074a8261a2825c86f99c8054acb3b35f50bb7e24a4f9f2c3c3b9f`.

License: MIT, full notice in `Mermaid-LICENSE.txt` (1,089 bytes).
Upstream bundled dependency comments remain intact in the JS. Additional complete
package notices (including Apache-2.0/MIT/BSD and DOMPurify's Apache-2.0/Mozilla
alternative licenses) are in `Mermaid-THIRD-PARTY-NOTICES.txt` (230,826 bytes).
`Mermaid-DEPENDENCIES.json` (14,393 bytes) records the upstream installed dependency
versions/licenses used to collect those notices; optional/build-only packages may
be listed though not executed. These four Mermaid vendor files total **5,741,109 bytes**.

The approved diagram profile uses iOS system fonts (`-apple-system`, PingFang SC,
sans-serif); **zero new font assets are required**. Mermaid embedded `$$` math,
HTML labels, icon/image shapes, user CSS/configuration/frontmatter, callbacks,
links and external resources are rejected with source fallback. Article LaTeX
continues to use the existing fully bundled KaTeX fonts; it is not Mermaid math.
The Mermaid package's dormant math/font code is never requested by this profile.

`reader-mermaid.js` pins strict/no-auto-start/no-HTML-label settings, bounds source
and output, rebuilds SVG through an inert allowlist, strips animation keyframes,
and emits only self-contained `data:image/svg+xml` images. SVG is never attached
as active article DOM and Mermaid's `bindFunctions` is never called. The template
retains `script-src 'none'` / `connect-src 'none'`; only `img-src` gains `data:`.
The article sanitizer still rejects author-supplied data URLs/SVG. The native
HTTPS image bridge, nonce, exact-file check and byte limits are unchanged.

# Bundled Markdown parser

Pinned Marked **12.0.2**, unmodified `lib/marked.umd.js` from
https://registry.npmjs.org/marked/-/marked-12.0.2.tgz .
MIT notice retained in `Marked-LICENSE.md`.
Runs in the existing isolated content world. Its output is NOT trusted HTML:
`reader.js` reconstructs it through the article allowlist. Memos previews disable
all embedded image loads; attachments use native authenticated download instead.
No token enters the parser, WebView or generated HTML. Memo previews are bound to
the current Memos connection generation and cleared on account change.

/* Trusted renderer. Executed ONLY in WKContentWorld LongBlogReader, never in the page world.
   Article HTML is parsed in an inert template and rebuilt from an explicit allowlist. */
(function (root) {
'use strict';
const tags = new Set('p div aside span br hr h1 h2 h3 h4 h5 h6 strong b em i u s del mark sub sup blockquote ul ol li dl dt dd pre code figure figcaption table caption colgroup col thead tbody tfoot tr th td a img details summary kbd samp small abbr audio video source'.split(' '));
const drop = new Set('script style link meta base iframe frame frameset object embed svg math template noscript form input textarea button select option canvas'.split(' '));
const classes = new Set(('math-tex reader-literal-dollar mermaid image image_resized image-style-align-center image-style-align-left image-style-align-right image-style-side image-style-block-align-left image-style-block-align-right table ck-table-resized trilium-collapsible admonition note tip important caution warning include-note-card include-note-card-label include-note-card-title include-note-card-summary local-attachment article-pdf-card article-video article-audio article-media article-video-card article-audio-card task-list-item task-list-item-checkbox hljs ' +
  'hljs-comment hljs-quote hljs-keyword hljs-selector-tag hljs-literal hljs-doctag hljs-name hljs-string hljs-regexp hljs-addition hljs-number hljs-symbol hljs-bullet hljs-title hljs-section hljs-attr hljs-attribute hljs-variable hljs-template-variable hljs-selector-attr hljs-selector-class hljs-selector-id hljs-built_in hljs-type hljs-meta hljs-params hljs-deletion hljs-emphasis hljs-strong').split(' '));
const str = v => typeof v === 'string' ? v : '';
function safeURL(raw, base, image, allowData) {
  try {
    if (!str(raw) || raw.length > 4096 || /[\u0000-\u001f\u007f]/.test(raw)) return null;
    // Inline data images are only trusted when the native side explicitly opts
    // in (local drafts / editor preview built from local bytes). Remote author
    // HTML never gets this allowance.
    if (image && allowData && /^data:image\//i.test(raw)) return new URL(raw);
    const u = new URL(raw, base);
    if (u.protocol !== 'https:' || u.username || u.password || !u.hostname) return null;
    if (image && u.origin !== new URL(base).origin) return null;
    return u;
  } catch (_) { return null; }
}
// The capability host is generated natively per reader; never accept a custom
// scheme from author HTML or let a memo enter the local article transport.
function localResource(raw, base, resourceBase) {
  try {
    if (!str(raw) || raw.length > 4096 || /[\\\u0000-\u001f\u007f]/.test(raw)) return null;
    const capability = new URL(resourceBase);
    if (capability.protocol !== 'lbreader-resource:' || !/^[a-z0-9-]+$/.test(capability.hostname) || capability.username || capability.password || capability.port) return null;
    const u = new URL(raw,base);
    if (u.protocol !== 'https:' || u.origin !== new URL(base).origin || u.username || u.password) return null;
    const parts = u.pathname.split('/');
    if (parts.length !== 4 || !['assets','trilium-assets'].includes(parts[1])) return null;
    const id = decodeURIComponent(parts[2]), name = decodeURIComponent(parts[3]);
    if (!/^[A-Za-z0-9_-]{1,200}$/.test(id) || !name || name.length > 255 || /[/\\\u0000-\u001f\u007f]/.test(name) || ['.','..'].includes(name)) return null;
    return new URL(`assets/${encodeURIComponent(id)}/${encodeURIComponent(name)}`,capability);
  } catch (_) { return null; }
}
function findPost(raw, note, posts, base) {
  if (str(note)) { const found = posts.find(p => p.id === note); if (found) return found; }
  raw = str(raw);
  try {
    let key = '';
    if (/^#root\//.test(raw) || /^\/?#root\//.test(raw)) key = raw.split('/').filter(Boolean).pop();
    else if (/^#/.test(raw)) key = raw.slice(1);
    else {
      const u = safeURL(raw, base, false);
      if (!u || u.origin !== new URL(base).origin) return null;
      const m = u.pathname.match(/^\/blog\/([^/]+)\/?$/);
      if (m) key = decodeURIComponent(m[1]);
      else if (/^#root\//.test(u.hash)) key = u.hash.split('/').pop();
      else if (/^\/(?:notes?|api\/notes)\/[^/]+\/?$/.test(u.pathname)) key = decodeURIComponent(u.pathname.split('/').filter(Boolean).pop());
    }
    return posts.find(p => p.id === key || p.slug === key) || null;
  } catch (_) { return null; }
}
// Tokenize math BEFORE Markdown can consume TeX escapes, underscores, HTML or
// multiline display delimiters. Fences/inline code keep Marked's own precedence.
// A dedicated parser avoids mutating the global memo/detail Marked instance.
let markdownParser;
function markdownHTML(source) {
  // Normalize dash/em-dash/en-dash variants in table separator lines so iOS smart punctuation doesn't break GFM tables
  source = str(source).replace(/^(\|?[ \t]*:?[-—–－]{1,}:?[ \t]*)+(\|?)[ \t]*$/gm, line => line.replace(/[—–－]/g, '-'));
  if (!markdownParser) {
    const escape = text => text.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
    function token(src, block) {
      const match = block ? /^(?: {0,3})(\$\$|\\\[)(?:\r?\n)?/.exec(src) : /^(\$\$|\$|\\\(|\\\[)/.exec(src);
      if (!match) return;
      const left = match[1], right = left === '\\[' ? '\\]' : left === '\\(' ? '\\)' : left;
      const start = match[0].length;
      if (left === '$' && (/\s/.test(src[start] || '') || src[start] === '$' || /^\d+(?:[.,]\d+)*(?=$|[\u3000-\u9fff\uff00-\uffef])/.test(src.slice(start)))) return;
      let end = src.indexOf(right,start);
      while (end >= 0) {
        let slash = end; while (slash > start && src[slash - 1] === '\\') slash--;
        if ((end - slash) % 2 === 0) {
          // An invalid single-dollar closer is not permission to swallow a later
          // sentence/formula (notably "$20 与 $30 ... $x$").
          if (left === '$' && (src[end + 1] === '$' || /\s/.test(src[end - 1] || '') || /\d/.test(src[end + 1] || ''))) return;
          break;
        }
        end = src.indexOf(right,end + right.length);
      }
      if (end < 0 || (left === '$' && /\r|\n/.test(src.slice(start,end)))) return;
      const raw = src.slice(0,end + right.length);
      if (block && src.slice(raw.length).match(/^[^\S\r\n]*\S/)) return;
      return {type:block ? 'readerBlockMath' : 'readerInlineMath', raw, text:src.slice(start,end), display:left === '$$' || left === '\\['};
    }
    const renderToken = item => `<${item.display ? 'div' : 'span'} class="math-tex">${escape((item.display ? '\\[' : '\\(') + item.text + (item.display ? '\\]' : '\\)'))}</${item.display ? 'div' : 'span'}>`;
    markdownParser = new root.marked.Marked({gfm:true,breaks:true,extensions:[
      {name:'readerBlockMath',level:'block',start:src => { const m = /^(?: {0,3})(?:\$\$|\\\[)/m.exec(src); return m ? m.index : undefined; },tokenizer:src => token(src,true),renderer:renderToken},
      // Preserve the escape through Marked so the post-sanitize HTML scanner
      // cannot reinterpret a literal \\$ as an opening delimiter.
      {name:'readerLiteralDollar',level:'inline',start:src => { const i=src.indexOf('\\$'); return i < 0 ? undefined : i; },tokenizer:src => src.startsWith('\\$') ? {type:'readerLiteralDollar',raw:'\\$',text:'$'} : undefined,renderer:() => '<span class="reader-literal-dollar">$</span>'},
      {name:'readerInlineMath',level:'inline',start:src => { const m = /\$|\\[([]/.exec(src); return m ? m.index : undefined; },tokenizer:src => token(src,false),renderer:renderToken}
    ]});
  }
  let html = markdownParser.parse(source);
  html = html.replace(/<blockquote>\s*<p>\s*\[!(NOTE|TIP|IMPORTANT|CAUTION|WARNING)\](?:\s*<br\s*\/?>)?([\s\S]*?)<\/blockquote>/gi, (_m, type, content) => {
    const cls = type.toLowerCase();
    return `<aside class="admonition ${cls}"><p>${content.trim()}</aside>`;
  });
  return html;
}
let stopInitialTop;
function initialTop(doc, send, generation, cancelled, target) {
  if (stopInitialTop) stopInitialTop();
  if (cancelled) {
    const end = () => {};
    root.LBReaderStopInitialTop = end; stopInitialTop = end;
    return {settle:end,stop:end,complete:Promise.resolve(),finish:end};
  }
  let active = true, resolveComplete, timeout;
  const complete = new Promise(resolve => { resolveComplete = resolve; });
  const end = () => {
    if (!active) return;
    active = false;
    root.clearTimeout(timeout);
    for (const event of ['pointerdown','touchstart','wheel','keydown']) doc.removeEventListener(event,interacted,true);
    doc.removeEventListener('load',layout,true);
    root.removeEventListener('resize',resized);
    resolveComplete();
  };
  const interacted = event => {
    if (event.isTrusted && active) {
      if (generation) send({type:'initial-top-interacted',value:generation});
      end();
    }
  };
  const reset = () => {
    if (!active) return;
    // Native article frame already excludes the navigation safe area; DOM zero
    // now means the actual document top, not an offset inside automatic insets.
    if (root.history && 'scrollRestoration' in root.history) root.history.scrollRestoration = 'manual';
    // Editor preview targets the author's caret; articles always start at the top.
    let y = 0;
    try { y = target ? Math.max(0, Math.round(Number(target()) || 0)) : 0; } catch (_) { y = 0; }
    doc.documentElement.scrollTop = y; doc.body.scrollTop = y;
    if (doc.scrollingElement) { doc.scrollingElement.scrollTop = y; root.scrollTo({top:y,left:0,behavior:'instant'}); }
  };
  const frame = callback => {
    const run = () => { if (!active) return; reset(); if (callback) callback(); };
    if (root.requestAnimationFrame) root.requestAnimationFrame(run); else root.setTimeout(run,0);
  };
  const layout = event => { if (event.target.localName === 'img') frame(); };
  const resized = () => frame();
  for (const event of ['pointerdown','touchstart','wheel','keydown']) doc.addEventListener(event,interacted,{capture:true,passive:true});
  doc.addEventListener('load',layout,true);
  root.addEventListener('resize',resized);
  const finish = () => {
    if (!active) return;
    frame(() => frame(() => {
      if (generation) send({type:'initial-top-settled',value:generation});
      end();
    }));
  };
  // A bounded loading session, not a recurring scroll trap. Slow fonts/Mermaid
  // are awaited rather than prematurely disabled by the previous 1.5s timer.
  timeout = root.setTimeout(finish,10000);
  reset(); frame();
  stopInitialTop = end;
  root.LBReaderStopInitialTop = end;
  return {settle:() => frame(),stop:end,complete,finish:diagrams => {
    const fonts = doc.fonts && doc.fonts.ready ? doc.fonts.ready : Promise.resolve();
    Promise.allSettled([fonts,diagrams]).then(finish);
  }};
}
function render(data, doc, send) {
  if (!data || typeof data !== 'object' || str(data.html).length > 4194304 || str(data.markdown).length > (data.bodyFormat === 'html' ? 4194304 : 200000)) throw Error('文章过大或数据无效');
  const base = safeURL(data.site, data.site, false);
  if (!base) throw Error('站点需要有效的 HTTPS 地址');
  const posts = Array.isArray(data.posts) ? data.posts.filter(p => p && str(p.id) && str(p.slug)) : [];
  const content = doc.getElementById('content');
  const allowData = data.allowDataImages === true;
  // One canonical body: Markdown (which may contain safe raw HTML), or an
  // explicitly tagged HTML body stored in the SAME .md file. Never sniff HTML
  // structure or revive a stale sidecar over an existing Markdown body. Legacy
  // HTML-only payloads remain readable through exactly the same sanitizer.
  const hasBody = data.isMemo || data.hasMarkdown === true || (data.hasMarkdown !== false && typeof data.markdown === 'string');
  const rawHTMLBody = !data.isMemo && data.bodyFormat === 'html';
  let html = hasBody ? (rawHTMLBody ? str(data.markdown) : markdownHTML(str(data.markdown))) : str(data.html);
  if (rawHTMLBody) {
    html = html.replace(/!\[([^\]]*)\]\(([^)]+)\)/g, '<figure class="image"><img src="$2" alt="$1"></figure>');
    html = html.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2">$1</a>');
  }
  const article = !data.isMemo || data.memoSiteStyle === true;
  const legacyStyle = doc.getElementById('legacy-reader-style');
  if (legacyStyle) legacyStyle.media = article ? 'not all' : 'all';
  doc.documentElement.classList.toggle('lb-article-reader',article);
  doc.getElementById('reader')?.classList.toggle('site-reader',article);
  content.classList.toggle('site-content',article);
  if (article && root.matchMedia) {
    const media = root.matchMedia('(prefers-color-scheme: dark)');
    const syncTheme = () => { if (doc.documentElement.classList.contains('lb-article-reader')) doc.documentElement.dataset.theme = media.matches ? 'dark' : 'light'; };
    syncTheme();
    if (!doc.__lbArticleTheme && media.addEventListener) { media.addEventListener('change',syncTheme); doc.__lbArticleTheme = true; }
  }
  const resourceBase = !data.isMemo ? str(data.resourceBase) : '';
  const localURLs = new Set();
  const resource = raw => {
    // Per-article index.md uses ./assets/name. Map that one relative form via
    // the article ID; never pass arbitrary local paths into a capability.
    let canonical = raw;
    const relative = str(raw).match(/^(?:\.\/)?assets\/([^/?#]+)$/);
    if (relative && /^[A-Za-z0-9_-]{1,200}$/.test(str(data.noteID))) canonical = `/assets/${data.noteID}/${relative[1]}`;
    const u = localResource(canonical,base.href,resourceBase); if (u) localURLs.add(u.href); return u;
  };
  const tpl = doc.createElement('template'); tpl.innerHTML = html;
  let budget = 50000;
  function clean(node, depth) {
    if (--budget < 0 || depth > 100) throw Error('文章结构过于复杂');
    if (node.nodeType === 3) return doc.createTextNode(node.textContent);
    if (node.nodeType !== 1) return doc.createDocumentFragment();
    const tag = node.localName.toLowerCase();
    if (tag === 'source') return doc.createDocumentFragment();
    if (['audio','video'].includes(tag)) {
      if (data.isMemo) return doc.createDocumentFragment();
      const sources = [node.getAttribute('src'), ...Array.from(node.querySelectorAll('source'),s => s.getAttribute('src'))].filter(Boolean);
      const u = sources.map(resource).find(Boolean) || sources.map(s => safeURL(s, base.href, false)).find(url => url && url.origin === base.origin);
      if (u) {
        const media = doc.createElement(tag);
        media.controls = true;
        media.src = u.href;
        media.className = 'article-' + tag;
        if (tag === 'video') { media.playsInline = true; media.preload = 'metadata'; }
        else { media.preload = 'metadata'; }
        return media;
      }
      return doc.createDocumentFragment();
    }
    if (tag === 'input' && node.getAttribute('type') === 'checkbox' && !data.isMemo) {
      const box = doc.createElement('input');
      box.type = 'checkbox';
      box.disabled = true;
      if (node.hasAttribute('checked') || node.checked) box.checked = true;
      box.className = 'task-list-item-checkbox';
      return box;
    }
    if (drop.has(tag)) return doc.createDocumentFragment();
    const e = tags.has(tag) ? doc.createElement(tag) : doc.createDocumentFragment();
    if (e.nodeType === 1) {
      if (tag === 'li' && node.querySelector('input[type="checkbox"]')) {
        node.classList.add('task-list-item');
      }
      const cls = Array.from(node.classList).filter(c => classes.has(c) || /^language-[a-z0-9_-]{1,60}$/i.test(c));
      if (cls.length) e.className = cls.join(' ');
      const id = node.getAttribute('id'); if (id && /^[\w\u3400-\u9fff-]{1,150}$/.test(id)) e.id = 'article-' + id;
      if (['td','th'].includes(tag)) for (const attr of ['colspan','rowspan']) {
        const n = Number(node.getAttribute(attr)); if (Number.isInteger(n) && n > 0 && n <= 100) e.setAttribute(attr, String(n));
      }
      if (tag === 'details' && node.hasAttribute('open')) e.open = true;
      if (tag === 'ol') { const start = Number(node.getAttribute('start')); if (Number.isInteger(start) && Math.abs(start) <= 100000 && node.hasAttribute('start')) e.start = start; }
      if (['td','th'].includes(tag)) {
        const align = node.getAttribute('align'); if (['left','center','right'].includes(align)) e.style.textAlign = align;
        const scope = node.getAttribute('scope'); if (tag === 'th' && ['row','col','rowgroup','colgroup'].includes(scope)) e.setAttribute('scope',scope);
      }
      if (['td','th','p','figure','col'].includes(tag)) {
        const align = node.style.textAlign; if (['left','center','right'].includes(align)) e.style.textAlign = align;
        const w = node.style.width; if (/^(?:\d{1,2}(?:\.\d{1,2})?|100)%$/.test(w) && !node.classList.contains('table')) e.style.width = w;
      }
      if (tag === 'a') {
        const raw = node.getAttribute('href') || '';
        const post = findPost(raw, node.getAttribute('data-note-id'), posts, base.href);
        if (post) { e.href = '#'; e.dataset.post = post.id; }
        else if (/^#[\w\u3400-\u9fff-]{1,150}$/.test(raw)) e.href = '#article-' + raw.slice(1);
        else {
          const u = resource(raw) || safeURL(raw, base.href, false);
          if (u) {
            e.href = u.href;
            e.rel = 'noreferrer noopener';
            const pathname = (u.pathname || raw).toLowerCase();
            if (pathname.endsWith('.pdf')) {
              e.classList.add('local-attachment', 'article-pdf-card');
              e.dataset.isPdf = 'true';
            } else if (/\.(mp4|mov|webm|m4v)$/i.test(pathname)) {
              e.classList.add('local-attachment', 'article-video-card');
              e.dataset.isVideo = 'true';
            } else if (/\.(mp3|m4a|wav|ogg|aac)$/i.test(pathname)) {
              e.classList.add('local-attachment', 'article-audio-card');
              e.dataset.isAudio = 'true';
            }
          }
        }
      }
      if (tag === 'img') {
        // Account attachments are downloaded via native authenticated transport;
        // never put the account token in WebKit or let a draft beacon off-site.
        if (data.isMemo) return doc.createTextNode('[图片请在附件区预览]');
        const u = resource(node.getAttribute('src')) || safeURL(node.getAttribute('src'), base.href, true, allowData);
        if (!u) return doc.createDocumentFragment();
        e.src = u.href; e.alt = str(node.getAttribute('alt')).slice(0, 1000) || '文章图片，点按放大';
        e.loading = 'lazy'; e.decoding = 'async'; e.referrerPolicy = 'no-referrer'; e.tabIndex = 0;
        for (const attr of ['width','height']) { const n = Number(node.getAttribute(attr)); if (n > 0 && n <= 20000) e.setAttribute(attr, String(n)); }
        e.addEventListener('error', () => { e.classList.add('failed'); e.alt = '图片未加载，点按重试 / 预览'; });
      }
    }
    for (const child of node.childNodes) e.appendChild(clean(child, depth + 1));
    return e;
  }
  const fragment = doc.createDocumentFragment();
  for (const child of tpl.content.childNodes) fragment.appendChild(clean(child, 0));
  content.replaceChildren(fragment);
  // Editor preview caret anchor: the marker is plain text inserted by the native
  // editor; it is removed here and replaced by an empty positioning element.
  let previewAnchor = null;
  const marker = data.isEditorPreview === true ? str(data.previewAnchor) : '';
  if (/^LBCARET[0-9A-F]{8}$/.test(marker)) {
    const walker = doc.createTreeWalker(content, 4);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const at = node.data.indexOf(marker);
      if (at < 0) continue;
      node.data = node.data.slice(0, at) + node.data.slice(at + marker.length);
      const host = node.parentElement;
      previewAnchor = doc.createElement('div');
      previewAnchor.className = 'reader-preview-anchor';
      previewAnchor.setAttribute('aria-hidden', 'true');
      if (host && host !== content && host.localName === 'p' && !host.textContent.trim() && !host.querySelector('img,video,audio')) host.replaceWith(previewAnchor);
      else { previewAnchor = doc.createElement('span'); previewAnchor.className = 'reader-preview-anchor'; node.parentNode.insertBefore(previewAnchor, node); }
      break;
    }
  }
  doc.getElementById('title').textContent = str(data.title);
  doc.getElementById('meta').textContent = str(data.meta);
  const summary = doc.getElementById('summary');
  if (summary) { summary.textContent = data.isMemo ? '' : str(data.summary); summary.hidden = !summary.textContent; }
  let formulas = 0;
  function math(el, source, display) {
    if (++formulas > 2000 || source.length > 20000) { el.textContent = source; el.classList.add('math-error'); return; }
    try {
      root.katex.render(source, el, {displayMode:display, output:'htmlAndMathml', throwOnError:true, strict:'ignore', trust:false, maxExpand:1000, maxSize:20, macros:{}});
      if (display) el.classList.add('math-block');
    } catch (_) { el.textContent = source; el.classList.add('math-error'); el.title = '公式暂时无法渲染，显示 LaTeX 源码'; }
  }
  content.querySelectorAll('.math-tex').forEach(el => {
    if (el.closest('pre,code,.mermaid')) return;
    let source = el.textContent.trim(), display = false;
    for (const [left,right,block] of [['\\[','\\]',true],['\\(','\\)',false],['$$','$$',true],['$','$',false]]) {
      if (source.startsWith(left) && source.endsWith(right) && source.length >= left.length + right.length) { source = source.slice(left.length,-right.length); display = block; break; }
    }
    math(el, source, display);
  });
  // Legacy rich editors can serialize display delimiters into separate <p>
  // nodes (and line breaks into <br>). Collect only inert prose runs, with hard
  // boundaries at code/diagrams/tables. A DOM Range replaces just the formula;
  // surrounding paragraphs, figures and code bytes are never flattened.
  const excludedMath = 'pre,code,kbd,samp,.reader-literal-dollar,.math-tex,.mermaid,[class*="language-mermaid"],[class*="language-text-x-mermaid"],.math-error,.katex';
  let run = '', positions = [], runs = [];
  const boundary = () => { if (run) runs.push({text:run,positions}); run=''; positions=[]; };
  const appendBreak = () => { if (run && !run.endsWith('\n')) run+='\n'; };
  function collectMath(node) {
    if (node.nodeType === 3) {
      const start=run.length;run+=node.textContent;
      positions.push({node,start,end:run.length});
      return;
    }
    if (node.nodeType !== 1) return;
    if (node.matches(excludedMath) || node.matches('table,figure,img,hr,details,summary')) { boundary(); return; }
    if (node.localName === 'br') { appendBreak(); return; }
    const block = node.matches('p,div,section,article,blockquote,h1,h2,h3,h4,h5,h6,li,ul,ol,aside');
    if (block) appendBreak();
    for (const child of node.childNodes) collectMath(child);
    if (block) appendBreak();
  }
  collectMath(content); boundary();
  function isEscaped(text,index) { let n=0; while(index>0 && text[--index]==='\\') n++; return n%2===1; }
  for (const item of runs) {
    const pattern=/\$\$|\\\[/g, matches=[]; let match;
    while ((match=pattern.exec(item.text))) {
      if (isEscaped(item.text,match.index)) continue;
      const left=match[0],right=left==='$$'?'$$':'\\]',start=match.index+left.length;
      let end=item.text.indexOf(right,start);
      while(end>=0 && isEscaped(item.text,end))end=item.text.indexOf(right,end+right.length);
      if(end<0)continue;
      const locate=index => {
        const part=item.positions.find(p=>p.start<=index && index<p.end);
        return part ? {node:part.node,offset:index-part.start} : null;
      };
      const from=locate(match.index),to=locate(end+right.length-1);
      if(from && to && from.node!==to.node)matches.push({from,to,source:item.text.slice(start,end)});
      pattern.lastIndex=end+right.length;
    }
    // Reverse document order: earlier offsets remain valid after each mutation.
    for(const match of matches.reverse()) {
      const range=doc.createRange();range.setStart(match.from.node,match.from.offset);range.setEnd(match.to.node,match.to.offset+1);
      const el=doc.createElement('span');el.className='math-tex';math(el,match.source,true);
      range.deleteContents();range.insertNode(el);
    }
  }
  // Same delimiters/escape rules for each remaining text node; fresh macros.
  const walker = doc.createTreeWalker(content, 4), texts = []; let textNode;
  while ((textNode = walker.nextNode())) {
    if (!textNode.parentElement.closest('pre,code,kbd,samp,.reader-literal-dollar,.math-tex,.mermaid,[class*="language-mermaid"],[class*="language-text-x-mermaid"],.math-error,.katex')) texts.push(textNode);
  }
  function escaped(text, index) { let slashes = 0; while (index > 0 && text[--index] === '\\') slashes++; return slashes % 2 === 1; }
  for (const node of texts) {
    const text = node.textContent, opener = /\\\[|\\\(|\$\$|\$/g;
    let match, cursor = 0; const replacement = doc.createDocumentFragment();
    while ((match = opener.exec(text))) {
      if (escaped(text, match.index)) continue;
      const left = match[0], right = left === '\\[' ? '\\]' : left === '\\(' ? '\\)' : left;
      const start = match.index + left.length;
      if (left === '$' && (/\s/.test(text[start] || '') || text[start] === '$' || /^\d+(?:[.,]\d+)*(?=$|[\u3000-\u9fff\uff00-\uffef])/.test(text.slice(start)))) continue;
      let end = text.indexOf(right,start);
      while (end !== -1 && escaped(text,end)) end = text.indexOf(right,end + right.length);
      if (end === -1) continue;
      if (left === '$' && (text[end + 1] === '$' || /\s/.test(text[end - 1] || '') || /\d/.test(text[end + 1] || '') || /\r|\n/.test(text.slice(start,end)))) continue;
      replacement.appendChild(doc.createTextNode(text.slice(cursor,match.index)));
      const el = doc.createElement('span'); el.className = 'math-tex';
      math(el,text.slice(start,end),left === '$$' || left === '\\['); replacement.appendChild(el);
      cursor = end + right.length; opener.lastIndex = cursor;
    }
    if (cursor) { replacement.appendChild(doc.createTextNode(text.slice(cursor))); node.replaceWith(replacement); }
  }
  content.querySelectorAll('table').forEach(table => {
    const wrap = doc.createElement('div'); wrap.className = 'table-scroll'; wrap.tabIndex = 0; wrap.setAttribute('role','region'); wrap.setAttribute('aria-label','表格，可横向滚动');
    table.before(wrap); wrap.appendChild(table);
  });
  content.querySelectorAll('pre').forEach(pre => {
    const code = pre.querySelector('code');
    // Mirror src/data/syntax-highlight.ts: explicit languages only. Never
    // autodetect text-x-trilium-auto, Mermaid or ordinary prose as source code.
    const mime = code ? Array.from(code.classList).find(c=>c.startsWith('language-'))?.slice(9) : '';
    const language = ({'text-x-sh':'bash','text-x-shell':'bash','text-x-bash':'bash','text-x-zsh':'bash','text-x-yaml':'yaml','text-x-yml':'yaml','text-x-python':'python','text-x-latex':'latex','text-x-tex':'latex'})[mime];
    if (article && language && root.LBSiteHighlight && code.textContent.length <= 262144 && !code.querySelector('[class^="hljs-"]')) {
      // Only the trusted bundled highlighter's escaped output enters this node.
      // highlight.js never invokes author code, loads languages or fetches URLs.
      try { code.innerHTML = root.LBSiteHighlight.highlight(code.textContent,{language,ignoreIllegals:true}).value; pre.classList.add('hljs'); } catch (_) {}
    }
    const text = (code || pre).textContent;
    const wrap = doc.createElement('div'); wrap.className = 'code-block';
    const bar = doc.createElement('div'); bar.className = 'code-toolbar';
    const label = doc.createElement('span'); label.textContent = (pre.querySelector('code')?.className || '代码').replace(/^language-/, '');
    const btn = doc.createElement('button'); btn.type = 'button'; btn.textContent = '复制'; btn.setAttribute('aria-label','复制代码');
    btn.addEventListener('click', event => { if (!event.isTrusted) return; if (text.length > 262144) { btn.textContent = '代码过长'; return; } send({type:'copy',value:text}); btn.textContent = '已复制'; root.setTimeout(() => { btn.textContent = '复制'; },1500); });
    bar.append(label, btn); pre.before(wrap); wrap.append(bar, pre);
  });
  content.querySelectorAll('a.include-note-card[data-post]').forEach(a => {
    const post = posts.find(p => p.id === a.dataset.post);
    a.replaceChildren();
    for (const [cls,text] of [['label','相关文章 ↗'],['title',post.title],['summary',post.summary]]) { const s = doc.createElement('span'); s.className = 'include-note-card-' + cls; s.textContent = str(text); a.appendChild(s); }
  });
  content.onclick = event => {
    if (!event.isTrusted) return;
    const image = event.target.closest('img');
    if (image) { event.preventDefault(); send({type:'image',value:image.src}); return; }
    const a = event.target.closest('a'); if (!a) return;
    if (a.dataset.post) { event.preventDefault(); send({type:'post',value:a.dataset.post}); }
    else if (a.getAttribute('href')?.startsWith('#article-')) { event.preventDefault(); doc.getElementById(a.getAttribute('href').slice(1))?.scrollIntoView({block:'start',behavior:'smooth'}); }
    else {
      event.preventDefault();
      const href = a.href || '';
      const isMedia = localURLs.has(href) || a.dataset.isPdf || a.dataset.isVideo || a.dataset.isAudio ||
                      /\.(pdf|mp4|mov|webm|m4v|mp3|m4a|wav)(?:[?#].*)?$/i.test(href);
      if (isMedia) {
        send({type:'attachment',value:href});
      } else if (a.href && safeURL(a.getAttribute('href'),base.href,false)) {
        send({type:'link',value:a.href});
      }
    }
  };
  content.onkeydown = event => { if (event.isTrusted && event.key === 'Enter' && event.target.localName === 'img') { event.preventDefault(); send({type:'image',value:event.target.src}); } };
  const ratio = data.isEditorPreview === true ? Math.min(1, Math.max(0, Number(data.previewRatio) || 0)) : 0;
  const scroller = () => doc.scrollingElement || doc.documentElement;
  // Caret block sits about a third down the viewport, like in the editor.
  const previewTarget = previewAnchor
    ? () => previewAnchor.getBoundingClientRect().top + scroller().scrollTop - (root.innerHeight || 0) * 0.3
    : (ratio > 0 ? () => ratio * Math.max(0, scroller().scrollHeight - (root.innerHeight || 0)) : null);
  const top = initialTop(doc,send,str(data.initialTopGeneration),data.initialTopCancelled === true,previewTarget);
  root.LBReaderInitialTopComplete = top.complete;
  // Diagrams render after the synchronous article pass; native readiness does not
  // wait for SVG layout. Expose completion only to the trusted test/debug world.
  root.LBReaderDiagramsComplete = Promise.resolve();
  if (root.LBMermaid) {
    try {
      const diagrams = root.LBMermaid.install(content,doc,send);
      root.LBReaderDiagramsComplete = diagrams && diagrams.complete ? diagrams.complete : Promise.resolve();
      root.LBReaderDiagramsComplete.then(top.settle).catch(()=>{});
    } catch (_) {
      // A broken diagram engine must not fail the whole article.
      root.LBReaderDiagramsComplete = Promise.resolve();
    }
  }
  top.finish(root.LBReaderDiagramsComplete);
  doc.getElementById('status').textContent = '';
  return {formulas, tables:content.querySelectorAll('table').length};
}
const api = {render, safeURL, findPost};
if (typeof module !== 'undefined' && module.exports) module.exports = api;
else root.LBReader = api;
})(typeof window !== 'undefined' ? window : globalThis);

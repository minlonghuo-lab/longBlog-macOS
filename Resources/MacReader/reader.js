/* LongBlog macOS offline renderer. Author HTML is inert input, never executable DOM. */
(function (root) {
'use strict';
const MAX_BODY = 4 * 1024 * 1024;
const tags = new Set('p div aside span br hr h1 h2 h3 h4 h5 h6 strong b em i u s del mark sub sup blockquote ul ol li dl dt dd pre code figure figcaption table caption colgroup col thead tbody tfoot tr th td a img details summary kbd samp small abbr'.split(' '));
const drop = new Set('script style link meta base iframe frame frameset object embed svg math template noscript form input textarea button select option canvas foreignobject'.split(' '));
const classes = new Set('math-tex reader-literal-dollar mermaid admonition note tip important warning caution image image_resized image-style-align-center image-style-align-left image-style-align-right table task-list-item'.split(' '));
const str = value => typeof value === 'string' ? value : '';
const escapeHTML = text => text.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');

// Decode once BEFORE URL normalization: encoded dot segments must not silently disappear.
function localImage(raw, resourceBase) {
  try {
    raw = str(raw).trim();
    if (!raw || raw.length > 4096 || /[\\\u0000-\u001f\u007f?#]/.test(raw)) return null;
    if (/^[a-z][a-z\d+.-]*:/i.test(raw) || raw.startsWith('//')) return null;
    let path = raw;
    if (path.startsWith('./')) path = path.slice(2);
    let parts = path.split('/');
    if (parts[0] === '') {
      // Canonical server /assets/NOTE/file becomes this article's ./assets/file.
      // NOTE is a label only, NEVER a directory capability or a vault lookup.
      if (parts.length !== 4 || !['assets','trilium-assets'].includes(parts[1]) || !/^[A-Za-z0-9_-]{1,200}$/.test(parts[2])) return null;
      parts = ['assets', parts[3]];
    }
    if (!parts.length || parts.length > 24) return null;
    const decoded = parts.map(part => decodeURIComponent(part));
    if (decoded.some(part => !part || part === '.' || part === '..' || part.length > 255 || /[/\\%\u0000-\u001f\u007f]/.test(part))) return null;
    if (!/\.(?:png|jpe?g|gif|webp)$/i.test(decoded[decoded.length - 1])) return null;
    const base = new URL(resourceBase);
    if (base.protocol !== 'lbmac-resource:' || !/^article-[a-f\d-]+$/.test(base.hostname) || base.username || base.password || base.port || base.search || base.hash || base.pathname !== '/') return null;
    return base.href + decoded.map(encodeURIComponent).join('/');
  } catch (_) { return null; }
}

function externalLink(raw) {
  try {
    raw = str(raw).trim();
    if (!raw || raw.length > 4096 || /[\\\u0000-\u001f\u007f]/.test(raw)) return null;
    const url = new URL(raw);
    if (url.protocol !== 'https:' || !url.hostname || url.username || url.password || (url.port && url.port !== '443')) return null;
    return url.href;
  } catch (_) { return null; }
}

function mathToken(src, block) {
  const match = block ? /^(?: {0,3})(\$\$|\\\[)(?:\r?\n)?/.exec(src) : /^(\$\$|\$|\\\(|\\\[)/.exec(src);
  if (!match) return;
  const left = match[1], right = left === '\\[' ? '\\]' : left === '\\(' ? '\\)' : left;
  const start = match[0].length;
  if (left === '$' && (/\s/.test(src[start] || '') || src[start] === '$' || /^\d+(?:[.,]\d+)*(?=$|[\u3000-\u9fff\uff00-\uffef])/.test(src.slice(start)))) return;
  let end = src.indexOf(right, start);
  while (end >= 0) {
    let slash = end; while (slash > start && src[slash - 1] === '\\') slash--;
    if ((end - slash) % 2 === 0) {
      if (left === '$' && (src[end + 1] === '$' || /\s/.test(src[end - 1] || '') || /\d/.test(src[end + 1] || ''))) return;
      break;
    }
    end = src.indexOf(right, end + right.length);
  }
  if (end < 0 || (left === '$' && /\r|\n/.test(src.slice(start, end)))) return;
  const raw = src.slice(0, end + right.length);
  if (block && /^[^\S\r\n]*\S/.test(src.slice(raw.length))) return;
  return {type: block ? 'readerBlockMath' : 'readerInlineMath', raw, text: src.slice(start, end), display: left === '$$' || left === '\\['};
}
let parser;
function markdownHTML(source) {
  if (!root.marked) throw Error('打包的 Marked 资源不可用');
  if (!parser) {
    const renderMath = item => `<${item.display ? 'div' : 'span'} class="math-tex">${escapeHTML((item.display ? '\\[' : '\\(') + item.text + (item.display ? '\\]' : '\\)'))}</${item.display ? 'div' : 'span'}>`;
    parser = new root.marked.Marked({gfm: true, breaks: true, extensions: [
      {name:'readerBlockMath', level:'block', start:src => {const m=/^(?: {0,3})(?:\$\$|\\\[)/m.exec(src);return m ? m.index : undefined;}, tokenizer:src => mathToken(src,true), renderer:renderMath},
      {name:'readerLiteralDollar', level:'inline', start:src => {const i=src.indexOf('\\$');return i < 0 ? undefined : i;}, tokenizer:src => src.startsWith('\\$') ? {type:'readerLiteralDollar',raw:'\\$',text:'$'} : undefined, renderer:() => '<span class="reader-literal-dollar">$</span>'},
      {name:'readerInlineMath', level:'inline', start:src => {const m=/\$|\\[([]/.exec(src);return m ? m.index : undefined;}, tokenizer:src => mathToken(src,false), renderer:renderMath}
    ]});
  }
  // Smart punctuation in GFM separator lines should not destroy a table.
  source = source.replace(/^(\|?[ \t]*:?[-—–－]+:?[ \t]*)+(\|?)[ \t]*$/gm, line => line.replace(/[—–－]/g,'-'));
  return parser.parse(source);
}

function sanitize(html, doc, payload) {
  const template = doc.createElement('template');
  template.innerHTML = html; // Inert: never attach original nodes, even for apparently safe elements.
  const fragment = doc.createDocumentFragment();
  let budget = 100000;
  const mediaNote = label => {const p=doc.createElement('p');p.className='blocked-resource';p.textContent=label;return p;};
  function clone(node, depth) {
    if (--budget < 0 || depth > 100) throw Error('文章结构过于复杂；请简化嵌套或分篇');
    if (node.nodeType === 3) return doc.createTextNode(node.textContent);
    if (node.nodeType !== 1) return null;
    const tag = node.localName.toLowerCase();
    if (node.namespaceURI !== 'http://www.w3.org/1999/xhtml' || drop.has(tag)) return null;
    if (['audio','video','source','picture'].includes(tag)) return mediaNote('离线预览已禁用音视频及动态媒体。');
    if (!tags.has(tag)) {
      const f=doc.createDocumentFragment();
      for (const child of node.childNodes) {const safe=clone(child,depth+1);if(safe)f.append(safe);}
      return f;
    }
    if (tag === 'img') {
      const src = payload.hasRoot ? localImage(node.getAttribute('src'), payload.resourceBase) : null;
      const alt = (node.getAttribute('alt') || '图片').slice(0,1000);
      if (!src) return mediaNote('图片未加载（仅允许当前文章的本地 PNG / JPEG / GIF / WebP）：' + alt);
      const image = doc.createElement('img');
      image.alt = alt; image.src = src; image.loading = 'eager'; image.decoding = 'async'; image.referrerPolicy = 'no-referrer';
      image.addEventListener('error', () => image.replaceWith(mediaNote('本地图片不可用：' + alt)), {once:true});
      return image;
    }
    const out = doc.createElement(tag);
    // Never copy name/id/data/style attributes: no DOM clobbering, CSS or renderer directives.
    const safeClasses = str(node.getAttribute('class')).split(/\s+/).filter(c => classes.has(c) || /^language-[\w-]{1,40}$/.test(c));
    if (safeClasses.length) out.className = safeClasses.join(' ');
    const title = node.getAttribute('title'); if (title) out.title = title.slice(0,1000);
    const lang = node.getAttribute('lang'); if (lang && /^[A-Za-z-]{1,35}$/.test(lang)) out.lang = lang;
    const dir = node.getAttribute('dir'); if (['ltr','rtl','auto'].includes(dir)) out.dir = dir;
    if (tag === 'a') {
      const raw = str(node.getAttribute('href'));
      const href = externalLink(raw);
      if (href) {out.href=href;out.rel='noopener noreferrer';out.referrerPolicy='no-referrer';}
      else if (/^#[A-Za-z\d_-]{1,160}$/.test(raw)) out.href = raw;
      else out.classList.add('disabled-link');
    }
    for (const key of ['colspan','rowspan']) if (['td','th'].includes(tag) && /^\d{1,2}$/.test(node.getAttribute(key)||'')) out.setAttribute(key,node.getAttribute(key));
    if (tag === 'ol' && /^-?\d{1,6}$/.test(node.getAttribute('start')||'')) out.setAttribute('start',node.getAttribute('start'));
    if (tag === 'details' && node.hasAttribute('open')) out.open = true;
    for (const child of node.childNodes) {const safe=clone(child,depth+1);if(safe)out.append(safe);}
    return out;
  }
  for (const child of template.content.childNodes) {const safe=clone(child,0);if(safe)fragment.append(safe);}
  return fragment;
}

function renderMath(content, doc) {
  let count = 0;
  function typeset(element, token) {
    if (!root.katex || token.text.length > 16000 || ++count > 1000) return;
    const original = element.textContent;
    try {
      root.katex.render(token.text, element, {displayMode:token.display,throwOnError:true,
        trust:false,strict:'warn',maxExpand:1000,maxSize:20,macros:{},output:'htmlAndMathml'});
    } catch (_) {element.textContent=original;element.classList.add('math-error');element.title='公式无法排版，保留原文';}
  }
  for (const element of content.querySelectorAll('.math-tex')) {
    const token=mathToken(element.textContent,false);
    if (token && token.raw.length === element.textContent.length) typeset(element,token);
  }
  // HTML bodies can contain TeX text too. Do not scan code, existing math or literal dollars.
  const walker=doc.createTreeWalker(content,4);
  const texts=[];let text;
  while ((text=walker.nextNode())) {
    if (!text.parentElement.closest('pre,code,kbd,samp,.math-tex,.katex,.reader-literal-dollar')) texts.push(text);
  }
  for (const node of texts) {
    const source=node.textContent, fragment=doc.createDocumentFragment();let cursor=0,last=0,changed=false;
    while (cursor < source.length) {
      const match=/\$|\\[([]/.exec(source.slice(cursor));if (!match) break;
      const at=cursor+match.index;
      // Keep escaped delimiters literal, including double-escaped author text.
      if (at > 0 && source[at-1] === '\\') {cursor=at+1;continue;}
      const token=mathToken(source.slice(at),false);
      if (!token) {cursor=at+1;continue;}
      fragment.append(doc.createTextNode(source.slice(last,at)));
      const span=doc.createElement('span');span.className='math-tex';span.textContent=token.raw;
      typeset(span,token);fragment.append(span);
      cursor=at+token.raw.length;last=cursor;changed=true;
    }
    if (changed) {fragment.append(doc.createTextNode(source.slice(last)));node.replaceWith(fragment);}
  }
}

function headings(content) {
  const used=new Set();
  for (const h of content.querySelectorAll('h1,h2,h3,h4,h5,h6')) {
    const stem=h.textContent.trim().toLowerCase().replace(/[^\p{L}\p{N}_-]+/gu,'-').replace(/^-|-$/g,'').slice(0,120)||'section';
    let id=stem, suffix=1;while(used.has(id))id=stem+'-'+(++suffix);
    used.add(id);h.id='heading-'+id;
  }
}

let generation=0;
async function render(payload) {
  const doc=root.document, content=doc.getElementById('content'), status=doc.getElementById('reader-status');
  const ticket=++generation;
  try {
    if (!payload || typeof payload.body !== 'string' || payload.body.length > MAX_BODY) throw Error('文章超过 4 MiB 预览上限，正文未被截断；请在编辑器中查看。');
    status.hidden=false;status.textContent='';
    const html=payload.bodyFormat === 'html' ? payload.body : markdownHTML(payload.body);
    const clean=sanitize(html,doc,payload);
    content.replaceChildren(clean);
    headings(content);
    renderMath(content,doc);
    status.hidden=Boolean(payload.body.trim());
    status.textContent=payload.body.trim() ? '' : '此文章尚无正文。';
    const diagrams = root.LBMermaid ? root.LBMermaid.install(content,doc).complete : Promise.resolve();
    if (!root.LBMermaid && content.querySelector('code.language-mermaid, .mermaid')) {
      status.hidden=false;status.textContent='离线图表资源不可用，已完整保留图表源码。';
    }
    // Content is attached before async diagrams/fonts settle. Never blank or truncate the first render.
    await Promise.allSettled([diagrams, doc.fonts ? doc.fonts.ready : Promise.resolve()]);
    if (ticket !== generation) return false;
    return true;
  } catch (error) {
    if (ticket !== generation) return false;
    content.replaceChildren();
    // Parser failures retain the WHOLE source; limit failures explain rather than silently truncating.
    if (payload && typeof payload.body === 'string' && payload.body.length <= MAX_BODY) {
      const pre=doc.createElement('pre');pre.className='source-fallback';pre.textContent=payload.body;content.append(pre);
    }
    status.hidden=false;status.textContent='预览提示：'+(error.message||'正文无法渲染');
    return false;
  }
}

if (root.document) {
  root.document.addEventListener('click', event => {
    const anchor=event.target.closest && event.target.closest('a');
    if (!anchor) return;
    if (!event.isTrusted) {event.preventDefault();return;}
    const href=anchor.getAttribute('href');
    if (href && href.startsWith('#')) {
      event.preventDefault();
      const key=href.slice(1), target=root.document.getElementById(key)||root.document.getElementById('heading-'+key);
      if(target)target.scrollIntoView({block:'start',behavior:'smooth'});
    }
    // HTTPS is handed to the WKNavigationDelegate, never fetched by the page.
  });
}
root.LBMacReader = Object.freeze({render});
// Pure helpers are also executable under Node without DOM or a package dependency.
if (typeof module !== 'undefined' && module.exports) module.exports={localImage,externalLink,mathToken,markdownHTML,sanitize,renderMath};
})(typeof window !== 'undefined' ? window : globalThis);

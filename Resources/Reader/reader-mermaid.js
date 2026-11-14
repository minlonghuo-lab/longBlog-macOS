/* Offline Mermaid boundary. Only vetted source reaches the strict renderer; only an
   inert, rebuilt SVG data-image reaches article DOM. No Mermaid bindFunctions. */
(function(root){
'use strict';
if (root.mermaid) root.mermaid.initialize({startOnLoad:false,securityLevel:'strict',suppressErrorRendering:true});
const LIMIT = Object.freeze({count:12, chars:16000, total:80000, lines:250, edges:120, svg:2000000, nodes:12000});
const allowed = new Set('svg g defs marker path rect circle ellipse line polyline polygon text tspan title desc style clipPath linearGradient radialGradient stop pattern symbol use'.split(' '));
const ns = 'http://www.w3.org/2000/svg';
let serial=0, queue=Promise.resolve();
function validate(source) {
  if (!source.trim() || source.length>LIMIT.chars || source.split('\n').length>LIMIT.lines || (source.match(/;|--|==|~~|->/g)||[]).length>LIMIT.edges) throw Error('图表过大或过于复杂');
  // Mermaid's embedded math needs another font set and may emit foreignObject;
  // article LaTeX is handled separately by the existing bundled KaTeX renderer.
  if (source.includes('$$')) throw Error('图表内公式暂不支持');
  // Deny configuration, callbacks, links, CSS, HTML, image/icon shapes and external resources.
  if (/%%\s*\{|^\s*---|\b(?:click|callback|href|javascript|https?|ftp|file|data|blob|style|classDef|linkStyle|css|icon|image)\s*[:=(\s]|@\{|<\s*\/?\s*[a-z!]|&(?:lt|gt|#)/im.test(source)) throw Error('图表包含不支持的交互或配置');
  if (!/^\s*(?:%%[^\n]*\n\s*)*(?:flowchart|graph|sequenceDiagram|classDiagram|stateDiagram(?:-v2)?|erDiagram|gantt|pie|journey|gitGraph|mindmap|timeline|quadrantChart|xychart-beta|block-beta|packet-beta)\b/.test(source)) throw Error('暂不支持此图表类型');
  return source;
}
function imageSVG(svg, doc) {
  if (svg.length>LIMIT.svg || /<!DOCTYPE|<!ENTITY/i.test(svg)) throw Error('图表输出过大');
  const parsed=new root.DOMParser().parseFromString(svg,'image/svg+xml');
  if (parsed.querySelector('parsererror') || parsed.documentElement.localName!=='svg') throw Error('图表输出无效');
  let budget=LIMIT.nodes;
  function clone(node,depth) {
    if (--budget<0 || depth>80) throw Error('图表结构过于复杂');
    if (node.nodeType===3) return doc.createTextNode(node.textContent);
    if (node.nodeType!==1 || node.namespaceURI!==ns || !allowed.has(node.localName)) return null;
    const out=doc.createElementNS(ns,node.localName);
    if (node.localName==='style') {
      // Mermaid 12 emits built-in keyframes even for static graphs. Drop them;
      // never admit arbitrary at-rules, imports, escapes or external CSS URLs.
      const css=node.textContent.replace(/@keyframes\s+[\w-]+\s*\{(?:[^{}]|\{[^{}]*\})*\}/g,'');
      if (/@|expression|javascript|https?:|data:|\\|<|url\(\s*[^#]/i.test(css)) throw Error('图表样式无效');
      out.textContent=css; return out;
    }
    for (const a of node.attributes) {
      const name=a.name, value=a.value;
      if (/^on/i.test(name) || /^(?:src|srcset|target|tabindex)$/i.test(name) || (a.namespaceURI && a.namespaceURI!=='http://www.w3.org/2000/xmlns/')) continue;
      if (/href$/i.test(name)) { if (/^#[\w-]+$/.test(value)) out.setAttribute('href',value); continue; }
      if (/javascript:|https?:|data:|@import|expression|\\|url\(\s*[^#]/i.test(value)) continue;
      if (/^[a-zA-Z][\w:.-]*$/.test(name)) out.setAttribute(name,value);
    }
    for (const c of node.childNodes) { const safe=clone(c,depth+1); if(safe) out.appendChild(safe); }
    return out;
  }
  const safe=clone(parsed.documentElement,0);
  const vb=(safe.getAttribute('viewBox')||'').trim().split(/[ ,]+/).map(Number);
  if (vb.length!==4 || vb.some(n=>!Number.isFinite(n)) || vb[2]<=0 || vb[3]<=0 || vb[2]>20000 || vb[3]>20000) throw Error('图表尺寸无效');
  safe.setAttribute('xmlns',ns); safe.setAttribute('width',String(vb[2])); safe.setAttribute('height',String(vb[3]));
  safe.removeAttribute('style');
  const text=new root.XMLSerializer().serializeToString(safe);
  return {url:'data:image/svg+xml;charset=utf-8,'+encodeURIComponent(text),width:vb[2],height:vb[3]};
}
function config(doc) {
  const css=root.getComputedStyle(doc.documentElement), token=(name,fallback)=>css.getPropertyValue(name).trim()||fallback;
  return {startOnLoad:false,securityLevel:'strict',suppressErrorRendering:true,theme:'base',look:'classic',layout:'dagre',htmlLabels:false,
    maxTextSize:LIMIT.chars,maxEdges:LIMIT.edges,deterministicIds:true,fontFamily:'-apple-system, PingFang SC, sans-serif',
    secure:['secure','securityLevel','startOnLoad','maxTextSize','maxEdges','suppressErrorRendering','htmlLabels','theme','themeVariables','fontFamily'],
    // Same semantic tokens as src/scripts/mermaid-diagrams.js. In site CSS
    // --muted is a SURFACE, not muted ink; using it for lines hid dark arrows.
    themeVariables:{darkMode:doc.documentElement.dataset.theme==='dark',background:token('--surface','#fcfaf6'),primaryColor:token('--code','#eee9df'),primaryTextColor:token('--foreground',token('--ink','#302b25')),primaryBorderColor:token('--border',token('--line','#ded7ca')),lineColor:token('--muted-foreground',token('--muted','#756d61')),textColor:token('--foreground',token('--ink','#302b25')),secondaryColor:token('--surface','#fcfaf6'),tertiaryColor:token('--background',token('--paper','#f7f4ee')),edgeLabelBackground:token('--surface','#fcfaf6'),clusterBkg:token('--background',token('--paper','#f7f4ee')),clusterBorder:token('--border',token('--line','#ded7ca')),fontSize:'16px'},
    flowchart:{htmlLabels:false,curve:'linear',useMaxWidth:false,nodeSpacing:28,rankSpacing:36,padding:16}};
}
function install(content,doc,send) {
  const entries=Array.from(new Set(Array.from(content.querySelectorAll('pre code.language-mermaid, pre code.language-text-x-mermaid, pre.mermaid, div.mermaid'),e=>e.closest('pre')||e)));
  let total=0; const jobs=[];
  entries.forEach((el,index)=>{
    const source=el.textContent, pre=el.closest('pre')||el;
    pre.dataset.diagram='true';
    const note=doc.createElement('p');note.className='mermaid-status';note.textContent='正在离线绘制图表…';
    const holder=pre.closest('.code-block')||pre;holder.before(note);
    try {total+=source.length;if(index>=LIMIT.count||total>LIMIT.total)throw Error('本页图表超过离线渲染上限');validate(source);}
    catch(error){note.textContent=error.message+'；保留源码。';return;}
    jobs.push({source,pre,holder,note});
  });
  // Serialized because Mermaid config is global. Article becomes usable immediately,
  // then diagrams settle independently; readiness is never tied to graph latency.
  const complete=queue=queue.catch(()=>{}).then(async()=>{
    await new Promise(resolve=>root.setTimeout(resolve,40));
    for(const job of jobs){
      if(!job.holder.isConnected)return;
      const scratch=doc.createElement('div');scratch.className='mermaid-scratch';doc.body.append(scratch);
      try {
        if(!root.mermaid)throw Error('离线图表资源不可用');
        root.mermaid.initialize(config(doc));
        const {svg}=await root.mermaid.render('lb-diagram-'+(++serial),job.source,scratch);
        const result=imageSVG(svg,doc);
        if(!job.holder.isConnected)continue;
        const image=doc.createElement('img');image.className='mermaid-image';image.alt='Mermaid 图表，点按放大；下方可查看源码';image.tabIndex=0;
        // Keep the rendered palette and its paper together if system appearance
        // changes while this article stays open; a new article uses the new theme.
        image.style.backgroundColor=root.getComputedStyle(doc.documentElement).getPropertyValue('--paper').trim()||'#faf7f1';
        image.width=result.width;image.height=result.height;image.src=result.url;
        image.setAttribute('role','button');image.setAttribute('aria-label','放大 Mermaid 图表');
        const preview=e=>{
          if(!e.isTrusted)return;
          e.preventDefault();e.stopPropagation();
          // Never read image.src or author DOM: only this sanitized renderer
          // result may cross the existing isolated-world nonce wrapper.
          if(typeof send==='function'&&result.url.length<=8000000)send({type:'diagram',value:result.url});
        };
        image.onclick=preview;
        image.onkeydown=e=>{if(e.key==='Enter'||e.key===' ')preview(e);};
        const details=doc.createElement('details'), summary=doc.createElement('summary');summary.textContent='图表源码';details.append(summary);
        image.onerror=()=>{details.open=true;image.remove();job.note.textContent='图表图片无法解码；保留源码。';details.before(job.note);};
        job.holder.before(image,details);details.append(job.holder);job.note.remove();
      }catch(_){job.note.textContent='图表暂时无法绘制；保留源码，可复制或在网页版查看。';}
      finally{scratch.remove();}
      await new Promise(resolve=>root.setTimeout(resolve,0));
    }
  });
  // Only explicit trusted activation sends the sanitized diagram data-image.
  // Source text and renderer SVG markup never cross the bridge directly.
  return {count:entries.length,complete};
}
root.LBMermaid={validate,imageSVG,install,limits:LIMIT};
})(typeof window!=='undefined'?window:globalThis);

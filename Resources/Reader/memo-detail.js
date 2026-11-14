/* Injected with the bundled renderer into LongBlogMemoDetail WKContentWorld only. */
(function(root){
'use strict';
function install(doc,send){
  let revision=0, active=false, queued=false, lastHeight=0;
  const reader=doc.getElementById('reader'), content=doc.getElementById('content');
  function measure(){
    queued=false;if(!active)return;
    // Measure the content wrapper, NOT body.scrollHeight: viewport height must
    // never become a minimum that prevents shrinking after a width change.
    const raw=Math.ceil(reader.getBoundingClientRect().height);
    const height=Math.max(1,Math.min(120000,Number.isFinite(raw)?raw:1));
    if(height!==lastHeight){lastHeight=height;send({type:'height',value:height,revision});}
  }
  function schedule(){if(!queued){queued=true;root.requestAnimationFrame(measure);}}
  if(root.ResizeObserver)new root.ResizeObserver(schedule).observe(reader);
  if(root.MutationObserver)new root.MutationObserver(schedule).observe(reader,{subtree:true,childList:true,attributes:true,characterData:true});
  root.addEventListener('resize',schedule);
  doc.addEventListener('load',schedule,true);doc.addEventListener('error',schedule,true);
  doc.addEventListener('toggle',schedule,true);
  if(doc.fonts){doc.fonts.ready.then(schedule);doc.fonts.addEventListener?.('loadingdone',schedule);}
  function clear(next){
    if(!Number.isSafeInteger(next)||next<revision)return;
    revision=next;active=false;lastHeight=0;
    content.replaceChildren();
    for(const id of ['title','meta','status'])doc.getElementById(id).textContent='';
    doc.querySelectorAll('.mermaid-scratch,.diagram-preview').forEach(el=>el.remove());
  }
  function render(payload,next){
    if(!Number.isSafeInteger(next)||next<revision)return false;
    clear(next);active=true;
    // LBReader rebuilds an inert marked template using its explicit allowlist;
    // isMemo removes all authored images before they can acquire a src.
    root.LBReader.render({...payload,isMemo:true},doc,event=>{
      if(active&&revision===next)send({...event,revision:next});
    });
    if(!content.textContent.trim()&&!content.children.length)content.textContent='（仅附件说说）';
    // Native keeps this WKWebView hidden behind the immediate local body until
    // a measured render is available. rAF can be suspended for hidden views;
    // report the synchronous layout too, then track fonts/diagrams as usual.
    measure();schedule();
    Promise.resolve(root.LBReaderDiagramsComplete).then(()=>{if(active&&revision===next)schedule();});
    return true;
  }
  const api={render,clear,measure};root.LBMemoDetail=api;
  send({type:'ready'});return api;
}
const api={install};
if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.LBMemoDetail=api;
})(typeof window!=='undefined'?window:globalThis);

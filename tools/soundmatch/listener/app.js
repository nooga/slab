'use strict';
const $=id=>document.getElementById(id);
let trials=[],labels={},index=0,busy=false,current=null,queue=[],generation=0;
const heard=new Map(),audio=new Audio(); audio.preload='auto';
let audioContext, gainNode;
const pairPeaks=new Map();
let requestedDb=12;
try{const saved=localStorage.getItem('slab-listening-volume-db');if(saved!==null&&Number.isFinite(Number(saved)))requestedDb=Math.max(-12,Math.min(24,Number(saved)));}catch{}
$('volume').value=requestedDb;
function applyVolume(){
 const peak=index<trials.length?pairPeaks.get(trials[index].id):undefined;
 const requested=10**(requestedDb/20);
 const gain=peak===undefined?requested:Math.min(requested,10**(-1/20)/Math.max(peak,1e-8));
 if(gainNode)gainNode.gain.setTargetAtTime(gain,audioContext.currentTime,.02);
 const actual=20*Math.log10(gain);
 $('volumeValue').textContent=`${requestedDb>=0?'+':''}${requestedDb} dB`;
 $('volumeHint').textContent=actual<requestedDb-.1?`Shared gain limited to ${actual.toFixed(1)} dB to preserve 1 dB peak headroom.`:'Same gain for reference, A and B. Peak protection prevents clipping.';
}
$('volume').addEventListener('input',()=>{requestedDb=Number($('volume').value);try{localStorage.setItem('slab-listening-volume-db',String(requestedDb));}catch{}applyVolume();});
async function prepareVolume(trial,turn){
 if(!audioContext){audioContext=new AudioContext();gainNode=audioContext.createGain();audioContext.createMediaElementSource(audio).connect(gainNode);gainNode.connect(audioContext.destination);}
 await audioContext.resume();
 if(!pairPeaks.has(trial.id)){
  const peaks=await Promise.all(Object.values(trial.audio).map(async url=>{
   const response=await fetch(url);if(!response.ok)throw new Error('Audio unavailable');
   const buffer=await audioContext.decodeAudioData(await response.arrayBuffer());let peak=0;
   for(let c=0;c<buffer.numberOfChannels;c++){const samples=buffer.getChannelData(c);for(let i=0;i<samples.length;i++)peak=Math.max(peak,Math.abs(samples[i]));}
   return peak;
  }));
  pairPeaks.set(trial.id,Math.max(...peaks));
 }
 if(turn!==generation)return;
 applyVolume();
 // Set the protected gain before starting a new clip, including first playback.
 const protectedGain=Math.min(10**(requestedDb/20),10**(-1/20)/Math.max(pairPeaks.get(trial.id),1e-8));
 gainNode.gain.cancelScheduledValues(audioContext.currentTime);gainNode.gain.setValueAtTime(protectedGain,audioContext.currentTime);
}
const names={reference:'Reference',A:'Candidate A',B:'Candidate B'};
function error(message){$('error').textContent=message;$('error').hidden=!message;}
async function request(path,options){const response=await fetch(path,options);const data=await response.json();if(!response.ok)throw new Error(data.error||'Request failed. Please retry.');return data;}
function stop(){generation++;queue=[];audio.pause();audio.removeAttribute('src');audio.load();current=null;document.querySelectorAll('[data-play]').forEach(b=>{b.classList.remove('active');b.setAttribute('aria-pressed','false');});$('playing').textContent='Playback stopped.';$('playhead').style.width='0';$('clock').textContent='0.0 / 4.5 s';}
async function play(label,sequence=false){
 if(index>=trials.length||busy)return;
 if(!sequence){stop();}else{audio.pause();}
 const turn=++generation;current=label;
 document.querySelectorAll('[data-play]').forEach(b=>{const active=b.dataset.play===label;b.classList.toggle('active',active);b.setAttribute('aria-pressed',String(active));});
 $('playing').textContent=`Loading ${names[label].toLowerCase()}…`;
 audio.src=trials[index].audio[label];
 try{await prepareVolume(trials[index],turn);if(turn!==generation)return;await audio.play();if(turn!==generation)return;const id=trials[index].id;if(!heard.has(id))heard.set(id,new Set());heard.get(id).add(label);$('playing').textContent=`Playing ${names[label].toLowerCase()}`;error('');}
 catch(e){if(turn!==generation)return;stop();error('Audio could not play. Click a playback button to retry.');}
}
audio.addEventListener('timeupdate',()=>{const duration=Number.isFinite(audio.duration)?audio.duration:4.5;$('clock').textContent=`${audio.currentTime.toFixed(1)} / ${duration.toFixed(1)} s`;$('playhead').style.width=`${100*audio.currentTime/duration}%`;});
audio.addEventListener('ended',()=>{if(queue.length){play(queue.shift(),true);}else{document.querySelectorAll('[data-play]').forEach(b=>{b.classList.remove('active');b.setAttribute('aria-pressed','false');});$('playing').textContent=`${names[current]} finished. Replay or make your choice.`;current=null;}});
audio.addEventListener('error',()=>{if(audio.getAttribute('src')){stop();error('Could not load this audio. Check that the local server is running, then retry.');}});
function display(){
 stop();error('');const complete=index>=trials.length;$('test').hidden=complete;$('complete').hidden=!complete;
 const answered=Object.values(labels).filter(x=>x.choice!=='skip').length;
 const skipped=Object.values(labels).filter(x=>x.choice==='skip').length;
 $('saveStatus').textContent=`${answered} / ${trials.length} labeled · saved locally`;
 if(complete){$('summary').textContent=`${answered} labeled${skipped?`, ${skipped} skipped`:''}. Model identities remain hidden. You can review your answers or export them.`;$('retrySkipped').hidden=!skipped;return;}
 $('counter').textContent=`Pair ${index+1} of ${trials.length}`;
 $('playing').textContent='Ready to listen. Each button plays from the start.';
 const choice=labels[trials[index].id]?.choice;
 $('currentChoice').textContent=choice?`Saved: ${{A:'A is closer',B:'B is closer',tie:'no difference',skip:'skipped'}[choice]}`:'Not labeled yet';
 $('previous').disabled=index===0;applyVolume();
 document.querySelectorAll('[data-choice]').forEach(b=>b.classList.toggle('selected',choice===b.dataset.choice));
 $('progress').replaceChildren(...trials.map((trial,i)=>{const b=document.createElement('button');b.textContent=i+1;b.setAttribute('aria-label',`Go to pair ${i+1}${labels[trial.id]?', '+labels[trial.id].choice:''}`);b.classList.toggle('current',i===index);b.classList.toggle('answered',!!labels[trial.id]&&labels[trial.id].choice!=='skip');if(i===index)b.setAttribute('aria-current','step');b.onclick=()=>{if(!busy){index=i;display();}};return b;}));
}
async function choose(choice){
 if(busy||index>=trials.length)return;
 busy=true;stop();error('');$('saveStatus').textContent='Saving…';
 document.querySelectorAll('button').forEach(b=>b.disabled=true);
 try{const id=trials[index].id;const data=await request('/api/label',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id,choice,heard:[...(heard.get(id)||new Set(labels[id]?.heard||[]))]})});labels=data.labels;index++;display();}
 catch(e){error(e.message+' Your answer has not been saved.');$('saveStatus').textContent='Save failed · retry your choice';}
 finally{busy=false;document.querySelectorAll('button').forEach(b=>b.disabled=false);$('previous').disabled=index===0;}
}
document.querySelectorAll('[data-play]').forEach(b=>b.onclick=()=>play(b.dataset.play));
document.querySelectorAll('[data-choice]').forEach(b=>b.onclick=()=>choose(b.dataset.choice));
$('sequence').onclick=()=>{stop();queue=['A','reference','B'];play('reference',true);};
$('stop').onclick=stop;
$('previous').onclick=()=>{if(!busy&&index>0){index--;display();}};
$('review').onclick=()=>{index=0;display();};
$('retrySkipped').onclick=()=>{index=trials.findIndex(t=>labels[t.id]?.choice==='skip');display();};
$('export').onclick=async()=>{try{const data=await request('/api/export');const url=URL.createObjectURL(new Blob([JSON.stringify(data,null,2)+'\n'],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download='slab-listening-labels.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}catch(e){error(e.message);}};
document.addEventListener('keydown',event=>{if(event.repeat||event.ctrlKey||event.metaKey||event.altKey||['INPUT','TEXTAREA','SELECT'].includes(event.target.tagName))return;const key=event.key.toLowerCase();if(key===' '){event.preventDefault();stop();return;}if(busy||index>=trials.length)return;const action={r:()=>play('reference'),'1':()=>play('A'),'2':()=>play('B'),a:()=>choose('A'),b:()=>choose('B'),t:()=>choose('tie'),s:()=>choose('skip')}[key];if(action){event.preventDefault();action();}});
request('/api/session').then(data=>{trials=data.trials;$('pairCount').textContent=`${trials.length} pairs`;labels=data.labels;index=trials.findIndex(t=>!labels[t.id]);if(index<0)index=trials.length;display();}).catch(e=>{error('Could not load the session. Reload once the local server is running.');$('saveStatus').textContent='Offline';});

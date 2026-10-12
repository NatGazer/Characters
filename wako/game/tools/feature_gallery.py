"""Add small, honest game captures to FeatureGallery and rebuild its offline browser.

Examples:
  python tools/feature_gallery.py image capture.png --id spring-install --title "Spring installation" --category Construction --caption "Actual Island foot installation."
  python tools/feature_gallery.py video capture.mp4 --id native-drive --title "Native drive" --category Mechanics --caption "Paid wheel travel."
  python tools/feature_gallery.py frames "capture/frame_*.jpg" --input-fps 30 --id model-wheel --title "Wheel" --category Parts --caption "Current model; camera orbit only."

Supply only inspected captures. A model orbit is not a working-mechanism demonstration.
"""
from __future__ import annotations

import argparse
import glob
import html
import json
import os
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "FeatureGallery"
MANIFEST = OUT / "gallery.json"


def ffmpeg():
    # The system PATH may contain the old 2013 Python utility build.
    if os.environ.get("FEATURE_GALLERY_FFMPEG"):
        return os.environ["FEATURE_GALLERY_FFMPEG"]
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except ImportError:
        return "ffmpeg"


def entries():
    return json.loads(MANIFEST.read_text(encoding="utf-8")) if MANIFEST.exists() else []


def added_time(item):
    """Keep export chronology stable when the index or captions are rebuilt."""
    if not item.get("added_at"):
        exported = (OUT / item["file"]).stat().st_mtime
        item["added_at"] = datetime.fromtimestamp(exported, timezone.utc).isoformat(timespec="microseconds")
    return datetime.fromisoformat(item["added_at"].replace("Z", "+00:00"))


def rebuild(items=None):
    OUT.mkdir(exist_ok=True)
    (OUT / ".gdignore").write_text("", encoding="utf-8")
    items = entries() if items is None else items
    # Older entries inherit their actual export-file time once. New exports stamp
    # themselves in add(); rebuilding never promotes an old capture to newest.
    ordered = sorted(enumerate(items), key=lambda pair: (added_time(pair[1]), pair[0]), reverse=True)
    MANIFEST.write_text(json.dumps(items, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    categories = sorted({e["category"] for e in items})
    total = sum(p.stat().st_size for p in OUT.rglob("*") if p.is_file())
    cards = []
    for _, e in ordered:
        esc = lambda value: html.escape(str(value), quote=True)
        path = esc(e["file"])
        media = (f'<video controls autoplay muted loop preload="none" playsinline poster="{esc(e.get("poster", ""))}"><source data-src="{path}" type="video/mp4"></video>'
                 if e["type"] == "video" else f'<a href="{path}"><img loading="lazy" src="{path}" alt="{esc(e["title"])}"></a>')
        cards.append(f'<article data-id="{esc(e["id"])}" data-added-at="{esc(e["added_at"])}" data-category="{esc(e["category"])}" data-type="{e["type"]}" data-search="{esc(e["title"]+" "+e["caption"])}">{media}<small>{esc(e["category"])}</small><h2>{esc(e["title"])}</h2><p>{esc(e["caption"])}</p><div class="actions"><a class="download" href="{path}" download>Open file</a><button type="button" class="report-card" data-report="{esc(e["id"])}">Report a problem</button></div></article>')
    options = ''.join(f'<option>{html.escape(c)}</option>' for c in categories)
    page = '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Raul's Mod · Feature Gallery</title>
<style>*{box-sizing:border-box}body{margin:0;background:#151a1b;color:#eee6d6;font:16px system-ui,sans-serif}header{padding:30px 5vw 20px;border-bottom:1px solid #354442}h1{margin:0;font-size:30px}header p{max-width:950px;color:#b6c7c1;line-height:1.55}.filters{display:flex;gap:12px;flex-wrap:wrap}input,select,textarea,button{background:#253032;color:#eee6d6;border:1px solid #526662;border-radius:6px;padding:10px;font:inherit}button{cursor:pointer}button:hover{background:#344b47}button:disabled{opacity:.6;cursor:default}button:focus-visible,a:focus-visible,input:focus-visible,select:focus-visible,textarea:focus-visible{outline:2px solid #91e3cb;outline-offset:3px}main{padding:24px 5vw;display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:22px}article{border:1px solid #3b4743;background:#202829;border-radius:12px;overflow:hidden}article[hidden]{display:none}img,video{display:block;width:100%;aspect-ratio:16/9;object-fit:contain;background:#111719}h2{font-size:18px;margin:8px 16px}article p{font-size:14px;line-height:1.45;margin:8px 16px;color:#becbc4}small{display:block;margin:14px 16px 0;color:#d8b674}a{color:#91e3cb}.actions{display:flex;align-items:center;gap:14px;flex-wrap:wrap;margin:12px 16px 16px;font-size:13px}.report-card{padding:6px 9px;font-size:13px}.count{font-size:14px;color:#d8b674}dialog{background:#202829;color:#eee6d6;border:1px solid #526662;border-radius:12px;padding:24px;width:min(560px,calc(100% - 32px));max-height:90vh}dialog::backdrop{background:#071210bb}dialog h2{font-size:23px;margin:0 0 12px}dialog p{color:#becbc4;line-height:1.45}dialog label{display:block;margin-top:16px}dialog textarea{display:block;margin-top:7px;width:100%;min-height:130px;resize:vertical}.report-options{display:flex;gap:20px;flex-wrap:wrap}.report-options select{display:block;margin-top:7px}.report-actions{display:flex;justify-content:flex-end;gap:12px;margin-top:20px}.report-status{white-space:pre-wrap;overflow-wrap:anywhere;font-size:14px}.report-status[data-state="error"]{color:#ffb3a1}.report-status[data-state="success"]{color:#91e3cb}</style>
<header><h1>Raul's Mod · Feature Gallery</h1><p>Actual game models and gameplay. Camera orbits show appearance; mechanic demonstrations show real work. Island and focused-yard captures are labelled. This gallery includes current models and does not claim that every design is fully polished.</p>'''
    page += f'<p class="count">{sum(e["type"]=="image" for e in items)} images · {sum(e["type"]=="video" for e in items)} clips · {total/1024/1024:.1f} MB. Images ≤720p; clips ≤720p at 30 fps. Newest additions first.</p><div class="filters"><select id="media-type" aria-label="Media type"><option value="all">All media</option><option value="image">Pictures only</option><option value="video">Videos only</option></select><select id="category" aria-label="Category"><option>All</option>{options}</select><input id="search" type="search" maxlength="500" placeholder="Find a part or feature" aria-label="Find a part or feature"><button id="report-general" type="button">Make a report</button></div></header><main>'
    page += ''.join(cards) + r'''</main>
<dialog id="report-dialog" aria-labelledby="report-title"><form id="report-form"><h2 id="report-title">Report a problem</h2><p id="report-context"></p><label for="report-text">What should be fixed?</label><textarea id="report-text" required maxlength="10000" placeholder="Describe what looks wrong or what happened."></textarea><div class="report-options"><label for="report-type">Type<select id="report-type"><option>Bug</option><option>Visual</option><option>Feature</option><option>Performance</option><option>Audio</option><option>Other</option></select></label><label for="report-severity">Severity<select id="report-severity"><option>Low</option><option selected>Medium</option><option>High</option><option>Critical</option></select></label></div><p class="report-status" id="report-status" role="status" aria-live="polite"></p><div class="report-actions"><button id="report-cancel" type="button">Cancel</button><button id="report-submit" type="submit">Save report</button></div></form></dialog>
<script>
const category=document.querySelector('#category'),search=document.querySelector('#search'),mediaType=document.querySelector('#media-type');
const cards=Array.from(document.querySelectorAll('article'));
const reportDialog=document.querySelector('#report-dialog'),reportForm=document.querySelector('#report-form'),reportText=document.querySelector('#report-text'),reportStatus=document.querySelector('#report-status'),reportSubmit=document.querySelector('#report-submit'),reportCancel=document.querySelector('#report-cancel');
let reportContext={},reportBusy=false;
const observer=new IntersectionObserver(entries=>{for(const entry of entries){const video=entry.target;if(entry.isIntersecting&&!video.closest('article').hidden&&!reportDialog.open){const source=video.querySelector('source');if(!source.hasAttribute('src')){source.src=source.dataset.src;video.load();}video.play().catch(()=>{});}else video.pause();}},{threshold:0.15});
for(const video of document.querySelectorAll('video'))observer.observe(video);
function filter(){for(const card of cards){card.hidden=(mediaType.value!=='all'&&card.dataset.type!==mediaType.value)||(category.value!=='All'&&card.dataset.category!==category.value)||!card.dataset.search.toLowerCase().includes(search.value.toLowerCase());const video=card.querySelector('video');if(video){if(card.hidden)video.pause();observer.unobserve(video);observer.observe(video);}}}
category.addEventListener('change',filter);mediaType.addEventListener('change',filter);search.addEventListener('input',filter);
function currentSnapshot(card){if(!card)return;const media=card.querySelector('video')||card.querySelector('img');if(!media)return;const width=media.videoWidth||media.naturalWidth,height=media.videoHeight||media.naturalHeight;if(!width||!height||(media.tagName==='VIDEO'&&media.readyState<2))return;try{const canvas=document.createElement('canvas'),scale=Math.min(1,1280/width,720/height);canvas.width=Math.max(1,Math.round(width*scale));canvas.height=Math.max(1,Math.round(height*scale));canvas.getContext('2d').drawImage(media,0,0,canvas.width,canvas.height);return canvas.toDataURL('image/jpeg',.72);}catch{return;}}
function openReport(card){for(const video of document.querySelectorAll('video'))video.pause();reportContext={};let context='General game report. Your notes will be saved in the game report inbox.';if(card){const video=card.querySelector('video');reportContext.media_id=card.dataset.id;if(video&&Number.isFinite(video.currentTime))reportContext.video_time=video.currentTime;const snapshot=currentSnapshot(card);if(snapshot)reportContext.screenshot=snapshot;context=card.querySelector('h2').textContent;if(video)context+=' · clip at '+(reportContext.video_time||0).toFixed(2)+' seconds';context+='\nThe selected capture and your notes will be included.';}document.querySelector('#report-context').textContent=context;reportText.value='';document.querySelector('#report-type').value=card?'Visual':'Bug';document.querySelector('#report-severity').value='Medium';reportStatus.textContent='';reportStatus.dataset.state='';reportSubmit.disabled=false;reportCancel.disabled=false;reportCancel.textContent='Cancel';reportDialog.showModal();reportText.focus();}
for(const button of document.querySelectorAll('[data-report]'))button.addEventListener('click',()=>openReport(button.closest('article')));
document.querySelector('#report-general').addEventListener('click',()=>openReport());
reportCancel.addEventListener('click',()=>reportDialog.close());
reportDialog.addEventListener('cancel',event=>{if(reportBusy)event.preventDefault();});
reportDialog.addEventListener('close',()=>{for(const video of document.querySelectorAll('video')){observer.unobserve(video);observer.observe(video);}});
async function serviceRequest(path,options={}){const controller=new AbortController(),timeout=setTimeout(()=>controller.abort(),6000);try{let response;try{response=await fetch('http://127.0.0.1:8765'+path,{...options,headers:{'X-Gallery-Report':'1',...options.headers},signal:controller.signal,cache:'no-store'});}catch{const error=new Error('Open OpenGallery.cmd in this folder, then send again.');error.connection=true;throw error;}const data=await response.json();if(!response.ok)throw new Error(data.error||'The report could not be saved.');return data;}finally{clearTimeout(timeout);}}
reportForm.addEventListener('submit',async event=>{event.preventDefault();if(reportBusy||reportSubmit.disabled)return;const text=reportText.value.trim();if(!text){reportText.focus();return;}reportBusy=true;reportSubmit.disabled=true;reportCancel.disabled=true;reportStatus.dataset.state='';reportStatus.textContent='Saving report…';try{const health=await serviceRequest('/api/health');if(!health.ok||health.service!=='raulsmod-feature-gallery'||typeof health.token!=='string')throw new Error('Open OpenGallery.cmd in this folder, then send again.');const result=await serviceRequest('/api/report',{method:'POST',headers:{'Content-Type':'application/json','X-Gallery-Token':health.token},body:JSON.stringify({...reportContext,text,type:document.querySelector('#report-type').value,severity:document.querySelector('#report-severity').value,filters:{media_type:mediaType.value,category:category.value,search:search.value}})});if(!result.ok||!result.id||!result.folder)throw new Error('The report could not be saved.');reportStatus.dataset.state='success';reportStatus.textContent='Saved to the game report inbox.\n'+result.folder;reportCancel.textContent='Close';}catch(error){reportStatus.dataset.state='error';reportStatus.textContent=error.message||'The report could not be saved.';reportSubmit.disabled=false;}finally{reportBusy=false;reportCancel.disabled=false;}});
</script></html>'''
    (OUT / "index.html").write_text(page, encoding="utf-8")


def add(args):
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", args.id):
        raise ValueError("Use a simple lowercase feature id.")
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9 _-]*", args.category):
        raise ValueError("Use a plain category name.")
    folder = OUT / args.category
    folder.mkdir(parents=True, exist_ok=True)
    item = dict(id=args.id, category=args.category, title=args.title, caption=args.caption,
                added_at=datetime.now(timezone.utc).isoformat(timespec="microseconds"))
    if args.command == "image":
        dest = folder / (args.id + ".webp")
        with Image.open(args.source) as image:
            image = ImageOps.exif_transpose(image).convert("RGB")
            image.thumbnail((1280, 720), Image.Resampling.LANCZOS)
            image.save(dest, "WEBP", quality=80, method=6)
        item["type"] = "image"
    else:
        dest = folder / (args.id + ".mp4")
        inputs = ["-ss", str(args.start), "-i", args.source]
        if args.command == "frames":
            files = sorted(glob.glob(args.source), key=lambda p: [int(n) if n.isdigit() else n.lower() for n in re.split(r"(\d+)", p)])
            if not files:
                raise ValueError("No source frames match.")
            files = files[int(args.start * args.input_fps):int((args.start + args.duration) * args.input_fps)]
            temp = ROOT / ".claude/tmp/gallery_encode"
            temp.mkdir(exist_ok=True)
            concat = temp / (args.id + ".ffconcat")
            lines = ["ffconcat version 1.0"]
            for file in files:
                path = Path(file).resolve().as_posix().replace("'", "'\\''")
                lines += [f"file '{path}'", "option framerate 120", f"duration {1/args.input_fps:.9f}"]
            lines += [f"file '{path}'", "option framerate 120"]
            concat.write_text("\n".join(lines) + "\n", encoding="utf-8")
            inputs = ["-safe", "0", "-f", "concat", "-i", str(concat)]
        factor = 2 if args.upscale else 1
        filters = f"setpts={args.slow_motion}*PTS,scale=w='min(1280,iw*{factor})':h='min(720,ih*{factor})':force_original_aspect_ratio=decrease:force_divisible_by=2,pad=1280:720:(ow-iw)/2:(oh-ih)/2,fps=30"
        audio = ["-an"]
        if args.keep_audio:
            if args.command != "video" or args.slow_motion != 1:
                raise ValueError("Keep audio requires a video source at its recorded playback speed.")
            audio = ["-map", "0:v:0", "-map", "0:a:0", "-c:a", "aac", "-b:a", "48k", "-ac", "1"]
        subprocess.run([ffmpeg(), "-y", "-hide_banner", "-loglevel", "error", "-threads", "2", "-filter_threads", "1", *inputs, "-t", str(args.duration), "-vf", filters,
                        "-c:v", "libx264", "-threads", "2", "-preset", "fast", "-crf", "28", "-maxrate", "700k", "-bufsize", "1400k", "-pix_fmt", "yuv420p", *audio, "-movflags", "+faststart", str(dest)], check=True)
        poster = folder / (args.id + "-poster.webp")
        subprocess.run([ffmpeg(), "-y", "-hide_banner", "-loglevel", "error", "-threads", "2", "-filter_threads", "1", "-i", str(dest), "-frames:v", "1", "-c:v", "libwebp", "-threads", "2", "-quality", "75", str(poster)], check=True)
        item.update(type="video", poster=poster.relative_to(OUT).as_posix())
        if args.slow_motion != 1:
            item["caption"] += f" Playback at {1/args.slow_motion:g}× speed."
    item["file"] = dest.relative_to(OUT).as_posix()
    if getattr(args, "proof", None):
        item["source_proof"] = args.proof
    items = [e for e in entries() if e["id"] != args.id]
    items.append(item)
    rebuild(items)
    print(json.dumps({"file": str(dest), "bytes": dest.stat().st_size}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest="command", required=True)
    subs.add_parser("rebuild")
    for command in ("image", "video", "frames"):
        sub = subs.add_parser(command)
        sub.add_argument("source")
        for option in ("id", "title", "category", "caption"):
            sub.add_argument("--" + option, required=True)
        sub.add_argument("--proof")
        if command != "image":
            sub.add_argument("--keep-audio", action="store_true", help="Preserve recorded game audio as compact mono AAC (video sources only).")
            sub.add_argument("--upscale", action="store_true", help="Double compact captures within the 720p limit.")
            sub.add_argument("--start", type=float, default=0)
            sub.add_argument("--duration", type=float, default=6)
            sub.add_argument("--input-fps", type=float, default=30)
            sub.add_argument("--slow-motion", type=float, default=1)
    args = parser.parse_args()
    rebuild() if args.command == "rebuild" else add(args)


if __name__ == "__main__":
    main()

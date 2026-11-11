import 'dart:convert';

String faceUploadPage(String memberName, String groupName) {
  // Direction: a photo-album utility, calm and specific. Member identity is
  // the focal point; the app's oshi pink marks the one upload action.
  // Craft guidance: Unslop by Damir Sokolovsky, CC BY 4.0.
  const escape = HtmlEscape();
  return '''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer"><title>录入成员脸照 · OTA Counter</title>
<style>
:root {color-scheme:light dark;font:17px/1.6 system-ui,sans-serif;background:#f6f4f2;color:#1d1b26}
body {max-width:560px;margin:0 auto;padding:48px 24px} .eyebrow {color:#625e70;font-size:16px;font-weight:400}
h1 {font-size:28px;font-weight:600;line-height:1.3;margin:12px 0} p {color:#675f6c} .member {font-size:22px;font-weight:600;margin:24px 0 4px}
label {display:block;border:2px dashed #7b7590;border-radius:16px;padding:28px 20px;margin:24px 0;cursor:pointer}
input {display:block;max-width:100%;margin-top:14px;font-size:16px}
button {font:inherit;font-weight:600;background:#d3245f;color:white;border:0;border-radius:12px;padding:16px 24px;width:100%;cursor:pointer}
button:disabled {opacity:.5;cursor:default} #status {white-space:pre-wrap;overflow-wrap:anywhere} small {font-size:15px;color:#625e70} :focus-visible {outline:3px solid #5b4be0;outline-offset:4px} button:hover:not(:disabled) {background:#b51c50} input::file-selector-button {min-height:44px;font:inherit;padding:8px 12px;cursor:pointer}
@media(prefers-color-scheme:dark){:root{background:#19151e;color:#f3edf5}p,small{color:#c2b7c9}.eyebrow{color:#c9c1da}button{background:#ff7aa8;color:#2a0a18}button:hover:not(:disabled){background:#ff95b9}}
</style></head><body>
<div class="eyebrow">OTA Counter</div><h1>录入成员脸照</h1>
<div class="member">${escape.convert(memberName)}</div><small>${escape.convert(groupName)}</small>
<p>选择清晰、正面的成员照片。每次最多 10 张，多人合照优先按可信相似度识别；否则仅在最大脸面积至少为次大脸的 1.5 倍时选择，无法判断会报告失败。</p>
<form id="upload"><label for="photos">选择照片<input id="photos" type="file" accept="image/*" multiple required></label>
<p><small>图片仅在本机浏览器压缩为长边不超过 1600 像素的 JPEG；上传后需在 App 中同步才会录入。</small></p>
<button id="submit" type="submit">上传并等待 App 同步</button></form>
<p id="status" role="status" aria-live="polite"></p><small>链接 24 小时有效，累计最多上传 10 张。服务器收到 App 处理回执后删除图片，超过 7 天的未处理图片会定期清理。</small>
<script>
'use strict';
const params = new URLSearchParams(location.search);
const uploadToken = params.get('token');
// Keep the capability out of browser history and subsequent referrers.
history.replaceState(null, '', location.pathname);
const form = document.getElementById('upload');
const photos = document.getElementById('photos');
const status = document.getElementById('status');
const submit = document.getElementById('submit');
async function compress(file) {
  const url = URL.createObjectURL(file);
  try {
    const image = new Image();
    await new Promise((resolve, reject) => {image.onload=resolve;image.onerror=()=>reject(new Error('无法读取图片，请选择 JPEG 或 PNG'));image.src=url;});
    const scale = Math.min(1, 1600 / Math.max(image.naturalWidth, image.naturalHeight));
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.round(image.naturalWidth * scale));
    canvas.height = Math.max(1, Math.round(image.naturalHeight * scale));
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(image, 0, 0, canvas.width, canvas.height);
    return await new Promise((resolve, reject) => canvas.toBlob(blob => blob ? resolve(blob) : reject(new Error('图片压缩失败')), 'image/jpeg', 0.9));
  } finally {URL.revokeObjectURL(url);}
}
form.addEventListener('submit', async event => {
  event.preventDefault();
  const files = Array.from(photos.files);
  if (!uploadToken) {status.textContent='链接无效，请从聊天中重新打开上传链接。';return;}
  if (!files.length || files.length > 10) {status.textContent='请选择 1 至 10 张照片。';return;}
  submit.disabled=true;photos.disabled=true;
  let uploaded=0;
  const messages=[];
  try {
    for (const file of files) {
      status.textContent='正在处理第 ' + (uploaded+1) + '/' + files.length + ' 张…';
      const blob = await compress(file);
      // Relative path preserves /ota-sync without trusting proxy headers.
      const response = await fetch(location.pathname, {method:'POST',headers:{'Authorization':'Bearer '+uploadToken,'Content-Type':'image/jpeg'},body:blob,referrerPolicy:'no-referrer'});
      const result = await response.json();
      if (!response.ok) throw new Error(result.error || '上传失败，请稍后重试');
      uploaded++;
      messages.push('第 '+uploaded+' 张已排队');
      // Remove successful files so a retry cannot duplicate queued photos.
      const remaining = new DataTransfer();
      files.slice(uploaded).forEach(item => remaining.items.add(item));
      photos.files=remaining.files;
    }
    status.textContent='已上传 '+uploaded+' 张。请打开 OTA Counter → MCP 同步 → 一键同步，再回到聊天查询录入结果。';
  } catch(error) {
    status.textContent=messages.join('；')+(uploaded?'。':'')+error.message+'。尚未上传的照片可重试。';
  } finally {submit.disabled=false;photos.disabled=false;}
});
</script></body></html>''';
}

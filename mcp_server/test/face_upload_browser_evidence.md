# 脸照上传 DOM/API 验证记录

以下为本次 Playwright 交互式调用的原始代码和结果摘要；它们不是已保存、可直接执行的一体化自动测试脚本。使用 `dart mcp_server/test/face_upload_browser_fixture.dart` 启动本地合成服务；该服务每次随机分配端口，将 `/ota-sync` 前缀剥除并转发到 `SyncHttpServer`，刻意令第二次 POST 返回 503。记录中的 50586 是当次端口。无真实图片或凭据。测试服务现已停止。

## 初始化与11张限制

Playwright `browser_run_code_unsafe`：

```js
async (page) => {
  await page.setViewportSize({width:390,height:844});
  await page.goto('http://127.0.0.1:50586/start');
  return {title:await page.title(), path:await page.evaluate(()=>location.pathname),
    queryCleared:await page.evaluate(()=>location.search==='')};
}
```

结果：路径 `/ota-sync/face-upload`，`queryCleared: true`。随后用以下页面代码生成 3000×2000 合成图片、设置11个文件并记录实际 JPEG 编码调用：

```js
async (page) => page.evaluate(async () => {
  const c=document.createElement('canvas'); c.width=3000; c.height=2000;
  const x=c.getContext('2d'); x.fillStyle='#e4afcd'; x.fillRect(0,0,3000,2000);
  x.fillStyle='#634476'; x.fillRect(300,300,1200,1000);
  const blob=await new Promise(r=>c.toBlob(r,'image/png'));
  const files=new DataTransfer();
  for(let i=0;i<11;i++) files.items.add(new File([blob],`synthetic-${i}.png`,{type:'image/png'}));
  const p=document.querySelector('#photos'); p.files=files.files;
  p.dispatchEvent(new Event('change',{bubbles:true}));
  const old=HTMLCanvasElement.prototype.toBlob; window.testBlobCalls=[];
  HTMLCanvasElement.prototype.toBlob=function(cb,type,quality){
    window.testBlobCalls.push({width:this.width,height:this.height,type,quality});
    return old.call(this,cb,type,quality);
  };
  return {fileCount:p.files.length,viewport:innerWidth,scrollWidth:document.documentElement.scrollWidth};
});
```

结果：`fileCount:11`。点击“上传并等待 App 同步”后读取 `#status` 和 `window.testBlobCalls.length`，分别为 `请选择 1 至 10 张照片。` 和 `0`。这是通过 DataTransfer 设置文件，并未测试操作系统文件选择器。

## 局部失败及重试

将上述列表切至前两张，然后运行：

```js
async (page) => {
  await page.getByRole('button',{name:'上传并等待 App 同步'}).click();
  await page.waitForFunction(()=>document.querySelector('#status').textContent.includes('尚未上传的照片可重试'));
  return page.evaluate(async()=>({status:document.querySelector('#status').textContent,
    remaining:document.querySelector('#photos').files.length, calls:window.testBlobCalls,
    server:await (await fetch('/test-state')).json()}));
}
```

结果：`第 1 张已排队。合成故障，请重试。尚未上传的照片可重试。`；`remaining:1`；服务端队列 `["enroll_face"]`，图片数 1。两次编码均为 `{width:1600,height:1067,type:"image/jpeg",quality:0.9}`。

继续运行：

```js
async (page) => {
  await page.getByRole('button',{name:'上传并等待 App 同步'}).click();
  await page.waitForFunction(()=>document.querySelector('#status').textContent.startsWith('已上传'));
  return page.evaluate(async()=>{
    const b=await (await fetch('/test-image')).blob();
    const image=await createImageBitmap(b);
    const bytes=new Uint8Array(await b.arrayBuffer());
    return {status:document.querySelector('#status').textContent,
      remaining:document.querySelector('#photos').files.length,
      stored:{mime:b.type,width:image.width,height:image.height,jpegMagic:bytes[0]===255&&bytes[1]===216},
      calls:window.testBlobCalls,server:await(await fetch('/test-state')).json(),
      queryCleared:location.search===''};
  });
}
```

结果：提示 `已上传 1 张。请打开 OTA Counter → MCP 同步 → 一键同步，再回到聊天查询录入结果。`，`remaining:0`；队列恰有两个 `enroll_face`、图片数 2，表明重试未重复排队第一张。`stored` 为 `{mime:"image/jpeg",width:1600,height:1067,jpegMagic:true}`；第三次 `toBlob` 同样传入 `image/jpeg` 与 `0.9`。质量值是浏览器编码 API 入参，不是从 JPEG 文件反推的独立质量测量。服务端存储图片经测试专用 `/test-image` 端点返回并由浏览器解码。

三次 POST 的 fixture 记录均为 `{path:"/ota-sync/face-upload",hasQuery:false,hasReferer:false,authBearer:true}`；无 token 内容输出。

## 服务端累计上限

```sh
dart mcp_server/test/face_upload_browser_cli_test.dart
```

实际结果：1–10 次上传各返回 201，第 11 次返回 409，队列恰好 10 个 `enroll_face`，存储 10 个合成字节流；MCP 链接包含前缀，页面响应设置 `no-referrer`。这是 HTTP 测试，使用合成 JPEG 标记字节，不用于证明图片解码或压缩。

原始交互式调用没有保存成独立可一键运行的 Playwright 测试；上述代码与结果为可定位的执行记录。未重新进行视觉检查。

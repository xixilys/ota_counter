# 从 Mac 文件夹批量录入成员脸照

`tool/face_inbox_import.py` 用 Python 3 标准库实现，扫描本机文件夹，把照片以
`image_base64` 调用同步服务的 MCP `enroll_face`，排队给 App 处理。

## 目录约定

默认扫描 `~/.ota-counter/face-inbox/`。每个子文件夹是一个成员：

```
face-inbox/
├── 小雪/                 # 只有成员名
│   ├── 01.jpg
│   └── 02.png
├── 小雪@甲团/            # 同名成员用 @团名 区分
│   └── 03.jpeg
├── done/                 # 成功后自动移动到这里
└── failed/<原因>/         # 失败后按原因分目录
```

支持 jpg/jpeg/png/webp/gif/bmp/heic/heif。单张原图或 base64 编码超过 8 MB 会跳过并提示；
全部图片都不可用或服务端报错（如成员重名、找不到成员）时，整个文件夹移到
`failed/<中文原因>/`。部分图片已成功排队、之后某张报错时也会移入 failed，重试前先检查。

## 运行

```bash
# token 从环境变量读取（推荐）
export OTA_SYNC_TOKEN='<TOKEN>'
python3 tool/face_inbox_import.py

# 或从文件读取；不要把 token 写进命令行参数或聊天
python3 tool/face_inbox_import.py --token-file ~/.ota-counter/token

# 自定义目录 / MCP 地址
python3 tool/face_inbox_import.py \
  --inbox ~/Pictures/face-inbox \
  --server https://sub.lyszqx.love/ota-sync/mcp

# 只看会发什么，不联网、不需要 token、不移动文件夹
python3 tool/face_inbox_import.py --dry-run
```

脚本不会打印 token，也不把 token 放进 URL；服务端只接受
`Authorization: Bearer` 头。排队成功后仍需打开 App → MCP 同步 → 一键同步，
之后可在聊天里用 `list_face_enrollments` 查结果；每人最多保留 30 个样本，
`samples_kept` 可能为 0。

测试：`python3 -m unittest discover tool/tests`

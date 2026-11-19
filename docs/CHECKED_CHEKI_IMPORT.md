# 导入已核对切图（本地附图，不补记账）

全局「切册 → 右上角切册操作 → 导入已核对切图」选择本地 ZIP。
成员私册不提供入口。预览显示已有流水编号、日期、卡名、团体、照片和稳定卡号，
以及整包/各流水的照片数、待附图数和重复数。确认前不写数据。

确认后仅调用 `DatabaseService.saveBatchImport(newRecords: [], media: ...)`：
只加媒体行及切图文件，不新增/删除流水，不增减计数，不覆盖旧照片，不导入备份。
日期/卡名/团体或归属有任一冲突时整包阻止导入；修正包后重新选择。

## ZIP 约定

推荐文件名 `checked-cheki-example.zip`；文件名不参与身份核对。
ZIP 根目录直接放 `manifest.json`（UTF-8 JSON），图片名称只用 ASCII 字母、数字、`_-.`：

```text
manifest.json
sources/original-01.jpg
cards/example-001.jpg
```

```json
{
  "format": "ota-checked-cheki",
  "version": 1,
  "cards": [
    {
      "card_id": "example-001",
      "record_id": 123,
      "date": "2026-11-15",
      "subject": "流水的 subjectName 原文",
      "group": "流水的 groupName 原文",
      "image": "cards/example-001.jpg",
      "source": "sources/original-01.jpg",
      "source_sha1": "0123456789abcdef0123456789abcdef01234567",
      "quad": {
        "tlx": 10, "tly": 20,
        "trx": 310, "try": 20,
        "blx": 10, "bly": 470,
        "brx": 310, "bry": 470
      }
    }
  ]
}
```

- `record_id`：手机现有流水的正整数主键；支持切数及多人流水，不接受门票流水。
- `date`：该流水 `occurredAt` 的年月日，严格 `YYYY-MM-DD`。不按照片 EXIF、凌晨 06:00 或时区换日。
- `subject`：该流水 **卡名 `subjectName`**，不是 `personName` 真人主档名。
- `group`：该流水 `groupName`；字段必须存在，值允许空字符串。
- 上述三个字段逐字核对已有流水，不做别名、大小写、空白或模糊名字匹配。
- `card_id`：1–96 个 ASCII 字母、数字、`_-`，首字符须为字母或数字。
  必须跨重新打包保持不变，建议批次前缀 + 序号。卡号不能重用于别的照片或流水。
- `image`：人工已核对、已处理好的切图，位于 `cards/`；应用不会再次裁切或识别。
- `source`：生成该切图的原始图片，位于 `sources/`；多张卡可共享原图。
- `source_sha1`：**原始图片文件字节**的 SHA1，40 位小写十六进制。应用读取 source 实际计算并核验，
  不能填切图哈希。source 仅参与本地验证，不另存入相册。
- `quad`：EXIF 转正后的原图像素坐标，固定键 tl/tr/bl/br 的 x/y；非负、凸四边形、不得交叉或越界。
  整图一张卡时四角是 `(0,0) / (width-1,0) / (0,height-1) / (width-1,height-1)`。
  图片必须是小写扩展名 `.jpg` / `.jpeg` / `.png` 的有效单帧 JPEG/PNG。

这个包没有计数、流水修改、备份、远程协议或人脸训练字段。
应用能验证原图字节、框选范围和目标流水；切图内容是否对应所声明的原图区域，由打包前的人机核对负责。

## 重复与身份

已存 `sourceHash` 保持现有语义：原图 SHA1。照片身份为原图 SHA1 + quad 固定键顺序、
1/10000 像素精度的规范化坐标，JSON 数字写成整数或小数不影响核对。
稳定卡号保存在 `cropQuadJson` 的 `_checked_card_id` 元数据，不增加数据库表。

同图重打 ZIP、重选文件、包内重复条目、预览后重复确认均跳过；确认前会重新检查数据库。
照片或卡号已用于另一流水/成员时提示冲突，整包不写入。
已有相同原图但没有可解析 quad 的老照片会提示无法核对，不擅自加图。
旧图没有 sourceHash 时无法据原图身份核对；本导入能力不回写、重算或修改旧图元数据。

owner 校验遵循现有身份语义：`ownerPersonName` 可以是 `identityName` 真人主档名，
不能直接与 manifest 卡名相比。明确不同的 ID、跨团和不属于该流水身份的名字仍然冲突；
缺少 ID 时只接受流水或其明确关联成员卡上的卡名/主档名，不按相似姓名推断归属。

## ZIP 安全边界

压缩包 ≤128 MiB，清单 ≤1 MiB，单图片 ≤32 MiB，总展开 ≤256 MiB，1–128 张卡，
图片 ≤2400 万像素。最多 257 个文件及可选的 `cards/`、`sources/` 两个目录项。
拒绝绝对路径、路径穿越、重名条目、未声明文件、链接/特殊文件、加密、分卷和非 Store/Deflate 压缩。
先检查 ZIP 文件头及声明大小，再限量流式展开，并核对实际长度和 CRC；ZIP 不解压到磁盘。
解析、哈希及图片验证在 isolate 中执行；预览缩略图按小尺寸解码。

## 验证

```bash
flutter test test/checked_cheki_import_test.dart
flutter test test/album_page_test.dart --plain-name 'checked ZIP import'
flutter analyze lib/services/checked_cheki_import_service.dart \
  lib/pages/album/checked_cheki_import_page.dart test/checked_cheki_import_test.dart
```

隔离 DB 测试覆盖有效挂图及旧图保留、计数/流水全部字段不变、重复/过期预览/并发确认、
卡号冲突、跨成员归属、legacy sourceHash/quad、目标变化、非法包/大小限制/CRC/路径/链接/加密，
以及本地 picker → 预览分组及照片 → 确认 → 返回的真实页面路径。
P2 回归另覆盖卡名≠主档名的同 ID/缺 ID 重复跳过，以及跨团、不同 ID、无关联名字拒绝。

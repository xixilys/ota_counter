# 2026-11-08 拍立得「自动记录」实拍验证

用主人当天 4 张桌面实拍（桌上平铺多张拍立得）跑通生产管线，回答一个问题：
**现在能不能"拍一张 → 自动变成记录"？**

结论：**不能。** 现在的批处理是「切卡 + 认人 + 人工复核」的加速器，不是自动记录。
本次 14 张卡里，能自动判定的 0 张。

## 实测数据

切入 4 张桌面照（`OTA_CHEKI_DIR`），切卡结果：

| 照片 | 切出 | 真值（主人确认） | 警告 | 缺口位置 |
|------|------|----------------|------|----------|
| desk1 | 6 | **8** | possiblyMerged | x≈669–906，约 1.5 张卡宽 |
| desk2 | **3** | **7** | possiblyMerged | x<454 与 x>1018 两头都空 |
| desk3 | **4** | **5** | possiblyMerged | x≈376–527，正好一张卡宽 |
| desk4 | 1（整帧，uncertain 0.51） | 1（手持单张） | — | — |

合计 21 张，切出 14 张，**漏检 7 张（33%）**。漏检不是随机位置：整行里出现
「正好一到两张卡宽」的空洞，即挨得紧或有重叠的那几张被整段跳过，而不是切歪。

## 修复：被邻居挡住 ≠ 不是一张卡

四张漏掉的卡，拒绝日志签名完全一致：

```
outer_reject seen=2 evidence=30.9,0.0,15.8,0.0 blocked=0101 score=1.000
```

`blocked=0101` = 左右两条边被相邻窗口挡住（证据自然是 0），上下两条边证据很强。
旧规则要求「至少 3 条边可见」，于是整张卡被丢掉 —— 不是没找到，是判得太严。

`lib/services/record_scan_service.dart` 的 `_outerFrame` 判据改为：

- 被挡的必须是**对面**两边（`(s1 + 2) % 4 == s2`），且可见的两边都要达到 `strongEvidence`；
- 相邻两边被挡（2×2 棋盘格的中间卡）仍然拒绝，保住既有「不猜切」的保守行为。

修复后：

| 照片 | 修前 | 修后 | 真值 |
|------|------|------|------|
| desk1 | 6 | 7 | 8 |
| desk2 | 3 | 6 | 7 |
| desk3 | 4 | 5 | 5 |
| desk4 | 1 | 1 | 1 |

`test/record_scan_multi_test.dart` 16 项全过（含「2×2 粘连不猜切」「near-white 不切」）。

剩下 2 张没有继续放宽：它们都是只有 1 条边可见的窗口（desk1 那张 128px 宽、夹在两张
已检出的卡之间；desk2 那个只有 59px 宽，更像是碎片）。再放宽会把碎片切成假卡，
收益不确定、风险确定，所以停在 19/21。

desk4 是手持单张，退回整帧是设计内的兜底，正确。
desk2 / desk3 漏检，且都带 `possiblyMerged`。

认人（备份恢复 → `learnFromArchive` 自举 11 条样本/6 人）：

| 状态 | 张数 | 说明 |
|------|------|------|
| auto | **0** | 没有一张达到自动阈值 |
| review | 4 | 给出候选（小树 ×2、小雪、淅璃Kiko） |
| unknown | 10 | 其中 2 张根本检测不到脸 |

两条路径的差距：

- 全自动落库：`buildSavePlan` 要求每张卡都指定成员，有 10 张未认出时直接抛
  `StateError('还有 N 张没有指定成员或团体')` —— **全自动在结构上就跑不通**。
- 确认后写入：14 张都要人过一遍，其中 4 张只需点确认，10 张要手动选人。

## 复现

```bash
# 1) 切卡
OTA_CHEKI_DIR=/path/to/desk_photos OTA_CHEKI_CROPS=/path/to/crops \
  flutter test test/cheki_desk_probe_test.dart

# 2) 生成人脸参考（OpenCV YuNet + SFace-int8，与 App 引擎同管线）
python3 tool/face_reference.py /path/to/crops /path/to/crops_reference.json
python3 tool/face_reference.py /path/to/activity_record_media /path/to/media_reference.json

# 3) 恢复到备份状态 + 自举样本 + 逐卡认人
OTA_REAL_BACKUP=/path/to/backup.zip \
OTA_ARCHIVE_REFERENCE=/path/to/media_reference.json \
OTA_CHEKI_CROPS=/path/to/crops \
OTA_CHEKI_REFERENCE=/path/to/crops_reference.json \
  flutter test test/cheki_recognize_probe_test.dart
```

两个探针在没有环境变量时自动 skip，不影响 `flutter test`。

## 待修（按影响排序）

1. **团切样本被白白丢掉**。`learnFromArchive` 只收单脸照片：23 张档案照片里 12 张
   是双人团切，直接 `not_single_face` 丢弃。这些照片里已认出成员的脸完全可以
   作为正样本。样本从 11 条涨到 20+ 条，是本次识别率最大的杠杆。
2. ~~**切卡漏检**~~ 已修一半：被邻居挡住一对边的卡不再被丢（21 张里 14 → 19）。
   仍剩 2 张只有单边证据的窗口，需要真机视觉确认是卡还是碎片后再定。
3. **全自动没有落地路径**。要么允许部分卡跳过保存，要么给"先记账、后补人"
   的录入模式，否则永远要人守着。
4. **候选集太宽**。当天没有票/记录时 `dayMembers` 为空，回退到全部 18 位成员，
   误配概率高。批量导入应结合当天的票/演出名单收窄。

## 注意

- 人脸特征**不随备份导出**（`export_import_service.dart` 里刻意排除，属于生物数据）。
  恢复备份后必须先「从已归档照片学习」，否则样本为 0。
- 本人（self）样本在本次备份里也是 0，所以"照片里的你会自动去掉"这条同样不生效。
- 探针里 `size` 全是 `threeInch` 是构造 `BatchCard` 时的占位，真实管线用切卡结果，
  不要据此判断尺寸识别。


## 验证状态（2026-11-08）

- `flutter analyze`：No issues found。
- `flutter test`：238 通过 / 7 跳过 / 1 偶发失败。失败的是
  `test/identity_reconciliation_test.dart`，并行负载下 30 s 超时，单独跑 2 s 通过，
  与本次切卡改动无关（它不走扫描管线）。同类偶发还有 `test/quick_count_save_test.dart`。
  这两个都属「固定等待 + 并发负载」问题，值得单独修一次，别当成功能失败。

## 2026-11-09 认人续查

**残留的 2 张确认是真卡**（看过原图）：desk1 漏的是第 5 张（蓝裙子），desk2 漏的是第 3 张
（女仆装）。切出的 19 张都没有切歪。

**小图放大后再检测脸**。切出的卡只有约 150×240 像素，脸约 25 像素，YuNet 容易漏检。
App 只会缩小大图，不会放大小图。`FaceDetectorOptions.minDetectSide = 480`：长边不足 480 的
图先做双线性放大再检测（`FaceImageOps.enlargeSize` / `resizeLinear`），
`tool/face_reference.py` 同步（`OTA_FACE_MIN_SIDE`，默认 480）。

| 放大策略 | 19 张里检测到脸的卡 |
|---|---|
| 不放大（旧） | 14 |
| 长边 480 双线性 | **16** |
| 长边 640 双线性 | 15 |

剩下 3 张检测不到，脸被手或涂鸦挡住（desk2#5、desk3#3），或者是手持整帧（desk4）。

**分辨率影响有，但不是主因**。拿备份里已知身份的单人照，缩到长边 240 后做留一法：
不放大时 5 张里有 2 张检测不到脸，放大到 480 后都能检出，只错 1 张。
同一人的相似度一般在 0.60–0.77，领先第二名 0.08–0.32。

**这批卡认不出，主要因为人不在样本库里**。样本只有 3–4 月的 6 个人，11 张照片。
今天的卡里，只有 desk3#0、desk3#1 指向小雪（0.63 / 0.70，领先 0.21 / 0.26），
落在同一人的分数区间。其余「待确认」都是第一、二名几乎打平（领先 0.01–0.07），
预选的成员等于随机猜。真值还没核对。

### desk1 真值与「待确认」预选门槛

主人给的 desk1 真值（左→右）：终到站·一绪、终到站·盈盈（含 ota）、酥酥_Cherishffon、
酥酥（含 ota）、小鸟Torine_Cherishffon（漏切那张）、骷KuKuro-NiiCORE、终到站·透、终到站·一绪。
8 人都不在 19 个成员里；偶像库里也没有终到站、Cherishffon、NiiCORE 这三个团。

这样一来，desk1 原来 3 张「待确认」预选（小树、小树、小叽）全错，领先第二名只有 0.07/0.02/0.02。
新增 `FaceMatchThresholds.reviewMargin = 0.08`：分数低于自动线 0.60、且领先「本卡其他脸没占用的
成员」不到 0.08 时，不预选，只列候选。

| 数据 | 改前 | 改后 |
|---|---|---|
| 今天 19 张卡的错误预选 | desk1 3 张 + desk2 2 张 + desk3#4 | 0（只剩 desk3#0/#1 预选小雪，待核对） |
| 备份留一法（全部成员候选） | 自动对 11 / 错 0 / 待确认 7 / 未认出 5 | 自动对 11 / 错 0 / 待确认 5 / 未认出 7 |

留一法里变成「未认出」的两张，本人在样本库里都没有样本（原预选必错），认对的一张没丢。

同一人在卡之间的相似度：酥酥两张 0.71（认得出）；一绪两张 0.17（一张严重过曝，认不出）。

### 全部真值与「录进去以后能认多准」

真值（主人提供，私人数据，只存在仓库外）：desk2 = Liumoo、優晴Yu1na(StarX)、早间月(真夜中ELF)、
申夜Shinya(StarX)、兔兔Miottie(ReCream)、Liumoo、第 7 张待定；desk3 = 小雪、小雪、優晴Yu1na、
起源Chika(ReCream)、兔兔Miottie。偶像库查不到的终到站Terminus（一绪/盈盈/透）、Cherishffon（酥酥/小鸟Torine）、
NiiCORE（骷Kukuro）已加进 `assets/data/manual_idols.json`。

desk3 的两张「小雪」预选是对的。

假设今天的人都已录入、每人只有另一张卡当样本，做留一法：14 张有脸的卡第一名认对 12 张。
错的 2 张是一绪（一张过曝，两张互相只有 0.17）。区分度：酥酥 0.71、小雪 0.71、本人 0.43–0.60
（明显高于对别人的 0.23–0.33）；兔兔 0.64 对 0.60、Liumoo 0.48 对 0.46，能认对但领先很小，
需要多积累几张样本。

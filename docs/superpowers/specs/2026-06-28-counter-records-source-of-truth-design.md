# 计数器记录单一真相源重构 — 设计文档

**日期：** 2026-06-28
**分支：** codex/v1.3-prep
**目标版本：** v1.5.0（schema v17）
**状态：** 已确认设计，待编写实现计划

---

## 背景与症状

用户反馈两类数据完整性 bug：

1. **多人切串号**：成员"兔"的切出现在"萝北"名下；删除其中一个，另一个也消失。
2. **总数漂移**：神秘的 -9 记录；删除后总数偏差；用户强制添加补偿记录才让总数对上，但月度统计又少了 9。打地鼠式 bug。

**用户核心直觉**："总数应该是可以直接计算出来的。"

## 根因（已通过代码调查确认）

**双真相源 + 非事务性双写。**

- `counters` 表存储**反规范化的计数列**（`count`、`three_inch_count`、`five_inch_count` 等）。
- `activity_records` 表存储**独立记录**。
- 每次增/删/改都做**非事务性双写**：先 `counter.count += delta` + `updateCounter()`，再 `insertActivityRecord()`。任一半失败或中途崩溃 → 永久漂移。
- **多人切**是**单条共享行**，含 `multi_participants_json` 参与者列表；通过**名字字符串匹配**(`_findCounterForParticipantIn`，member_detail_page.dart:351)解析到计数器，无稳定 ID → 删除一人波及另一人。

## 核心设计决策（已与用户确认）

| # | 决策 | 选择 |
|---|------|------|
| 1 | 真相源 | `activity_records` 为唯一真相源；`counters.count*` 降级为只读缓存（重建专用，绝不增量写） |
| 2 | 多人切模型 | 拆成**每人一行**，由共享 `group_record_id` 关联；用稳定 ID(`counter_id`/`person_id`)匹配，不用名字 |
| 3 | 全局总览计数 | 多人切**按事件去重**算 1 张（按 `group_record_id` 去重） |
| 4 | 成员卡片计数 | 每个参与成员**各 +1**（成员卡片之和 > 全局总数，符合"每人都切到一张"直觉） |
| 5 | 遗留无记录计数器 | v17 迁移回填 `system_adjustment` 记录补足差额，标记 `is_system_adjustment=1` |
| 6 | system_adjustment 与周期统计 | system_adjustment 记录**计入总数但排除出月/周/年周期统计**（代表期初余额，非某期活动） |
| 7 | 用户手动 -9 补偿记录 | **保留不动**，不自动删除用户历史 |
| 8 | 发布方式 | OTA 自动迁移：用户更新到新 APK 首次启动时自动跑 v17，迁移前**强制备份** `counter_app.db` |
| 9 | 执行顺序 | ① Bug 修复 → ② 性能优化 → ③ UI 美化 |

## 架构方案

### 数据流（修复后）

```
写路径（增/删/改记录）：
  单条 sqflite 事务 {
    仅修改 activity_records
    （可选）事务内重建受影响 counter 的缓存列
  }

读路径（卡片/统计）：
  从 activity_records 计算总数
  - 成员卡片：按 counter_id/person_id 聚合，多人切每人计入
  - 全局总览：按 group_record_id 去重多人切
  - 周期统计：按 occurred_at 过滤 + 排除 is_system_adjustment
```

### Schema v17 变更

`activity_records` 新增列：
- `group_record_id TEXT`（多人切同组关联；单人/门票为 NULL 或自身唯一 ID）
- `is_system_adjustment INTEGER NOT NULL DEFAULT 0`（迁移回填/期初余额标记）

迁移步骤（`onUpgrade` v16→v17，事务内）：
1. **备份**：迁移前复制 `counter_app.db` → `counter_app.db.v16.bak`（在 `database` getter 打开前执行，文件级复制）。
2. **加列**：`ALTER TABLE activity_records ADD COLUMN group_record_id TEXT` + `is_system_adjustment`。
3. **拆分多人切**：遍历 `record_type='multi'` 行，为每个参与者生成一条新行，共享 `group_record_id`（用原 id 派生），用参与者的稳定 ID 填 `counter_id`/`person_id`；删除原共享行。
4. **回填遗留计数器**：对每个 counter，比较存储总数 vs 从（拆分后的）records 派生的总数；差额生成 `is_system_adjustment=1` 的 `counter` 类型记录，`occurred_at` 设为一个历史锚点（如 epoch 或计数器创建时间）。
5. **重建缓存列**：从 records 重算每个 counter 的 `count*` 列写回（一次性，事务内）。

### 受影响代码（重写目标）

| 文件 | 变更 |
|------|------|
| `lib/services/database_service.dart` | schema 升版 v17 + onUpgrade 迁移；新增 `recalculateCounterTotals()`；写路径包事务；移除增量计数写 |
| `lib/models/activity_record_model.dart` | 新增 `groupRecordId`、`isSystemAdjustment` 字段 + toMap/fromMap；`multiCut` 工厂改为产出参与者行集合（或新增 `multiCutRows()`） |
| `lib/models/counter_model.dart` | `count*` 改为派生语义（保留字段作缓存，文档标注只读） |
| `lib/main.dart` | `_applyRecordCounterImpact` 移除；总览按 group_record_id 去重；成员聚合用稳定 ID |
| `lib/pages/member_detail_page.dart` | `_findCounterForParticipantIn` 改用稳定 ID；删除/编辑改事务化、不波及他人 |
| `lib/pages/chart_page.dart` | 周期统计排除 is_system_adjustment；多人切按 group_record_id 处理 |

## 测试策略

用模拟脏数据验证迁移与新逻辑：
- 遗留无记录计数器（存储计数但无 records）→ 迁移后总数不变
- 多人切拆分 → 删一人不影响另一人；全局去重算 1 张；成员各 +1
- 用户 -9 补偿记录 → 保留
- 总数 = 派生计数（无漂移）
- 月度统计排除 system_adjustment
- 跨团/改名场景的稳定 ID 匹配

## 风险

- **不可逆本地迁移**：强制备份是必须的安全网。
- **迁移逻辑 bug 损坏数据**：充分的迁移测试在发版前本地验证（含真实导出数据样本）。
- **缓存列残留**：过渡期保留 `count*` 但仅重建写，绝不增量写。

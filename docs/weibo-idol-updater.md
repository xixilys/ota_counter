# 微博偶像资料 updater（本机定时模板）

用于在 Mac 上定期运行独立脚本 `tool/weibo_idol_updater.py`，辅助维护 OTA Counter 的偶像资料。它与现有 `tool/generate_china_idols_seed.py`（Wiki + 人工补充）、`tool/validate_china_idols_seed.py` 及服务器端种子定时任务分开，不替换现有任务。

**本文只提供文档与模板，不执行安装与发布。本次 dry-run 已获用户授权；实际安装、部署及发布由主人之后批准执行。**

## 选择规则与 a–f 自动护栏

候选来自线上演出名单最近 90 天的已发生演出，以北京时间计算日期，不包含未来场次。团体必须有数字微博 UID；去掉团名末尾 `official`，忽略大小写、空格、下划线、连字符和间隔点后，与线上种子已有团名做包含匹配，匹配到的团不选。候选按 UID 和规范化团名去重。

排除只看 Wiki 和人工补充的团：本脚本自己补进种子的团（来源标记为“微博自动补充”）仍会每 7 天重新检查一次，用来补上新加入的成员。

优先选择从未检查的团，其次按上次检查时间从旧到新轮换；距离上次检查未满 **7 天**的团跳过。默认每次最多检查 `--limit 25` 团。正常写入轮次只为完成检查且未触发单团超限、未遗漏长文的团记录检查时间；普通单团请求或提取失败、长文未补全的团不进入冷却，后续仍可重试。dry-run 不更新任何冷却记录。

每团读取 profile 和首页 timeline，优先使用成员关键词及置顶帖，有预算时补全长文；通过 `dsh --profile headless -` 提取候选，再执行以下 a–f 自动护栏：

- **a．名字须逐字出现在原文。** 清理后的名字必须逐字出现在抓到的正文中；不猜测或改写无法确认的名字。长文未补全时整篇排除，不拿截断摘要提取；其他完整帖子仍可用于提取。
- **b．校验名字。** 去掉开头 `@` 和可识别的末尾团名后缀；名字长度须为 1–20 个字符，不能包含网址，不能是团名或“官方”“运营”“成员”等常见噪声词。
- **c．只保留正式或见习成员。** 状态只能为“正式成员”或“见习成员”。同一篇完整微博正文同时出现姓名及毕业、前成员、离团等词（包括标题换行），会保守丢弃该姓名，即使其他帖也写在籍；可能因此漏掉同帖中其他在籍成员。
- **d．单团超过 12 人整团丢弃。** 单团提取候选超过 12 人时整团跳过，不截取前 12 人，也不进入冷却。
- **e．种子同名不写，累计结果去重。** 跳过种子已有的同名成员，累计文件和本次提取也去重；不删除或修改已有成员。成员名比较忽略大小写、空格、下划线、连字符和间隔点。累计输出保留来源微博 URL、检查时间及“微博自动补充”来源标记。服务器种子合并时，团名规范化精确匹配优先；无精确匹配且存在多个包含匹配时，该团暂不合并并记录歧义，累计文件保留。
- **f．全轮新增受 `--max-new` 限制。** 单次新增成员上限默认为每团 5 人（`--limit` × 5，默认 125）；超过上限时整轮不写累计输出和 state，也不发布，不截断后写入部分结果。

### 登录、日志与失败写入说明

微博请求之间随机等待 **3–6 秒**。普通单团请求或提取失败时跳过、不进入冷却，继续检查后续团；其他团的有效结果可继续写出。长文未补全（包括预算不足导致缺全文）的团也不进入 7 天冷却，后续仍可重试。

整轮登录失效、请求预算整轮超限或其他写入前的整轮错误，不写输出和 state。检测到登录失效时停止整轮并提示用户在 Edge 重新登录，不自动绕过登录验证。`--dry-run` 不写累计输出、不写 state、不发布，日志仍记录；试跑选出的 5 团不能仅因试跑进入 7 天冷却。

正式运行先写本地文件，再执行发布，因此发布 `scp` 失败时，本地输出和 state 可能已经写入，不能把发布失败等同于本地未写入。远端按用户指定直接用 `scp` 覆盖，传输中断可能影响远端文件，不保证远端原子替换。

日志记录检查团体、提取结果、丢弃与跳过原因、拟新增成员、请求次数及整轮摘要；日志、参数和 plist 不记录 Cookie 值或认证请求头。

后台定时任务（launchd）没有权限读 Edge 的 Cookie 库（macOS 隐私保护，会报 `authorization denied`）。所以每次在终端里成功读到 Edge Cookie 时，updater 会在状态目录存一份仅本人可读（600）的副本 `cookies.lwp`；后台读不到 Edge 时改用这份副本。副本过期或登录失效时，在终端手动跑一次 `--dry-run --limit 1` 就会刷新它。

状态目录中的 `weibo_idols.json` 是累计补充文件，`state.json` 保存轮换检查时间，`logs/` 保存每次运行日志。调试使用下文的 `--dry-run`，不要用正式写入来试验选择结果。

## 运行前准备

- macOS 用户登录会话及 launchd；采用用户级 LaunchAgent，不使用 root/system daemon。
- 本机已使用 `/usr/bin/python3`（Python 3.9.6）运行 updater 和测试，且可导入 `requests`、`browser_cookie3`。换机器后重新核对解释器及同一解释器下的依赖。
- 用户已核实 `dsh` 位于 `/opt/homebrew/bin/dsh`。模板 `PATH` 显式包含 `/opt/homebrew/bin` 和 `/usr/bin`，以便找到 `dsh` 和 `scp`；launchd 不继承交互式终端的完整环境。
- Microsoft Edge 中由用户本人完成微博登录。首次读取 Edge 登录状态若出现钥匙串访问弹窗，核对请求来自预期的 Python/updater 后选择“始终允许”，以免后续无人值守任务被弹窗阻塞。
- 安装前核实 `tool/weibo_idol_updater.py` 已交付，并符合本文的选择、写入与发布要求。发布依赖的 `dsh` 目标配置和认证应由用户预先配置；不在 plist 中存储认证材料。

状态目录环境变量统一为 `OTA_WEIBO_IDOLS_DIR`，约定默认 `~/.ota-counter/weibo-idols`。模板中显式设置其绝对路径。下方安装命令会将状态目录及 `logs/` 目录权限设置为 `700`；手动运行不保证默认权限相同，建议使用者按需检查目录及已有文件的权限。日志不得包含 Cookie 值、认证请求头或完整登录材料，不使用打印这些内容的调试方式。

## 启用前先完成服务器接入

服务器当前的旧版 generator / runner **不会读取微博文件**。启用 launchd 前，须由主人批准并自行部署本次修改的 `tool/generate_china_idols_seed.py` 和 `tool/run_idol_seed_update.sh`；本次不执行部署。只上传微博文件不代表它已合并进种子，也不代表 App 已入库。

主人还需自行验证现有服务器 SSH 目标的文件写权限、免交互认证，以及 `dsh` / `scp` 在定时任务环境下能正常工作。不要在未确认权限时修改服务器认证或目录权限。服务器更新上述脚本后，应由主人确认 runner 能读取已发布的微博文件、生成并校验合并后的种子，再确认 App 实际同步到相关资料，之后才启用自动发布。

## 修改模板中的绝对路径

模板位于 `tool/weibo_idol_updater.launchd.plist`，服务 Label 为 `top.huangxuanqi.ota-counter.weibo-idol-updater`。

| 模板值 | 替换内容 |
| --- | --- |
| `__REPO_ROOT__` | 本机仓库绝对路径，本任务为 `/Users/xixilys/orca/workspaces/ota_counter/tunicate` |
| `__HOME__` | 实际运行用户的主目录，例如 `/Users/xixilys` |
| `/usr/bin/python3` | 本机已核实的解释器；换机器后按实际绝对路径替换 |
| `PATH` | 按实际工具安装目录调整，保留能找到 `dsh`、`scp` 的目录 |

launchd 不展开 `~`、`$HOME`、环境变量引用或 shell 表达式。`ProgramArguments` 每个参数各占一项，路径含空格也不额外嵌入引号。不要把 Cookie 放进参数或 `EnvironmentVariables`。若自定义状态目录，须同时调整两项日志路径，并在安装前创建其父目录。

模板在每天**本机当地时间 10:40**执行 Python updater 的 `--publish --limit 25`；不是固定北京时间。`RunAtLoad=false`，加载或登录时不立即执行；没有 `KeepAlive` 重启循环。LaunchAgent 依赖用户登录，关机期间不执行；睡眠中错过的日历触发可能在唤醒后补跑，不能将其视作服务器端全天候定时器。

## 独立手工调试

不需要先安装 launchd。本次 dry-run 已获授权，在终端设置路径，先查看帮助，再使用 `--dry-run` 独立调试。试跑会请求微博，但不写累计输出和 state，不发布；日志仍会记录。

```bash
REPO='/Users/xixilys/orca/workspaces/ota_counter/tunicate'
UPDATER="$REPO/tool/weibo_idol_updater.py"
export OTA_WEIBO_IDOLS_DIR="$HOME/.ota-counter/weibo-idols"
export PATH='/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'
cd "$REPO"
/usr/bin/python3 "$UPDATER" --help
/usr/bin/python3 "$UPDATER" --dry-run --limit 25
```

手工调试时可用 `OTA_WEIBO_MAX_REQUESTS=40` 设置单次请求预算。updater 会为剩余团保留 profile + timeline 请求；额外长文请求耗尽可用预算时，日志说明未补全篇数，整篇排除且该团不进入冷却，不记录 Cookie 值。只对这一条命令设置，避免影响之后的正常运行：

```bash
OTA_WEIBO_MAX_REQUESTS=40 /usr/bin/python3 "$UPDATER" --dry-run --limit 5
```

每团至少需要 profile + timeline 两项基础请求，25 团至少 50 次，因此 40 次预算示例使用 `--limit 5`。定时运行不设置 `OTA_WEIBO_MAX_REQUESTS`，plist 中不添加此变量。

单独获得发布授权、核实选择规则和全部护栏后，才可手工执行与定时模板相同的调用：

```bash
/usr/bin/python3 "$UPDATER" --publish --limit 25
```

登录失效时，先停用已加载的定时任务（见卸载节的 `bootout`），用户本人打开 Edge 并重新登录微博；需要验证码或安全验证时手工完成，不导出、粘贴或输出 Cookie。随后在终端用 `--dry-run --limit 25` 验证登录恢复，再重新加载定时任务。钥匙串弹窗应在有人值守的首次运行中处理，不依赖后台任务替用户登录。

## 安装命令（之后获得安装及自动发布授权才执行）

完成“启用前先完成服务器接入”一节的要求，获得安装及自动发布授权后，才执行以下命令。代码先生成用户目录中的配置副本，**不修改仓库模板**。`REPO` 必须按用户机器替换为仓库绝对路径，`UPDATER` 固定指向其下的 `tool/weibo_idol_updater.py`；核实脚本已交付后再执行。安装完成后，每次定时触发都具有发布效果，不能仅以“测试定时器”为由加载。

```bash
set -e
REPO='/Users/xixilys/orca/workspaces/ota_counter/tunicate'
UPDATER="$REPO/tool/weibo_idol_updater.py"
LABEL='top.huangxuanqi.ota-counter.weibo-idol-updater'
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE="$HOME/.ota-counter/weibo-idols"
test -f "$UPDATER"
test ! -e "$PLIST" # 已有配置时先核对，不覆盖
mkdir -p "$HOME/Library/LaunchAgents"
# launchd 不会自动创建日志父目录，必须在 bootstrap 前创建。
mkdir -p "$STATE/logs"
chmod 700 "$STATE" "$STATE/logs"
/usr/bin/python3 - "$REPO" "$UPDATER" "$PLIST" <<'PY'
import os
import plistlib
import sys
from pathlib import Path

repo, updater, output = map(Path, sys.argv[1:])
assert repo.is_absolute() and updater.is_absolute(), '必须使用绝对路径'
home = Path.home()
with (repo / 'tool/weibo_idol_updater.launchd.plist').open('rb') as stream:
    config = plistlib.load(stream)
config['ProgramArguments'][1] = str(updater)
config['WorkingDirectory'] = str(repo)
state = home / '.ota-counter/weibo-idols'
config['EnvironmentVariables']['OTA_WEIBO_IDOLS_DIR'] = str(state)
config['StandardOutPath'] = str(state / 'logs/updater.stdout.log')
config['StandardErrorPath'] = str(state / 'logs/updater.stderr.log')
with output.open('xb') as stream:
    plistlib.dump(config, stream, sort_keys=False)
os.chmod(output, 0o600)
PY
/usr/bin/plutil -lint "$PLIST"
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl print "gui/$(id -u)/$LABEL"
```

`launchctl print` 只能确认任务已加载及退出状态，不能证明抓取或发布成功。应查看不含 Cookie 的运行摘要与结果；不要用 `kickstart` 随意试跑，它会实际执行 `--publish`。日志文件需定期检查大小，模板未配置自动轮转。

## 停用与卸载（获得对应授权后执行）

暂停但保留配置，只执行 `bootout`；它会停止该任务，运行中时不要在发布中途操作。确认当前没有正在执行的发布后再卸载。

```bash
LABEL='top.huangxuanqi.ota-counter.weibo-idol-updater'
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)" "$PLIST"
# 完全卸载时才执行下行；保留状态、日志和仓库模板。
rm -i "$PLIST"
```

若任务原本未加载，`bootout` 会报错；先核对 `launchctl print "gui/$(id -u)/$LABEL"`，不要把失败当成已经卸载。暂停后恢复使用 `launchctl bootstrap "gui/$(id -u)" "$PLIST"`，同样需要自动发布授权。

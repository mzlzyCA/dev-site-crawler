---
name: "dev-site-crawler"
description: "每日定时爬取 10 家厂商开发者门户的 What's New / Release Notes 内容（NVIDIA 重点，含 Anthropic/OpenAI）。Invoke when 用户要求定时抓取厂商开发者站点更新、查看爬取日志、或维护站点配置。"
---

# Dev Site Crawler

每日定时爬取 NVIDIA / AMD / Qualcomm / Intel / Apple / 昇腾 / 鲲鹏 / Google / Anthropic / OpenAI 10 家厂商开发者门户的 What's New 与 Release Notes 页面，做整页快照 + diff 比对 + 变更页面截图，把"有变化"的内容按日期归档。支持从种子页自动发现并爬取同域子页面。

## When to Use

- 用户说"跑一下爬取"、"抓一下今天的更新"、"看看厂商有什么新动态"
- 用户要求修改爬取站点列表、调整定时时间、查看爬取日志
- 用户要求"重跑某天的爬取"、"清空历史快照"
- 用户要求"爬取范围扩到整个一级域名"、"给变更页面截图"

## Architecture

```
.trae/skills/dev-site-crawler/
├── SKILL.md                          # 本文件
├── config/
│   ├── sites.json                    # 站点配置（公司、URL、提取规则）
│   └── dashboard-strings.json        # 看板中文文案（外置避免 PS5 编码问题）
└── scripts/
    ├── crawl.ps1                     # 主爬取脚本（PowerShell 5 兼容）
    ├── build-dashboard.ps1           # 爬取结束后自动重建 HTML 看板
    ├── install-task.ps1              # 注册 Windows 任务计划
    └── uninstall-task.ps1            # 卸载 Windows 任务计划

dev-site-crawls/                       # 数据输出根目录（运行时自动创建）
├── index.html                         # 可视化看板（每次爬取后自动重建）
├── crawl-YYYY-MM-DD.log               # 每日运行日志
├── summary/YYYY-MM-DD.md              # 每日更新汇总（bullet point，方便人看）
├── nvidia/
│   ├── developer/
│   │   ├── snapshots/YYYY-MM-DD.md    # 当日整页快照（保留 60 天，自动清理）
│   │   ├── changes/YYYY-MM-DD.md      # 与上一次的差异（仅在有变化时生成）
│   │   ├── changes/YYYY-MM-DD.png     # 变更页面长截图（仅真实内容变更时生成）
│   │   ├── latest.md                  # 最近一次抓取内容（diff 基准）
│   │   └── pages/<page-slug>/         # 子页面数据（crawl=true 时）
│   │       ├── snapshots/ changes/ latest.md
│   ├── cudnn/
│   ├── cuda/
│   ├── nim/
│   └── llms-txt/
├── amd/
├── qualcomm/
├── intel/
├── apple/
├── ascend/
├── kunpeng/
├── google/
├── anthropic/
└── openai/
```

## 默认执行时间

每天 02:00 由 Windows 任务计划程序触发 `crawl.ps1`。

任务计划已开启防漏抓设置（2026-11-14/15 曾因机器睡眠漏抓）：

- `StartWhenAvailable`：错过 02:00（关机/睡眠）后，开机或唤醒时尽快补跑
- `WakeToRun`：到点唤醒计算机
- 电池模式下也允许启动、运行中切电池不中断
- `S4U` 登录类型：**不管用户是否登录都要运行**，无需存储密码（注册需管理员权限，`install-task.ps1` 会自动弹 UAC 自提升；已在无桌面会话下实测 16 站全部抓取成功）

## 站点配置

修改 `config/sites.json` 即可增删站点，无需改脚本。每个站点包含：

- `company`：公司归类（用于创建一级子目录）
- `name`：站点标识（用于二级子目录）
- `url`：抓取 URL（种子页）
- `crawl`（可选，默认 false）：`true` 时从种子页提取同域子页面链接并逐页抓取
- `maxPages`（可选，默认 6）：子页面抓取数量上限（不含种子页）
- `scope`（可选，默认 `host`）：子页面链接范围
  - `host`：只爬种子页同主域的链接（如 `developer.nvidia.com` 下的页面）
  - `domain`：爬整个一级域名（registrable domain）下的链接（如 `nvidia.com` 所有子域）

子页面爬取行为：

- 从种子页 HTML 提取所有 `href`，过滤静态资源（css/js/图片/压缩包等）、隐私/登录类页面、锚点与跳转协议链接
- URL 解析为绝对路径后按 scope 过滤、去重、按字母排序（保证每天抓取集合稳定）
- 每个子页面独立维护 `pages/<page-slug>/` 下的 snapshots / changes / latest.md，与种子页同一套 diff + 截图逻辑
- page-slug 由 URL 的 host+path 规范化生成（非字母数字折叠为 `-`，最长 70 字符）
- 子页面间抓取间隔 1 秒（polite pacing）

## Diff 策略

1. 抓取页面 HTML → 转文本（剥 script/style，块级标签转行，多空行折叠）
2. 保存为 `snapshots/YYYY-MM-DD.md`（每日都留快照，不覆盖；快照保留 60 天，到期自动清理，diff 与 latest.md 永久保留）
3. 与 `latest.md` 做行级 diff（按行集合比对，新增行 `+`、删除行 `-`）
4. 若有差异：差异写入 `changes/YYYY-MM-DD.md`，更新 `latest.md`
5. 若无差异：仅留快照，不生成 changes 文件

## 变更截图

页面发生**真实内容变更**（非首次基线抓取）时，自动用 headless Edge/Chrome 截一张长图：

- 输出路径 `changes/YYYY-MM-DD.png`，与当日 diff md 同目录同名
- 浏览器自动定位：优先 Edge（Windows 10/11 自带），其次 Chrome；两者都找不到则记 WARN 跳过截图，不影响 diff
- 参数：`--headless --window-size=1280,2400 --virtual-time-budget=10000`（JS 页面留 10 秒虚拟时间渲染），独立 `--user-data-dir` 避免与日常浏览器会话冲突
- 截图失败（如目标站在该网络不可达）只记 WARN，不影响爬取主流程

### 防假变更机制（重要）

以下机制保证"CHANGE detected"只反映页面真实内容变化：

- **latest.md 只存正文（body-only）**：header 里的 `Fetched` 时间戳不参与 diff，否则每天全站点误报变更
- **自解码原始字节**：不信任 PS5 对 charset 的自动猜测（常猜错产生 mojibake）。从 `RawContentStream` 读原始字节，UTF-8 优先解码，U+FFFD 过多时回退 GB18030，避免中文乱码假 diff
- **不可见字符归一化**：NBSP (U+00A0) → 空格，零宽字符 (U+200B) / BOM 直接删除，避免页面只翻转隐形字符就误报
- **空响应/限流处理**：部分站点（如 intel.cn）限流时会返回 HTTP 200 + 空 body。视为可重试错误：重试 1 次（间隔 8 秒），仍失败则记 `ERROR` 日志并跳过，绝不静默失败
- **重试**：网络异常（超时、连接失败）同样重试 1 次

## 执行命令

### 手动跑一次

```powershell
powershell -ExecutionPolicy Bypass -File .trae\skills\dev-site-crawler\scripts\crawl.ps1
```

### 注册定时任务

```powershell
powershell -ExecutionPolicy Bypass -File .trae\skills\dev-site-crawler\scripts\install-task.ps1
```

### 卸载定时任务

```powershell
powershell -ExecutionPolicy Bypass -File .trae\skills\dev-site-crawler\scripts\uninstall-task.ps1
```

### 查看任务状态

```powershell
schtasks /query /tn "DevSiteCrawler-Daily" /v /fo list
```

## Output Format

每个快照文件头部包含元信息：

```markdown
# {site-name}

- URL: https://...
- Fetched: 2026-11-11_02-00-13
- Company: nvidia

---

{页面正文}
```

每个 diff 文件结构：

```markdown
# Diff for {site-name} on 2026-11-11

- URL: https://...
- Compared: 2026-11-11_02-00-13

## Added lines

+ 新增的内容行

## Removed lines

- 被删除的内容行
```

### 每日更新汇总 `summary/YYYY-MM-DD.md`

每天爬取完成后自动生成，按公司分组的 bullet point 总览，方便人快速浏览今日更新要点：

```markdown
# Daily Dev-Site Update Summary - 2026-11-11

- Fetched: 2026-11-11_02-00-13
- Stats: OK=13 FAIL=3 CHANGED=11
- Companies with changes: 7

---

## nvidia

### cuda

- Added CUDA 12.6 Update 3 release notes
- Fixed cuBLAS performance regression on H100
- ... 5 more added lines, see changes/2026-11-11.md

### nim

- New NIM container version 1.3.0 published
- Supported model list updated: added Llama 3.3 70B

## amd

### rocm-release-notes

- ROCm 6.3.1 hotfix released
- ...

## intel

### oneapi-toolkit-rn

- __First-time capture, baseline only, no diff info__
```

要点：
- 只列出 `## Added lines` 区段中长度 ≥5 的行（过滤噪音）
- 每个站点最多展示 20 条，超出会输出 "... N more added lines, see changes/..."
- 首次抓取的站点会标注 `__First-time capture, baseline only, no diff info__`
- 完全无变化的站点不出现在汇总里
- 全英文输出，避免 PowerShell 5 在中文环境下编码问题

### 可视化看板 `index.html`

每次爬取结束后（summary 生成之后）自动由 `build-dashboard.ps1` 重建，纯静态无 JS 依赖，浏览器直接打开即可：

- **按日期倒序**：最新日期置顶，当日有真实更新的页面排在前面（按新增行数降序），噪音类条目排最后
- **每日折叠分组**：最新一天默认展开，其余日期默认收起；每组 summary 行显示"N 个页面有更新 / N 无变化 / N 失败"
- **变更摘要**：从 diff 的 Added lines 自动蒸馏出最多 5 条有意义的标题级条目（过滤日期行、超短/超长噪音行）；首次抓取的子页显示基线提示
- **分类标签**（规则式，基于路径/URL/新增行关键词自动匹配）：
  - `最新博客`：路径含 blog
  - `产品发版`：新增行含 release/hotfix/released
  - `新产品发布`：新增行含 launch/announce/introducing/now available
  - `文档改版`：docs 域名或新增行 ≥40
  - `模型更新`：Claude/GPT/Gemini/Llama 等模型发布、弃用、模型清单/定价变更
  - `社区 AI 相关`：MCP、Agent、RAG/检索、工具调用、插件等开发者可用的 AI 能力
  - `AI 产品`：NIM/TensorRT/Megatron/Cosmos 等 AI 平台产品栈、显卡 AI 特性（DLSS 等）
  - `活动资讯` / `站点资讯` / `噪音`（纯模板/cookie 类变更）
  - 子页面额外带灰色 `子页` 标识，首次收录带 `首次收录` 标识
- **页面直达图标**：每条变更右侧外部链接图标（↗），点击新标签页打开原始页面；旁边 "Diff →" 链接查看本地差异文件
- **Diff 直达链接**：每条变更可跳转对应的 changes/*.md
- **无变化/失败分组**：每日底部折叠展示，默认收起不占篇幅
- 所有中文文案外置于 `config/dashboard-strings.json`（脚本本体保持 ASCII，规避 PS5 中文编码问题）
- 手动重建：`powershell -ExecutionPolicy Bypass -File .trae\skills\dev-site-crawler\scripts\build-dashboard.ps1`

## 注意事项

- PowerShell 5 兼容（不依赖 PS 7 特性）
- 启用 TLS 1.2 以避免部分站点握手失败
- User-Agent 使用桌面 Chrome UA（部分站点对非常规 UA 返回 403/空响应）
- 抓取超时 60 秒，网络异常或空响应自动重试 1 次，仍失败则记 ERROR 日志跳过，不中断其他站点
- 部分站点（如 Apple Developer）可能依赖 JS 渲染，抓到的是初始 HTML，仅做 best-effort
- 若站点长期 404/403，优先在 `config/sites.json` 换官方可访问的 changelog/release notes URL，而非放宽脚本容错
- 站点变更历史：`intel/onemkl-whatsnew` → `intel/oneapi-toolkits`（intel.cn docs 路径 403）；`google/gemini-api-changelog` 原 generative-ai-python 仓库 CHANGELOG 已废弃 404，现用官方 `ai.google.dev/gemini-api/docs/changelog`

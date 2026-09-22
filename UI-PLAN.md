# pi-emacs 界面美化与可读性提升计划

目标：让 `*pi-code:<project>*` 聊天缓冲区的**结构更清晰、信息密度更合理、长时间阅读不累**，
同时参考 Claude Code / opencode / aider / Cursor 等 coding agent 的通用做法。

约束：只改渲染层（`pi-code-chat.el` 为主，`pi-code.el` 少量），不动 `pi-code-rpc.el` 的协议逻辑；
不改动现有 ERT 断言所依赖的标记（`## You`、`## pi`、`▸`、`└`）；对新依赖（如 markdown-mode）做可选降级。

---

## 0. 现状问题清单（基于当前代码）

| # | 位置 | 问题 |
|---|------|------|
| A | `pi-code-chat.el:22` | `pi-code-user-face` 定义了但**从未使用**，`## You` 实际没有 face，纯默认色 |
| B | `pi-code--render-user` 等 4 处 | `## You` 渲染逻辑重复，样式散落，难以统一 |
| C | 全篇 | 消息之间没有**视觉分隔**，用户/助手/工具混在一起 |
| D | `pi-code--handle-event` tool_execution_start | 工具参数是**原始 JSON 一行**，超 300 字符被 `…` 截断，几乎不可读 |
| E | `pi-code--format-tool-result` | 结果多行时后续行**没有缩进**，看不出层级 |
| F | `pi-code--ev-message-update` | thinking 只有斜体，没有标签，容易和正文混淆；`thinking_start/end` 未处理 |
| G | `pi-code--update-header` | header line 信息少、无 face、无 session 名/thinking level/队列/耗时 |
| H | 全局 | 助手正文**完全不渲染 Markdown**：代码块、列表、加粗、标题都是纯文本 |
| I | 全局 | 没有代码块语法高亮、没有 diff 高亮（`write`/`edit` 结果） |
| J | 全局 | 文件路径不可点击、无跳转 |
| K | 全局 | 长工具输出不能折叠，只能整段铺满 |
| L | `pi-code--handle-event` | `queue_update`、`bash_execution_update`、`extension_error`、`summarization_retry_*` 被静默忽略 |
| M | `pi-code--dispatch-ui-request` | 未实现 `setTitle` |
| N | `pi-code--open-chat` | 空缓冲区没有任何 welcome / 键位提示，首次打开很空 |
| O | 输入区 | 输入与历史没有边界标识，看不出"从哪开始打字" |
| P | 全局 | 没有 spinner，`● working` 是静态的 |
| Q | `pi-code--format-tool-result` | 只有文字截断，没有"还有 N 行 / 查看完整输出"的折叠入口（`details.truncation`、`fullOutputPath` 可用） |

---

## 1. 参考实现调研（取长补短）

| 参考 | 值得借鉴的做法 | 在 Emacs 里的对应手段 |
|------|----------------|----------------------|
| **Claude Code** | `⏺` 工具圆点、`⎿` 结果树、工具输出默认折叠并可展开、底部状态栏（model / ctx% / cost）、thinking 暗色斜体、todo widget | text property + `invisible`、`header-line-format`、`setWidget` 渲染 |
| **opencode** | 消息按块渲染、Markdown、语法高亮代码块、彩色 diff、状态栏 | `markdown-mode` 的 font-lock、`diff-mode`、`font-lock` on fenced code |
| **aider** | 明确的分隔线、彩色 unified diff、token/费用统计 | `pi-code-separator-face`、diff 上色、header line 统计 |
| **Cursor / Cline** | 每条消息卡片化、工具块可折叠、文件链接可点、inline diff | `magit-section` 风格折叠、`button`/`link` 文本属性、`diff-mode` |
| **Continue** | 助手正文 Markdown + 代码块语言高亮 | 同 opencode |
| **Emacs 生态** | `magit` 的 section 折叠、`eshell` 的 prompt、`comint` 的 input field、`org` 的 fringe/ellipsis | `invisible`+`isearch-open-invisible`、`field` 属性、`read-only` |

---

## 2. 设计目标与原则

1. **分层视觉**：turn 分隔 > 角色头 > 正文 > 工具调用 > 工具结果 > thinking > meta 通知，用 face + 缩进 + 前缀符号分层。
2. **默认克制**：分隔线/图标用 `shadow` 系浅色，不抢正文；颜色全部**继承标准 face**，跟随用户主题（不硬编码颜色）。
3. **可折叠**：长工具输出默认收起尾部，提供展开/收起键与鼠标点击。
4. **可点击**：文件路径、URL、工具名做成 button。
5. **渐进增强**：markdown-mode / diff-mode 缺失时自动降级为纯文本，不报错。
6. **流式安全**：markdown 只在 `message_end` 时字体化整段，避免每个 delta 重新解析；流式中保持纯文本追加。
7. **不破坏测试**：保留 `## You`/`## pi`/`▸`/`└`，并新增针对新样式的 ERT。

---

## 3. 分阶段计划

### Phase 1 — 基础：face 调色板 + 模式设置 + 欢迎条（低风险，先落地）

- 新增/整理 faces（全部 `:inherit` 标准 face，加 `:extend t`）：
  - 已有：`user` / `assistant` / `thinking` / `tool` / `error` / `meta`
  - 新增：`pi-code-thinking-label-face`、`pi-code-tool-args-face`、`pi-code-tool-result-face`、
    `pi-code-separator-face`、`pi-code-banner-face`、`pi-code-header-brand-face`、
    `pi-code-header-model-face`、`pi-code-header-busy-face`、`pi-code-prompt-face`、
    `pi-code-code-face`、`pi-code-diff-add-face`、`pi-code-diff-del-face`、`pi-code-file-link-face`
- **修复 A**：`## You` 真正使用 `pi-code-user-face`。
- `pi-code-chat-mode`：`word-wrap t`；可选 `visual-line-mode`（评估与 evil 的按键冲突后再定）。
- 新增 `pi-code--session-name` buffer-local；`pi-code--open-chat` 与 `pi-code-new-session` 都插入 welcome banner
  （项目名 + 常用键位提示），历史 marker 在其后建立。
- 统一渲染入口，消除 B：
  - `pi-code--insert-user`（分隔线 + 角色头 + 正文）
  - `pi-code--insert-assistant-header`
  - `pi-code--insert-thinking`（标签 + 内容）
  - `pi-code--insert-tool-call`（名称 + 参数）
- 验收：`M-x pi-code` 打开即有欢迎条；`## You` 有色；ERT 全绿。

### Phase 2 — 结构与留白：turn 分隔 + 角色头 + 时间

- turn 之间插入宽度自适应的浅色分隔线（`window-body-width` 上限 100）。
- 角色头增加可选时间戳（`pi-code-show-timestamps` defcustom，默认 t 或 nil 待定）。
- 助手头 `## pi` 后可选显示模型短名。
- 长行换行时用 `wrap-prefix` 做悬挂缩进，避免续行顶格。
- 验收：连续多轮对话时能一眼区分 turn。

### Phase 3 — 工具调用/结果可读性（收益最大）

- `pi-code--format-tool-args`：把 plist 参数渲染为多行缩进 `key: value`，不再一行 JSON。
- `pi-code--indent-lines`：工具结果首行 `  └ `，续行 4 空格对齐；错误用 `pi-code-error-face`。
- 按 `toolName` 映射前缀图标（如 bash `$`、read `📄`、write/edit `✎`、grep/search `⌕`，未知用 `▸`）。
- 运行中显示 `◐ running`，结束显示 `✔` / `✖`，live 替换保持现有 `pi-code--replace-live` 机制。
- 结果折叠：超过 `pi-code-tool-result-lines`（如 15 行）时只显示前 N 行 + `… 还有 M 行（TAB/点击展开）`，
  用 `invisible` + `isearch-open-invisible` 实现；`details.truncation` / `details.fullOutputPath` 存在时给出提示。
- 文件路径/URL 做成 `button`，点击打开文件（`find-file-other-window`）或浏览器。
- 验收：`bash`、`read`、`write`、`edit`、`grep` 输出层级清晰、可折叠、可点击。

### Phase 4 — Markdown 与代码/diff 渲染

- 为助手正文加 `markdown-mode`（gfm）字体化：
  - `message_end` 后对整段区域调用 `markdown-fontify-region`（或 `gfm-mode` 的 font-lock）。
  - 开启 `markdown-fontify-code-blocks-natively`，让 fenced code 用对应 major mode 高亮。
  - 缺少 markdown-mode 时降级：仅用简单正则给 `inline code`、``` 围栏 ``` 上 face。
- diff 渲染：`write`/`edit` 工具结果若含 unified diff，识别后按行上 `diff-add/diff-del` face
  （或用 `diff-mode` 的 `diff-font-lock-keywords`）。
- 代码块的 `pi-code-code-face` 加浅背景（`:extend t`）与等宽。
- 性能：只对"已结束"的消息字体化，流式期间纯文本；超过阈值的超长消息可跳过 markdown。
- 验收：代码块有高亮、列表/标题/加粗正确、diff 红绿可辨。

### Phase 5 — 状态栏与进度反馈

- 重写 `pi-code--update-header`：分段 propertize
  `pi · <session> · <model> · <thinking> · ◐ spinner · ctx 30% (60k/200k) · tokens · $cost · <ext status> · <queue>`。
- 流式期间用 timer 驱动 spinner（`◐◓◑◒` 或 `⠋⠙⠹…`），空闲停止。
- 处理 `queue_update`：在 header 或输入区上方显示 `queued: N`（steering / follow-up 分开）。
- 处理 `bash_execution_update`：直接渲染到对应命令的工具块。
- `compaction_end`：显示 `context compacted: 150k → 32k`。
- `auto_retry_*` / `summarization_retry_*`：统一成 `[retry 2/3 in 2s]` 样式通知。
- `extension_error` 落到 notices。
- 实现 `setTitle`：更新 buffer name / frame title。
- 验收：状态栏信息完整、spinner 转起来、队列可见。

### Phase 6 — 输入区与交互增强

- 输入区加 `> ` prompt 前缀与 `pi-code-prompt-face`；用 `field` 属性界定 input 区域，
  `C-c C-c` 只在 input 区工作。
- 键位：
  - `TAB` 折叠/展开光标处工具块
  - `C-c C-o` 打开光标处文件
  - `C-c C-y` 复制最近一次回复/代码块
  - `M-n`/`M-p` 在 turn 之间跳转（基于 outline headings 或 imenu）
- 可选 `outline-minor-mode`，把每个角色头当 heading，支持折叠整轮、imenu 目录。
- 可选 transient menu（`pi-code-menu`）聚合 model/thinking/session/resume/compact。
- 验收：定位、复制、折叠都有顺手的键。

### Phase 7 — 可选增强

- 内联图片：attachment / 图片型 tool result 用 `create-image` 插入。
- 窗口布局：diff/大文件用 `display-buffer-alist` 放到侧窗。
- `pi-code-theme`：预置一套配色（可选）。
- 空状态提示、错误态友好文案。

---

## 4. 关键技术点

- **折叠**：区域文本加 `(invisible t)` + 覆盖层 `…`（`before-string`/`after-string`），
  配合 `isearch-open-invisible` 与一个 toggle 函数；避免用 `outline` 抢占 `TAB`。
- **Markdown 字体化**：`markdown-fontify-region` 对 read-only 区域是安全的；
  需 `(let ((inhibit-read-only t)) ...)` 才能加 face（`font-lock-ensure` 也可）。
- **流式**：`text_delta` 期间不做 markdown；`message_end` 时对 `[start,end]` 区域一次性字体化。
- **点击**：`(make-text-button ...)` 或 `put-text-property 'button`；注意 read-only 与 `rear-nonsticky`。
- **性能**：`pi-code--display-cap` 之外新增"超长消息跳过 markdown"阈值；字体化在 `with-silent-modifications` 中做，避免污染 undo。

---

## 5. 测试与验收

- 保持现有 4 个 ERT 文件全绿（尤其 `## You`/`## pi`/`▸`/`└` 计数断言）。
- 新增 `test/pi-code-render-test.el`：
  - 工具参数多行格式不乱码、plist 含嵌套值时可读
  - 结果续行缩进正确
  - 折叠：默认 hidden、toggle 后 visible
  - `pi-code--session-name` 与 header 各段存在
  - `queue_update` 渲染
  - `setTitle` 更新 buffer name
  - 无 markdown-mode 时降级不报错（`cl-letf` 模拟）
- 手工 checklist：新会话、流式回复、thinking、bash 长输出、write diff、abort、compaction、
  resume、extension dialog、图片。

---

## 6. 风险与取舍

| 风险 | 缓解 |
|------|------|
| markdown-mode 未安装 | 作为可选依赖，降级为轻量正则 |
| 字体化大段文本卡顿 | 只在 message_end 做，设阈值，`with-silent-modifications` |
| `invisible` 折叠与 isearch/evil 交互 | 用 `isearch-open-invisible`，TAB 只在工具块内生效 |
| 图标/emoji 字体不齐 | 优先用 ASCII/box-drawing（`▸ └ ✔ ✖ ◐`），emoji 可选开关 |
| 分隔线宽度随窗口变化不更新 | 接受静态宽度；或提供 `pi-code-refresh-separators` |
| 主题差异导致对比度差 | 全部 `:inherit` 标准 face，不硬编码颜色 |

---

## 7. 建议实施顺序

1. **Phase 1 → 2**（基础 + 结构）：改动小、立即见效、风险低。
2. **Phase 3**（工具块）：可读性收益最大。
3. **Phase 5**（状态栏）：反馈更专业。
4. **Phase 4**（Markdown/diff）：依赖可选项，收益高但需谨慎。
5. **Phase 6 → 7**（交互 / 增强）：锦上添花。

每个 Phase 结束跑一次 ERT 并更新 README 的截图/说明。

---

## 8. 实施进度检查（2026-09-22，第二轮）

检查方式：逐项对照 `pi-code-chat.el` / `pi-code.el` / `test/`，并运行全部 ERT。

- ERT：64/64 通过（`test/pi-code-render-test.el` 41 项，含工具包裹/颜色新增 3 项）。
- 字节编译：无 error，仅 1 条 docstring 宽度警告。

### 已完成

| Phase | 内容 | 证据 |
|---|---|---|
| 1 | 全部新增 face | `defface pi-code-*-face` 齐全 |
| 1 | 修复 A：`## You` 使用 `pi-code-user-face` | `pi-code--insert-user` |
| 1 | welcome banner（`pi · name` + 键位） | `pi-code--insert-banner`，`open-chat` / `new-session` 均调用 |
| 1 | 统一渲染入口 | `--insert-user` / `--insert-assistant-header` / `--insert-thinking` / `--insert-tool-call` |
| 2 | turn 分隔线、时间戳、模型短名、`wrap-prefix` 悬挂缩进 | `pi-code--rule-string`、`pi-code-show-timestamps`、`pi-code-show-model-name` |
| 3 | 多行参数、结果续行缩进、工具图标、`◐/✔/✖`、折叠、URL/路径 button、truncation 提示 | `--format-tool-args`、`--indent-lines`、`--tool-icons`、`--make-fold`、`--linkify-region` |
| 3 | 工具块包裹：header 行 `──` 规则线（上开）+ `└` 结果前缀（下合）；参数键/值分色；`✔` success、`✖` error、`◐` busy | `--insert-tool-line`、`--fill-rule`、`pi-code-tool-key-face` |
| 4 | markdown gfm 字体化 + 降级、diff 红绿、代码块 face、长度阈值、流式期间纯文本 | `--fontify-markdown-full/lite/region`、`--diff-fontify` |
| 5 | spinner 定时器、`queue_update`、`bash_execution_update`、retry 统一、`extension_error` | 均有 |
| 5 | header：session 名 + `ctx 30% (60k/200k)` + `tokens 105k` | `pi-code--update-header`、`--context-label`、`--format-tokens` |
| 5 | `compaction_end` 显示 `150k → 32k` | `pi-code--handle-event` compaction_end |
| 5 | `setTitle` 同步 buffer 名 + buffer-local `frame-title-format` | `pi-code--sync-frame-title` |
| 6 | `> ` prompt + `field` 输入区、TAB 折叠、`C-c C-o`、`C-c C-y`、`M-n/M-p` | 均有，ERT 覆盖 |
| 6 | `outline-minor-mode`（`##` heading，可整轮折叠 / imenu） | `pi-code-chat-mode`、`pi-code-use-outline` |
| 6 | transient menu `pi-code-menu`（`C-c C-a`）+ `pi-code-compact` | `pi-code.el` |
| 7 | 内联图片 `create-image`（含降级标签） | `pi-code--image-placeholder`、`pi-code-inline-images` |
| 7 | 点击文件可用侧窗打开 | `pi-code-open-file-side-window`、`pi-code--link-open` |
| 7 | `pi-code-theme`（独立文件，`load-theme` 可用） | `pi-code-theme.el` |
| 7 | 更完善的空态提示 | `pi-code--insert-banner` 首行提示 |

### 待办（可选，未纳入本轮）

- Phase 7：`display-buffer-alist` 全局注册（当前仅在 `pi-code--link-open` 内按需侧窗）。
- Phase 7：进程意外退出时的聊天内错误态提示（目前只有 `[send failed: …]` 与 stderr 缓冲区）。
- 会话 fork/tree 浏览器、edit diff overlay、`@file`/region 引用、file-change auto-revert。

以上与 README 末尾「Not yet implemented」一致。

---

## 9. 第三轮：默认外观缺陷修复（2026-09-22）

检查方式：通读渲染层并实测 face 继承，逐项修复后跑全部 ERT。

- ERT：69/69 通过（render 新增 5 项：`tool-glyph-column`、
  `tool-result-fold-indent`、`thinking-indent`、`context-face`、
  `header-dedup-project`）。
- 字节编译：`pi-code-rpc` / `pi-code-chat` / `pi-code-theme` / `pi-code`
  全部无 warning、无 error。

### 已修复

| # | 问题 | 修复 |
|---|------|------|
| P0 | `pi-code-code-face` 继承 `highlight`，行内/围栏代码在终端变反色、彩屏变绿底 | 改为只继承 `fixed-pitch`，背景交给 `pi-code-theme` |
| P0 | `pi-code-tool-result-face` 默认 `shadow`，工具输出被压暗难读 | 改为 `default`，正常对比度 |
| P0 | base defface 与 theme 漂移（thinking-label / tool-result / code / 缺 tool-key） | theme 收敛为只覆盖 code/diff 背景，其余以 base 为唯一来源 |
| P0 | `default-directory` 未设为会话 cwd，相对路径不 linkify、点击跳错目录 | `pi-code--open-chat` 设置 `default-directory` |
| P1 | 工具结果续行固定 4 空格，与首行 6/14 列前缀错位 | 续行/`wrap-prefix` 按首行前缀实际宽度对齐 |
| P1 | 折叠占位符固定 4 空格缩进 | overlay 存 `pi-code-fold-indent`，占位符随块对齐 |
| P1 | thinking 正文顶格、与标签无层级 | 标签与正文统一缩进 2 列，流式 delta 同步缩进并清理尾部幽灵行 |
| P1 | 已知识别工具与未知工具的 `▸` 不在同一列 | 固定 4 列图标位 |
| P1 | header 中 session 名与项目名重复 | 同名时省略项目段 |
| P1 | header 的 context 百分比不随用量预警 | 新增 `pi-code--context-face`：≥80% warning、≥95% error |

### 仍待办（下一轮）

- 正文（user/assistant）仍顶格，与缩进的工具/thinking 块层级偏弱（P2 #9）。
- 连续多条 user 消息会插多条分隔线（P2 #10）。
- lite markdown 仍缺列表/引用/链接文字/代码语法高亮（P2 #12）。
- 代码块不 truncate，长行被 `word-wrap` 硬折（P2 #13）。
- diff 仅上色 `+`/`-`，未处理文件边界/上下文行（P2 #14）。
- spinner 仅在 header；banner 键位行偏长；分隔线宽度不随窗口刷新（P2 #16/#17/#19）。

---

## 10. 第四轮：P2 排版与交互细节（2026-09-22）

检查方式：逐项实现后跑全部 ERT 并重新字节编译。

- ERT：74/74 通过（render 新增 5 项：`markdown-lite-extras`、
  `input-prompt-own-line`、`streaming-caret`、
  `consecutive-user-single-rule`、`rule-refresh`）。
- 字节编译：四个文件均无 warning、无 error。

### 已修复

| # | 问题 | 修复 |
|---|------|------|
| P2 #10 | 连续 user 消息各插一条分隔线 | `pi-code--last-turn-role` 去重，连续同角色共用一个规则 |
| P2 #14 | diff 的文件边界行（`diff --git`/`---`/`+++`/`index`/rename…）无明显样式 | 新增 `pi-code-diff-file-face`，在 +/- 判定之前优先匹配 |
| P2 #3 | lite markdown 仅支持标题/粗体/行内代码 | 新增围栏标记、块引用、有序/无序列表、斜体、删除线、链接文字、水平线 |
| P2 #13 | 代码块长行被硬折、看不出是同一行 | 围栏代码体设置 `wrap-prefix` 为 `↪ ` 续行标记（可关闭） |
| P2 #16 | 流式文本与输入提示符挤在同一行（`answer> `） | `pi-code--maintain-input-separator` 保证 `> ` 独占一行；新增 `▌` 流式光标 overlay |
| P2 #17 | banner 键位行无悬挂缩进 | 该行加 `wrap-prefix "  "` |
| P2 #19 | 窗口缩放后分隔线宽度不变 | `pi-code--refresh-rules` + `window-size-change-functions` 重绘规则 |

### 仍待办（P2 #9，已在 §11 完成）

- ~~正文（user/assistant）仍顶格，工具/thinking 有 2 列缩进，层级偏弱。~~
  已实现：`pi-code-body-indent`（默认 2 列）统一正文缩进。
- 代码块仍不做硬截断（Emacs 无区域级 `truncate-lines`，
  改用续行标记提示换行）。

---

## 12. 第六轮：markdown 解析修复（2026-09-22）

起因：用户反馈 markdown 语法仍有部分未正确解析。实测定位到
lite 高亮的三类缺陷，逐项修复后跑全部 ERT 并重新字节编译。

- ERT：85/85 通过（render 新增 6 项：`markdown-fence-trailing-info`、
  `markdown-fence-trailing-space`、`markdown-fence-unclosed`、
  `markdown-bold-code-nesting`、`markdown-code-span-beats-bold`、
  `markdown-table`）。
- 字节编译：四个文件均无 warning、无 error。

### 已修复

| # | 问题 | 修复 |
|---|------|------|
| M1 | 围栏 info 后带尾随空格/文字（` ```python extra`）整段不识别 | open 正则放宽为 ` ```[^`\n]* `；`mark-code-blocks` 同理 |
| M2 | 未闭合围栏（截断输出）导致整段无高亮 | 找不到 closer 时高亮到区域末尾 |
| M3 | `**bold `c`` 中 code face 被 bold 覆盖，与代码注释说法相反 | bold 与行内 code 交换顺序，code 后上色优先；`code **not bold** span` 同理正确 |
| M4 | GFM 表格完全无高亮 | 新增 `pi-code--table-delimiter-re`：header 行加粗、`|` 管道符 meta；无前导 `|` 的散行不误伤 |

### 已确认非问题

- font-lock 落 face 属性（非 `font-lock-face`），gfm 全量路径的
  属性拷贝逻辑正确（用内置 mode 实测验证）。
- 流式/全量/历史回放三条字体化路径实测均正常。
- CJK 相邻的 `*斜体*` 不解析符合 CommonMark 行内强调规则
  （词内单个 `*` 不构成强调），非缺陷。
- Setext 标题（`===`/`---` 下划线式）暂不支持：与 HR 规则冲突
  且 LLM 输出罕用，留待用户确认后再做。

---

## 13. 第七轮：think 区分 + markdown 围栏保护（2026-09-22）

起因：用户反馈 think 与正文没有区分开、markdown 仍有解析问题。
实测定位后修复，跑全部 ERT 并重新字节编译。

- ERT：88/88 通过（render 新增 3 项：`markdown-code-protected`、
  `markdown-hr-spaced`、`thinking-label-rule`；另同步更新 2 处
  thinking 断言以匹配新格式）。
- 字节编译：四个文件均无 warning、无 error。

### 已修复

| # | 问题 | 修复 |
|---|------|------|
| T1 | think 块与正文/工具块视觉无区分（标签裸奔、折叠占位符与工具共用一套文案） | 标签加规则线（`▹ thinking ───`，与工具头同语言）；折叠占位符专属文案（`⋯ ▹ thinking · N lines (TAB)`），`pi-code--make-fold` 新增 label 参数 |
| M5 | 围栏代码内的 `#`/`-`/`>`/`**`/`` ` ``/`|` 被后续 lite 遍覆盖上色 | 围栏遍先收集代码区 ranges，其余 9 遍统一跳过（ranges 行对齐、构造均为单行，查 match 起点即可） |
| M6 | 空格分隔的 HR（`- - -`）不识别 | HR 正则支持单空格分隔；`***` 类仍优先判 HR（CommonMark 一致） |

### 第二次反馈：think 结尾判断仍不对（同一轮，追加修复）

用户反馈 §13 上面这轮修完后，「think 结尾仍然没有判断正确」。
复现后发现是真 bug，不是视觉问题：

- 根因：只有干净收到 `thinking_end` 事件时，流式 think 块才会被
  `pi-code--finish-thinking` 折叠。如果 agent 被取消/异常终止
  （`agent_settled` 直达，没有 `thinking_end`），或者流协议异常
  （`text_delta`/`toolcall_start` 紧跟在 `thinking_delta` 后面、
  中间漏了 `thinking_end`），think 块会永久停留在展开、未清理尾部
  缩进的状态——这就是用户看到的「结尾没判断对」。
  `message_end` 里对这种情况本来就有安全网（`pi-code--disarm-thinking`
  只清标记不折叠，注释写的是"避免误吞后续正文"），但代价是流式路径
  下任何没等到 `thinking_end` 的 think 块都会裸奔到底。
- 修复：在 `agent_settled`、`text_delta`、`toolcall_start` 三处开头都
  补一次 `pi-code--finish-thinking()`（该函数已加空 body 保护，
  没有打开的 think 块时是纯 no-op，不会误插换行打断正在流式的文字）。
  这样无论 think 块以什么方式收尾——正常 `thinking_end`、agent 被取消、
  还是协议漏发 `thinking_end` 直接来了文字/工具调用——都会在第一时间
  折叠，不再有裸奔的 think 块。
- 复现 + 回归用例：`pi-code-render-test-thinking-folds-on-cancel`
  （agent_settled 无 thinking_end）、
  `pi-code-render-test-thinking-folds-before-text`
  （text_delta 紧跟 thinking_delta，无 thinking_end）。
- ERT：90/90 通过；四文件字节编译无 warning；evil 2/2 通过。

---

## 14. 第八轮：Org 输出支持（2026-09-22）

起因：用户问 LLM 是否默认返回 markdown、能否要求返回 org、在哪里改。
结论：pi 默认 prompt 不要求格式，模型靠训练惯性吐 markdown；pi 原生
支持 `~/.pi/agent/APPEND_SYSTEM.md`（全局自动发现，`resource-loader.js:820`）
和 `--append-system-prompt`，用来指示 org 即可。用户选定：指令放全局
`APPEND_SYSTEM.md`，pi-emacs 内做完整 org 支持（含 `auto` 检测），
渲染默认保持 markdown。

- ERT：99/99 通过（新增 9 项：`org-emphasis`、`org-src-block`、
  `org-link`、`org-headline`、`org-structure-skips-src`、`detect-format`、
  `org-auto`、`org-degrade`、`map-org-face`）。
- 字节编译：四个文件均无 warning、无 error；evil 2/2 通过。

### 已做

| # | 内容 |
|---|------|
| O1 | `~/.pi/agent/APPEND_SYSTEM.md`（仓库外）：要求 Org markup、禁用 Markdown 的指令；改完需重启 pi 进程（`new_session` 不重读 system prompt） |
| O2 | 新 defcustom `pi-code-response-format`（`markdown` 默认 / `org` / `auto`）；`pi-code-use-markdown` 保留为总开关，老配置不破 |
| O3 | `pi-code--fontify-org-region`：临时 buffer + `org-mode` + `font-lock-ensure`，org 缺失时静默跳过；`org-src-fontify-natively` 绑 nil 防语言 face 泄漏 |
| O4 | `pi-code--org-face-map` + `pi-code--map-org-face`：org face 映射回 pi-code 主题并归一化（`(bold)`→`bold`、`(:inherit (org-block))`→code face 等），未映射（如 `org-table`）保留原样 |
| O5 | `pi-code--org-src-ranges` / `pi-code--mark-org-code-blocks`：认大小写不敏感的 `#+begin_src`/`#+begin_example`，body 加 `↪` wrap-prefix |
| O6 | `pi-code--fontify-org-structure`：缩进正文里的 org 标题/列表符直接上色（org 标题必须顶格，chat 缩进下 org 自身永远认不出），src 区内跳过 |
| O7 | `pi-code--detect-format`：强信号计分（org：`#+begin_`/`#+end_`/`[[..]]`/多星标题；md：``` ``` ```/`**..**`/`# `/`[]( )`），歧义项（单 `* `、表格）不计分，平局回 markdown |
| O8 | `pi-code--fontify-markdown-region` 内按格式分派；linkify 两条路共用 |

### 修到的潜 bug（附带）

- `pi-code--fontify-markdown-full` 的属性拷贝从没真正工作过：
  `with-temp-buffer` 里的 `put-text-property` 没传 OBJECT，face 全写进
  了临时 buffer 后丢弃。之前 §12 记的"已验证正确"是误判（无 markdown-mode
  的环境里 full 路径从没跑过）。本次用 org-mode 冒充 gfm-mode 实测复现，
  已修复（捕获 `target` 传 OBJECT）。org 新路径同样修法。

### 已知限制

- 模型对 org 的遵从度不如 markdown（训练数据偏向），复杂结构可能混写；
  `auto` 可缓解，无法根治。
- 老 session 存的是 markdown，切 `org` 后重渲旧回合会按 org 硬套；
  用 `auto` 可让新旧并存。
- `*单星 bullet*` 与 org 一级标题字形相同，检测时不计分；纯 `* item`
  短消息在 `auto` 下判 markdown（平局规则）。

### 已确认非问题（抽查结论，供后人参考）

- gfm 全量路径的属性拷贝逻辑正确（font-lock 落 `face` 属性，
  已用内置 mode 实测验证）。
- CJK 相邻 `*斜体*` 不解析符合 CommonMark 行内规则。

---

## 11. 第五轮：P2 #9 正文缩进（2026-09-22）

检查方式：实现后跑全部 ERT 并重新字节编译。

- ERT：79/79 通过（render 新增 5 项：`body-indent-user`、
  `body-indent-streamed`、`body-indent-empty-delta`、
  `body-indent-custom`、`body-indent-markdown`）。
- 字节编译：无 warning、无 error。

### 已修复

| # | 问题 | 修复 |
|---|------|------|
| P2 #9 | 正文顶格，与 2 列缩进的工具/thinking 块层级脱节 | 新增 `pi-code-body-indent`（默认 `"  "`，空字符串关闭）；`pi-code--insert-body-text` 统一处理 user 全量、assistant 流式/全量：行首补缩进、内部换行后补缩进、尾换行不留尾随空格、空 delta 不插入 |
| P2 #9 | markdown-lite 行首锚点（围栏/标题/引用）不认缩进行 | `^` 改为 `^[ \t]*`（围栏 code-wrap 标记同理）；列表/水平线原本已容忍 |
| P2 #9 | 旧断言 `## You\nhello` 类行内缩进变化 | 同步更新 2 处 ERT 断言为 2 列缩进 |

### 附带修复（基线曾不可运行）

- 测试套件因陈旧 `.elc` + 老版 bundled transient（0.7.2.2，无
  `transient--set-layout`）无法加载：`pi-code.el` 的 transient
  改为可选依赖——新 transient 用真菜单（运行时 `eval` 定义，
  编译产物跨环境可用），否则用 completing-read 回退菜单；
  `C-c C-a` 键位与 `pi-code-menu` 命令在两种环境下均可用。

---

## 15. 第九轮：整个 buffer 原生跑 Org（2026-09-22）

起因：用户两点反馈——① user/pi 头还是 markdown 的 `##`；
② org 还是没渲染对，能否把整个 buffer 放到 org 文件下。
结论：`pi-code-chat-mode` 改从 `org-mode` 派生，header 换成
`* You` / `* pi`，渲染/折叠/链接全走 org 原生机制。

- ERT：102/102 通过（18 处 `##` 断言同步为 `*`；org 测试改写
  为 native face；新增 mode/remap/TAB/RET/nav 测试 6 项，删除
  过时 2 项）。
- 字节编译：四个文件均无 warning、无 error；evil 2/2 通过。

### 已做

| # | 内容 |
|---|------|
| N1 | `pi-code-chat-mode` 改派生 `org-mode`（`(require 'org)`，内置无新依赖）；`face-remapping-alist` 把 `org-code`/`org-block`→code face、`org-link`→link face、`org-*-begin/end-line`+`org-meta-line`→meta face，显示层保持主题一致，text property 里仍是原生 org face |
| N2 | header `## You`/`## pi` → `* You`/`* pi`（显式 user/assistant face 保留）；turn 导航正则同步；`outline-minor-mode` + `pi-code-use-outline` 删除（org 原生 folding/imenu 代替） |
| N3 | 自动重染关闭（`font-lock-support-mode` nil）：实测确认 org 会覆盖已有显式 face（如 header 色）且 `font-lock-ignore=t` 无效；Org body 只在消息完成时显式 `font-lock-fontify-region`，thinking/工具/markdown body 永远不被误染；顺序为 native 先、structure 后（native 的 unfontify 会清 structure 的 face，反之则内层强调丢失——与 §14 行为一致） |
| N4 | §14 的 temp-buffer 拷贝链删除（`fontify-org-region`、`map-org-face`、`org-face-map`）：原生已覆盖，留着是双份工作 |
| N5 | `RET` 绑 `newline`（保住输入区行为，不用 `org-return`）；其余 org 按键（`M-RET`、`C-c C-x` 前缀等）保留原生 |
| N6 | `TAB` 语义升级：fold 占位符 → toggle；org heading → `org-cycle` 整轮折叠；input 区 → 缩进 |

### 附带修到的真 bug（2 个）

- mouse-2 / RET 点 placeholder 从没工作过：`pi-code-fold-ov`
  属性只存在于 after-string 字符串对象上，`get-text-property`
  读 buffer 位置永远 nil——之前只有 TAB 靠粘性回退能展开。
  改为按 overlay end 精确查找（`pi-code--fold-placeholder-at`），
  三路（TAB/RET/mouse）统一走 `pi-code--fold-at-pos`。
- `pi-code--fold-at-point` 的粘性回退（point 之后最近的 fold）
  导致 input 区按 TAB 会误触旧 fold；改为严格查找（光标下
  overlay 或正好站在 placeholder 上），无 fold 时 input 区正常缩进。

### 已知限制 / 取舍

- markdown 内容在 org buffer 里：lite 高亮遍照常工作；org 原生
  只在 org-format 的 flush region 上显式跑，且 jit 已关，不会扩散
  到 markdown 区。唯一例外是用户手动整 buffer 重染
  （`font-lock-fontify-buffer`），那会按 org 规则盖一遍——属用户
  主动行为，不处理。
- `org-src` 代码块走原生高亮（`print` 这类词会有语言 face），
  不再强制统一 code 色——这是原生 org 行为，视为特性。
- `pi-code-use-markdown=nil` 只关 pi-code 自己的高亮遍；org
  major-mode 自带的 font-lock 仍在（buffer 本来就是 org）。
- 转 `*` 头后，旧 session 文件里的历史 `##` 头重放时会按新
  `*` 头渲染（header 是 chrome，非内容，无影响）。

---

## 16. 第十轮：结果文件复现的三个渲染缺陷（2026-09-22）

起因：用户反馈 org 仍没渲染对，附 `pi-emacs-result.org`
（整 buffer dump：banner、分隔线、`* You`、`* pi`、40 行
thinking、org 表格回答、`>` 输入提示）。用文件原文逐行复现后
定位三处真问题（chat 内确无 face 或错 face），全部修复。

- ERT：106/106 通过（新增 4 项：`org-table-align`、
  `org-cjk-emphasis`（含 `/usr/bin`、`a=b` 反例）、
  `org-cjk-local-only`、`org-headline-star-plain`）。
- 字节编译零 warning；evil 2/2；多表/src 内管道/未闭合表
  压力探针无 hang。

### 已修复

| # | 文件中的证据 | 根因与修复 |
|---|---|---|
| R1 | 表格只有颜色、对不齐（`\| 水星 \| 类地 \| 2 440 \|` 列参差） | face 不管对齐。新增 `pi-code--align-org-tables`：按 table 块调一次 `org-table-align`（CJK 等宽、缩进保留，实测），src 区内跳过；dispatch 里放最前（文本手术先于一切上色） |
| R2 | `/类地行星/：`、`是*粗体*的` 没斜体/粗体 | stock org 的 prematch/postmatch 不含非 ASCII。`pi-code--set-org-cjk-emphasis` 把两套集合 buffer-local 扩展 `[:nonascii:]`，再用真正的 `org-set-emph-re` 重算 buffer-local 的 `org-emph-re`/`org-verbatim-re`（读 org.el 源码确认：keyword 存的是函数 `org-do-emphasis-faces`，匹配时动态读这三者——另含 `quick-re` 候选扫描也读 components，不扩展它连候选都找不到）。全局用 save/restore 包住，实测零泄漏 |
| R3 | `* 太阳系…` 标题的星号被加粗 | structure 的 bullet 正则含 `*`，单星标题既判标题又判 bullet。org 里 `*` 开头永远是标题：bullet 改为只认 `-`/`+`/有序标记 |

### 附带修到的真 bug（hang）

- `pi-code--align-org-tables` 第一版死循环：`org-table-align`
  不移动 point，循环从原地重搜同一行（batch 直接卡死 120s+
  core dump）。改为处理完向前跨过整张表。教训：凡是回调里
  改 buffer 文本的循环，必须显式推进 point，不能依赖
  re-search 自然前进。

### 反例锁死（均有 ERT）

- `/usr/bin`（真实路径→linkify 按钮，不是斜体）、`a=b`（无邻接
  空格约束）不受 CJK 扩展影响；`alpha*beta*gamma` 类希腊字母
  数学式会被判粗体（`[:nonascii:]` 的已知代价，中文场景可接受）。
- `**md**` 仍按 stock org 语义判粗体（与改动无关，原生行为）。

---

## 17. 第十一轮：去掉 Markdown，只留 Org（2026-09-22）

用户要求：去掉 markdown 相关代码，只使用 org mode。

背景：`xxx.org` 真实输出里表格裸写但仍参差不齐。逐项排查
（对齐函数直接调用 OK、缩进 OK、dispatch OK）后定位根因在
`pi-code--detect-format`：单 `*` 标题+纯 pipe 表格都是刻意
中性信号，计分 0/0，平局兜底判 markdown → 走 markdown 分支，
完全跳过 `pi-code--align-org-tables`。先把平局改判 org 验证
通过，但用户随即决定整个 markdown 路径不要了——探测/平局
问题连根消失。

删掉的东西（`pi-code-chat.el` 内）：
- `pi-code-use-markdown`、`pi-code-response-format` 两个 defcustom，
  新增 `pi-code-use-org`（默认 t）为主开关；`pi-code-markdown-max-chars`
  改名 `pi-code-org-max-chars`。
- `pi-code--fontify-markdown-lite`（约 100 行内置 highlighter）、
  `pi-code--fontify-markdown-full`（gfm-mode 临时 buffer 路径，
  顺带删掉 markdown-mode 可选依赖的 declare-function）、
  `pi-code--detect-format`、`pi-code--mark-code-blocks`、
  `pi-code--table-delimiter-re`。
- `pi-code--fontify-markdown-region` 改名 `pi-code--fontify-org-region`，
  无分派：对齐 → 原生 fontify → structure → src wrap 标记 → linkify。
- `~/.emacs` 里失效的 `(setq pi-code-response-format 'auto)` 清掉。

测试：删 markdown 专用 ERT（lite/degrade/fence/nesting/GFM 表/
code 保护/HR/detect-format/org-auto），改 `body-indent-markdown` 为
org 版（`* T` + `#+begin_src`）、`streamed-text-around-tool` 反引号
改 `~...~` 断言 `(org-code)`、`--org-faces` helper 去掉 format 开关。
ERT 93/93，evil 2/2，字节编译零 warning。用 `xxx.org` 原文端到端
验证表格对齐。

README 同步：Customization 去掉两个旧 defcustom，Org mode output
小节改写为 Org-only（无格式开关/无探测）。

---

## 18. new-result.org 检查（2026-09-22，只验不改）

用户新增 `new-result.org`（三段回答：中文表、英文表、org 测试页）。
Emacs `string-width` 口径逐表检查：4 张对齐（英文两张、小 ASCII
两张），4 张真没对齐（中文两张：行 42-51、55-64；测试页两张大表：
行 233-242、365-376，其中 365-376 是纯 ASCII，排除字体口径问题）。

- 消息 1 原文走当前 handler 复现：两张表都对齐（OK 92 / OK 109）。
  365 表直接调 `org-table-align` 也 OK。代码没问题。
- 结论：用户 live Emacs 跑的是 §16 之前（对齐函数加入之前）的旧
  代码，从未 reload——英文表是模型手写碰巧对齐的，中文/复杂表模型
  没手调、旧代码又没跑对齐。解法是重启 Emacs（连带载入 org-only
  改写和 fontset 配置），不是改代码。
- 其余构造逐项对照纯 org-mode：checkbox/timestamp/footnote 引用/
  quote-center 关键字行/fixed-width（`: ` 原生给 org-code，出乎意料
  但与原生一致）/裸 `\alpha`（原生 nil）/`-----`（org 无 HR face，
  原生 nil）/脚注定义正文（原生 nil）——chat 与原生逐项一致，无残留
  渲染 bug。嵌套 src 的孤立 `#+end_src`（355 行）保持 plain，正确。

---

## 19. 字体比例实测（2026-09-22，只改 ~/.emacs）

用户问标点是否导致对不齐。fontTools 实测 advance：
- 西文格 Noto Sans Mono = 0.6em；Mono CJK SC 的 CJK/全角标点 = 1.0em、
  拉丁反而 0.5em——直接配对是 1.667:1，不是 2:1（之前"换字体即好"的
  判断错了，Mono CJK 的 2:1 是相对它自己拉丁而言）。
- `₂`/`₄` (U+2080–209F) 根本不在 Mono CJK 内，fallback 默认命中
  Noto Sans（比例字体，₂ 仅 0.35em）；全角 `（）`、`、` 在 cjk-misc
  内已正确映射，无问题；`°` 走拉丁字体，无问题。
修复（~/.emacs，重启生效）：`face-font-rescale-alist` 给
"Noto Sans Mono CJK" ×1.2（1.2em = 2×0.6em 精确 2:1）；
`(#x2080 . #x209F)` 钉到 Liberation Mono（精确 0.6em）。

---

## 20. 第十二轮：答案标题降级 + 答案区 TAB 折叠 + CJK 斜体可见性（2026-09-22）

用户反馈两点：(1) 答案标题从最高级 `*` 开始，与 turn header
（也是 `*`）撞级，`*****` 之类还一直显示；(2) `/斜体/，` 第二个
斜线紧贴逗号，斜体渲染失败。result-code.org 证实：答案里 `* 太阳系…`
与 `* pi` 同级，org 的 `org-cycle`/overview 把答案标题当成 turn 的
兄弟，折叠/层级全乱。

### 修复

- **降级**：新增 `pi-code--demote-org-headlines`，把答案区间内所有
  `*+ ` 标题统一 +1 级（`*`→`**`、`**`→`***`…），在
  `pi-code--fontify-org-region` 最前面（派发前）跑。跳 src/example
  区（那里 `*` 是代码）。相对层级不变，与 LLM 从哪级起无关。
- **TAB 折叠答案区**：`pi-code--answer-headline-at-point` 识别缩进
  标题（排除 src），`pi-code--fold-answer-section` 从标题下一行折到
  下一个同级/更高级标题、turn header 或输入区；已有 fold 就地 toggle。
  接进 `pi-code-toggle-fold`（在 org-cycle 分支之前）。
- **CJK 斜体可见性**：实测解析完全正常（15 种标点矩阵 + 无空格 +
  ASCII 边界全部 `italic`），根因是 Noto Sans Mono CJK 没有 italic
  字形，`italic` face 对汉字无视觉变化。新增
  `pi-code-emphasis-face`（inherit italic + underline），在
  `pi-code-chat-mode` 里 buffer-local 把 `org-emphasis-alist` 的
  `"/"` 换成它，据此基础自全局值，其它标记不动。

### 关键排查记录

- 用户 `~/.emacs:264` 有 `org-hide-emphasis-markers t` +
  `org-startup-indented t` + `org-bullets-mode`，都会作用于 chat buffer
  （它是真 org-mode）。逐一验证：`org-indent-mode` 下 italic 仍正确、
  `buffer-invisibility-spec` 已含 `(org-link)`、markers 正常隐藏。
  所以渲染管线没问题，纯粹是字体无斜体字形。
- 旧消息不会追溯重排/降级：降级与对齐都只在消息完成时跑，已在屏的
  旧文本保持原样，需新消息验证。

### 验证

97/97 ERT（新增 `org-headline-demoted`、`org-headline-demote-skips-src`、
`answer-headline-folds`、`org-emphasis-cjk-comma`；改 `org-emphasis`/
`org-cjk-emphasis` 断言为 `pi-code-emphasis-face`），evil 2/2，字节
编译零 warning。result-code.org 原文端到端：标题正确降级、斜体生效。

---

## 21. 第十三轮：org/HTML 导出修复（2026-09-22）

用户把 final-test.org 导出 final-test.html 后发现：(1) thinking 与
正文在 HTML 里没有区分；(2) `*` 分级仍有问题。

### 根因（实测 org-element 解析）

- org 只认**第 0 列**的标题：`  ** x` → paragraph，`** x` → headline。
  表格/列表/src 块缩进都能解析，**只有标题不行**。答案标题此前是
  缩进的（为了聊天缩进外观），所以 org 根本不把它当标题 → HTML 里
  `** 八大行星` 变成普通文本、`***` 被当粗体 `*`，turn header
  `* You`/`* pi` 反而成了唯一顶层标题。字号分级全乱。
- thinking 只是缩进段落（fold 是 overlay，导出不带），所以 HTML 里
  和正文一样。

### 修复

- `pi-code--demote-org-headlines` 改为**去缩进 + 降级**：逐行状态机
  跳过 src/example 区，标题行去掉前导空白并 +1 颗星（`*`→`**`）。
  标题到第 0 列 → org 认作真标题，嵌套在 `* pi` 下，`org-cycle`
  原生折叠，HTML 导出正确。
- thinking 用 `#+begin_quote`…`#+end_quote` 包裹（缩进版 keyword 实测
  可解析）。`#+begin_quote` 在 `pi-code--insert-thinking-label` 里
  写、label 行仍保留在块内；`#+end_quote` 在 `pi-code--finish-thinking`/
  `pi-code--insert-thinking` 里写（先 `fresh-line` 防粘行）。
  新增 `pi-code--thinking-block-start` marker，fold 覆盖整个块，
  placeholder 行数只数正文（`pi-code--fold-thinking-block`）。
- 标题到第 0 列后，答案折叠交给原生 `org-cycle`，删掉了上一轮加的
  `pi-code--answer-headline-at-point`/`pi-code--fold-answer-section`
  及 `pi-code-toggle-fold` 里的对应分支（已无用）。
- `thinking_delta` 兜底分支也补插 label/块头。

### 验证

98/98 ERT（新增 `thinking-quote-block`、`answer-headline-native-fold`，
改 `org-headline-demoted` 断言第 0 列），evil 2/2，字节编译零 warning。
端到端：模拟一轮后 `org-html-export-as-html`，
`blockquote=t`、`outline-2/3/4=t`、无残留字面星号。

---

## 22. 第十四轮：导出与缩进细节（2026-09-23）

用户两点：(1) 转 HTML 时去掉 thinking；(2) thinking/bash 之后那条
`─────` 填充线去掉；另指出 org 强调不识别是因为标记与其后中文标点
之间缺空格。

### 改动

- thinking 容器由 `#+begin_quote` 改为 `#+begin_comment`
  （`pi-code--insert-thinking-label` / `pi-code--close-thinking-block`）。
  `comment` 块在 org-html 导出时被整体丢弃（实测 thinking 文本与
  keyword 都不出现），Emacs 里仍正常显示、TAB 折叠。
- 删掉 `pi-code--fill-rule` 及两处调用（thinking 标签行、tool 行），
  不再在 `▹ thinking` / `$ ▸ bash` 后追加 `─────` 填充线。测试相应
  改为断言无填充线。
- CJK 强调导出：定位到 **font-lock 与导出用的是两套机制**。
  font-lock 读 `org-emphasis-regexp-components`/`org-emph-re`
  （所以前面加 `[:nonascii:]` 后显示就对了）；但导出走
  `org-element--parse-generic-emphasis`，其开合边界字符集**写死为
  ASCII**，完全不读那两个变量，故 `~code~，` 导出仍不解析。修法：
  用同一套 pre/post 覆盖该函数（`advice-add :override`），放在
  `~/.emacs` 的 `with-eval-after-load 'org-element`。实测
  `~RecursionError~，`、`/斜体/。`、`是*粗体*的` 导出均为
  `<code>`/`<i>`/`<b>`，ASCII 用例不受影响。

### 验证

98/98 ERT（`thinking-comment-block`、`tool-line-glyph`、
`thinking-label-plain` 替换原 rule 断言），evil 2/2，编译零 warning。
端到端导出：thinking 文本与 keyword 均不出现、无 `bash ─` 填充线、
CJK 强调正确、标题嵌套 outline-2/3/4。

### 备注

- `~/.emacs` 全局 `org-emphasis-regexp-components` 扩展 + org-element
  覆盖都属**编辑器全局**行为（导出发生在用户的普通 org buffer，不是
  chat buffer），因此放在用户配置而非 pi-code 包内。
- 标记后有空格的传统写法（如 `~code~ ，`）无需任何改动即正常。

---

## 23. 第十五轮：强调空格的源头修复（2026-09-23）

用户澄清：第 3 点**关键不在导出**——在 org 文件本身，标记与其后
中文标点之间缺空格也会渲染错。确认根因：org 的强调要求标记落在词
边界（前：空白/`-('"{`/行首；后：空白/ASCII 标点/行尾），`~code~，`
的 `，` 不满足，stock org 一律不识别；只有把边界集合加宽（我们的
扩展）或**加空格**才成立。

- 源头修：`~/.pi/agent/APPEND_SYSTEM.md` 增加规则，要求标记外侧遇
  中文/中文标点必须留空格（`是 *粗体* 的`、`用 ~code~ ，`），这样
  在任何 org 渲染器都有效，而不只用户本机 Emacs。
- `pi-code--set-org-cjk-emphasis` 改为幂等：若全局已含
  `[:nonascii:]` 就不重复追加（用户 `~/.emacs` 已全局扩展）。
- 实测 final-test.org 在纯 org buffer + 全局扩展下：143 处 `~…~`
  中真正未解析的 18 处全是代码/thinking 里的裸 `~`（如 Racket
  `format "~a\t~a"`），无一是正文强调；`~RecursionError~，`、
  `/斜体/。` 等均正常。

三层保障：① 源头（agent 加空格）② 显示（`org-emphasis-regexp-
components` 扩展，buffer-local + 全局）③ 导出（org-element 覆盖）。
98/98 ERT，evil 2/2，编译零 warning。

---

## 待办 (TODO)

### T1. thinking 结束与正文起始可能同一行
用户报告 thinking 的 `#+end_comment` 与紧随的正文出现在同一行。
本地复现未成功：thinking→text（有/无结尾换行）、空 thinking、
thinking→tool→text 三种路径下 `#+end_comment` 与正文都各占一行
（`pi-code--finish-thinking` 里 `pi-code--close-thinking-block` 先
`pi-code--fresh-line`）。**需要用户给出具体触发场景**（哪个模型事件
序列 / 截图片段）才能定位。候选嫌疑：`thinking_end` 与 `text_delta`
之间夹了 `toolcall_*`、`message_start` 重入、或非流式
`pi-code--insert-thinking` 后紧跟 `pi-code--insert-body-text` 的边界。

### T2. 核对所有 Org 转义字符是否都正确跳脱
正文里若出现会被 Org 解释的字符，可能误渲染，需要逐一核对/加固：
- 行首 `*` / `-` / `+` / `1.`（标题/列表）
- 行首 `#+`（关键字/块）与 `,` 转义
- `|`（表格）、`[ ]`（链接/脚注）、`< >`（时间戳）
- `*` `/` `_` `=` `~` `+`（强调）、`^` `_`（上下标）
- `$`（LaTeX 片段）、`\`（实体/转义）
目标：要么按 Org 语义正确渲染，要么在会破坏结构时转义，避免输出
被错误解析成标题/列表/表格。

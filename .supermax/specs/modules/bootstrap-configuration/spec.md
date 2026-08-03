---
module: bootstrap-configuration
authority: draft
status: partial
target_disposition: redefined-by-supermax-configuration-provider-contract-actions-commands
baseline_commit: 558518f8d78a44198cd428f6bf8bf48bfa38d76d
baseline_version: v18.7.0
---

# CodeCompanion.nvim v18.7.0：Bootstrap、配置与公开入口反推规格

## 1. 范围与证据规则

本稿只描述锁定 baseline commit `558518f8d78a44198cd428f6bf8bf48bfa38d76d`（tag `v18.7.0`）的可观察行为和必要状态契约。它是 `authority: draft` 的 upstream 证据，不是目标规格。目标行为由 `supermax-configuration`、`provider-contract` 和 `actions-commands-target` 定义；不支持的 upstream public surface 不产生实现要求。

主要证据：

- `plugin/codecompanion.lua`：一次性加载、版本门槛、highlight、FileType/TermEnter/BufEnter autocmd、treesitter 注册。
- `lua/codecompanion/init.lua`：`setup`、公开 Lua API、配置初始化及 interaction 委托。
- `lua/codecompanion/config.lua`：defaults、深合并、旧 `strategies` 迁移、keymap/diagnostic 归一化、配置访问器。
- `lua/codecompanion/commands.lua`：四个用户命令及 completion/参数解析。
- `lua/codecompanion/health.lua`：依赖、parser、library 检查。
- `tests/config.lua`、`README.md`、`doc/configuration/others.md`、`doc/usage/events.md`：配置 fixture、用户可观察文档和事件目录。

## 2. 操作级 Requirements

### R1 — 插件入口幂等加载与版本门槛

**GIVEN** 插件入口被加载，**WHEN** `vim.g.loaded_codecompanion` 已为真，**THEN** `plugin/codecompanion.lua` 立即返回且不重复注册入口副作用。

**GIVEN** 尚未加载且 Neovim 版本低于 0.11，**WHEN** 入口执行，**THEN** 设置 loaded 标记后以 ERROR 级别通知 `CodeCompanion.nvim requires Neovim 0.11+` 并停止后续注册。

**GIVEN** 版本满足要求，**WHEN** 入口执行，**THEN** 安装默认 Chat 相关 highlight；创建 syntax/buffer augroup；注册 syntax、terminal、buffer context autocmd；注册 Markdown parser 到 Chat filetype。Inline highlights are removed from target requirements.

### R2 — Chat buffer syntax 与 context 状态

**GIVEN** `FileType=codecompanion`，**WHEN** callback 调度执行且 buffer 仍有效，**THEN** 开启 syntax，并为通用 tool token `@{...}` 及配置中的 chat variables 注册匹配规则；若调度后 buffer 已删除，则安全返回。

**GIVEN** `TermEnter` 进入有效 terminal buffer，**WHEN** callback 执行，**THEN** `_G.codecompanion_last_terminal` 更新为该 buffer；无效 buffer 或非 terminal 不更新。

**GIVEN** `BufEnter` 进入有效且未排除的 buffer，**WHEN** callback 执行，**THEN** `_G.codecompanion_current_context` 更新为 buffer number，并触发 `ContextChanged`（payload 至少含 `bufnr`）。当 filetype 或 buftype 命中 `config.interactions.chat.variables.buffer.opts.excluded` 时不更新且不触发该变化。

### R3 — 配置输入合并与禁止字段

**GIVEN** `CodeCompanion.setup(args)` 未传参，**WHEN** 执行，**THEN** 使用 defaults 的深拷贝作为配置，避免后续修改污染默认模板。

**GIVEN** `args.constants` 存在，**WHEN** 配置 setup 执行，**THEN** 拒绝该配置并发出 ERROR 通知 `Your config table cannot have the field \`constants\``，不接受用户覆盖内部 constants。

**GIVEN** 使用 v18 之前的 `args.strategies`，**WHEN** setup 执行，**THEN** 将其与默认 `interactions` force-deep-merge，写入 `args.interactions`，再删除 `args.strategies`；该兼容路径标记为 TODO 移除于 v19.0.0。

**GIVEN** 普通配置字段，**WHEN** setup 执行，**THEN** 使用 `vim.tbl_deep_extend("force", vim.deepcopy(defaults), args)`；用户值覆盖同路径默认值，未提供的默认分支保留。

### R4 — 配置后处理与公开配置访问

**GIVEN** Chat keymap 的值为 `false`，**WHEN** setup 完成，**THEN** 这些禁用映射从最终 keymap 表中删除，而非作为可执行映射保留。

**WHEN** setup 完成，**THEN** 创建 `CodeCompanion-info` 与 `CodeCompanion-error` diagnostic namespaces，并将 underline/signs 关闭、virtual text spacing 设为 2、最低 severity 设为 INFO 的 diagnostic 配置应用到两者。

**GIVEN** 调用 `require("codecompanion.config").<field>`，**WHEN** 字段不是模块自身显式方法，**THEN** metatable `__index` 从当前 `M.config` 返回该字段；`setup` 仍可作为公开方法访问。

**GIVEN** `config.opts.send_code` 为 boolean，**WHEN** `can_send_code()` 调用，**THEN** 返回该 boolean；为 function 时返回函数结果；其他类型返回 false。

### R5 — setup 的初始化顺序

**GIVEN** target runtime setup succeeds, **THEN** configuration validation, four-protocol provider registration, Action/Command registration, Chat input completion, logging, extensions, MCP/Skill and status integration initialize in a declared order. Unsupported protocol namespaces are absent.

该顺序来自 `lua/codecompanion/init.lua` 的 setup 逻辑；各阶段的异常隔离、重复 setup 行为及全部副作用仍未完成静态逐分支核验。

### R6 — `:CodeCompanionChat` 命令

**GIVEN** 参数包含 `key=value`，**WHEN** 执行命令，**THEN** 将其写入 `opts.params`；支持 `adapter=`, `model=`, `command=`，其中 model/command 的 completion 依赖选定 adapter 的 schema/commands。

**GIVEN** 参数为 `toggle`、`add` 或 `refreshcache`（大小写不敏感），**WHEN** 执行命令，**THEN** 设置对应 `opts.subcommand`；其他参数按原顺序拼接为空格分隔的 user prompt，并设置 `opts.args`。

**GIVEN** 执行 chat 命令，**WHEN** callback 完成解析，**THEN** 委托 `CodeCompanion.chat(opts)`；completion 在起始位置提供 `adapter=`, `command=`, `model=`, `Toggle`, `Add`, `RefreshCache`，不匹配 adapter/model 条件时返回空列表。

### R7 — `:CodeCompanionActions`

**GIVEN** 执行 Actions refresh，**THEN** 先以当前 buffer context 刷新 Actions cache，再打开 Actions palette。Actions remain a runtime entrypoint; standalone command-input Chat is removed.

### R8 — 公开 Lua API 委托与状态

Target public API retains setup, Chat create/toggle/add/restore/lookup/close, Actions/Commands, prompt/context insertion, extension registration, feature/version and history/status operations. Inline and standalone command-input Chat APIs are removed. Session lookup uses runtime session identity; buffer lookup is a host-view convenience only.

除 R1–R8 已展开的入口行为外，逐 API 参数、返回值、无效 adapter、chat 创建失败、版本依赖 completion（Neovim 0.12）尚未完成，故本模块保持 partial。

### R9 — health check

**GIVEN** 执行 `:checkhealth codecompanion` 触发 `M.check()`，**WHEN** Neovim 低于 0.11，**THEN** 报错 `codecompanion.nvim requires Neovim 0.11+`。

**WHEN** 版本满足，**THEN** 输出 Neovim 版本与日志文件路径，并分别检查：必需 plenary.nvim；必需 markdown/markdown_inline parser；可选 yaml parser；必需 curl；可选 file 与 rg。缺失必需项报告 error，缺失可选项报告 warn，存在项报告 ok。adapter credential 检查代码在该 baseline 被注释，不应宣称已执行。

## 3.1 `init.setup` 完整注册链与边界

基线 `lua/codecompanion/init.lua:391-456` 的 `CodeCompanion.setup(opts?)` 是一次性初始化编排器；`opts` 为 nil 时先变为空表。可观察顺序如下：

1. `config.setup(opts)` 先建立最终配置；配置拒绝 `constants` 时会提前返回，因此后续注册链不会可靠发生。
2. Target provider registration validates only `openai_chat`, `openai_responses`, `anthropic_messages`, and `gemini`; compact provider records replace upstream adapter preset/deep-merge behavior.
3. 遍历 `codecompanion.commands`，对每个 descriptor 调用 `vim.api.nvim_create_user_command(cmd.cmd, cmd.callback, cmd.opts)`；重复 setup 未做显式 command-exists 防护，重复注册的具体错误/中断状态未由该模块测试确认。
4. 读取 `config.interactions.chat.opts.completion_provider`，以 `pcall(require, "codecompanion.providers.completion." .. provider .. ".setup")` 加载 provider；失败只写 WARN，不阻止后续日志、extension 和 sticky 初始化。
5. 以 notify WARN handler 与 file handler 建立 logger root；文件名固定为 `codecompanion.log`，文件级别取 `vim.log.levels[config.opts.log_level]`。
6. 遍历 `config.extensions`；`schema.enabled == false` 跳过，否则以 `pcall(_extensions.load_extension, name, schema)` 加载，单个失败写 ERROR 并继续其他 extension。
7. 仅当 `config.display.chat.window.sticky` 为真且 layout 不是 `buffer` 时，清理并创建 `codecompanion.sticky_buffer` augroup 及 `TabEnter` callback。callback 对最近 chat 且在其他 tab 可见的情况更新 `buffer_context`，schedule 关闭并以 `toggled=true` 重开；其他情况不动作。

**GIVEN** completion provider 或 extension 加载失败，**WHEN** setup 继续执行，**THEN** 失败被记录而不是直接抛出，后续阶段仍尝试执行。**GIVEN** sticky 未启用或 layout 为 `buffer`，**WHEN** setup 完成，**THEN** 不注册 sticky `TabEnter`。

**setup 边界**：该函数返回 `nil`，没有成功/失败结果协议；配置拒绝是 `vim.notify` ERROR 返回路径，provider/extension 失败是日志 WARN/ERROR 路径。adapter resolve、chat creation、命令 callback 的失败属于后续 API 链，不应归因于 setup 已验证的返回值。

## 3.2 默认值与缺失约束

以下约束来自 baseline `lua/codecompanion/config.lua` 的 defaults（约行 12-1058），仅记录会影响 bootstrap/API 或后续可观察行为的缺失语义；不是完整默认树：

- Upstream adapter namespace/defaults are baseline-only. Target provider defaults are declared by `provider-contract` and expose only the four supported protocols.
- Chat 默认 adapter 为 `copilot`；background title 采用 copilot / `gpt-4.1`，background interactions 默认 disabled。缺失的 `interactions.chat.opts.completion_provider` 会使 setup 拼接无效模块名并仅产生 WARN。
- Chat keymap defaults are a table; a disabled mapping is absent from the normalized target Action/Command registry.
- `opts.send_code` 支持 boolean 或 function；`config.can_send_code()` 仅对 boolean 原值、function 返回值提供语义，其他类型返回 false。它直接影响 `CodeCompanion.add` 是否继续。
- `display.chat.window.sticky` 与 `layout` 共同决定是否注册 TabEnter；`extensions[name].enabled=false` 共同决定是否加载 extension。`opts.log_level` 必须能索引 `vim.log.levels` 才能形成预期 file handler level；非法值的具体 logger 行为未由本模块测试确认。
- `constants` 是内部保留表，用户传入该字段不会被合并；`strategies` 是旧配置兼容输入，迁移到 `interactions` 后删除。未提供字段保留默认分支，深合并不会将默认树整体替换。

**可观察 defaults 约束（baseline `config.lua:12-1058`）**：

- Provider layer: target defaults cover proxy/transport timeout/retry, model discovery/cache, supported capabilities and compact provider validation; upstream preset namespaces are not retained.
- Background：默认标题 adapter/model 是 `copilot`/`gpt-4.1`；background callbacks 预置 `chat_make_title` 且 enabled；总开关 `interactions.background.opts.enabled=false`，因此默认不会启用全部后台交互。
- Chat selection/input: target defaults declare provider/model, blank-prompt behavior, completion/debounce/register and input timing. Permission/authorization timeout is removed.
- Chat 子系统：默认提供 tools/groups、variables、slash_commands、keymaps；tools 的 fold/always-loaded/system-prompt 选项默认启用，slash command 和 variable 条目可由各自 `enabled` 函数按上下文禁用。将任一 chat keymap 设为 `false` 会在 setup 后删除该键。
- Chat 默认显示：`auto_scroll=true`、`show_context=true`、`show_reasoning=true`、`fold_reasoning=true`、`show_tools_processing=true`、`show_token_count=true`、`start_in_insert_mode=false`；`fold_context=false`、`show_settings=false`、`show_header_separator=false`。窗口默认 vertical、full_height=true、sticky=false、buflisted=false、border=single、relative=editor，window opts 启用 breakindent/linebreak/wrap。
- Standalone Inline and command-input Chat defaults are removed. Commands execute through the retained Action/Command runtime and Chat surface.
- Prompt/rules：prompt library 的 markdown dirs 默认空表；rules 默认包含 `default` 与 `CodeCompanion` preset；parser 提供 `claude`、`codecompanion`、`none`；rules chat autoload=`default`、enabled=true、default_params=`diff`、show_presets=true。
- Display/Action: retain Chat icons and Action palette behavior required by `chat-ui` and `actions-commands-target`. Inline/diff interaction defaults are removed.
- General opts：`log_level="ERROR"`、`language="English"`、`send_code=true`、`job_start_delay=1500`、`submit_delay=2000`。`log_level` 通过 `vim.log.levels[log_level]` 选择文件 handler 级别；`send_code` 由 `can_send_code()` 解释。

**边界**：上述 defaults 是对会影响 bootstrap 或直接用户可观察行为的字段分组，不声称逐一列出每个 tool/slash/variable/prompt 的内部 schema。各字段的动态 callback（例如 adapter 名称、规则 enabled、窗口尺寸、token_count）必须在其所属交互模块继续反推。

## 3.3 公开 Lua API 参数、返回与失败状态

以下均为 baseline `lua/codecompanion/init.lua` 的委托边界；除特别标注外函数返回 `nil`，失败通过 log 或下游模块状态暴露：

| API | 输入与成功效果 | 返回/失败状态 |
|---|---|---|
| `setup(opts?)` | 配置表或 nil；执行本节注册链 | `nil`；保留 `constants` 时 ERROR notify 并提前结束 |
| `inline(args)` | `args` 表；当前 buffer context，创建 inline 并 `prompt(args.args)` | `nil`；inline 创建失败时无 prompt |
| `inline_accept_word/line()` | 无参数 | Neovim <0.12 WARN 并返回；否则委托 completion provider |
| `prompt(alias, args?)` | prompt library alias、可选 context args | 找不到 alias WARN、无 prompt；成功委托 action resolve |
| `add(args)` | context args | `send_code` false/非支持值 WARN；无法创建 chat WARN；成功向最近/新 chat 插入 user code message 并打开 |
| `chat(args?)` | `params`, `subcommand`, `messages`, `user_prompt`, `context`, `callbacks`, `auto_submit`, `window_opts` | 返回 Chat 或 nil；`add/toggle/refreshcache` 子命令转委托；adapter/model/command 由 adapter resolver 与 chat new 决定，具体无效 adapter 错误未在本模块闭合 |
| `cmd(args)` | `args.args` 及当前 buffer context | `nil`；command interaction 创建成功则 start，否则无动作 |
| `toggle(args?)` | 可选 `params`, `window_opts` | `nil` 或新 Chat；无 chat 创建；可见 chat hide；隐藏 chat 更新 context、关闭旧窗口并重开 |
| `restore(bufnr)` | buffer number | `nil`；无效 buffer 或非 chat ERROR；已可见时尝试切换其 window，否则 open |
| `buf_get_chat(bufnr?)` / `last_chat()` | 可选 buffer / 无参 | 返回 Chat/table 或 nil，完全委托 chat registry |
| `close_last_chat()` | 无参 | `nil`，委托关闭最近 chat |
| `actions(args)` | action palette 参数表 | `nil` 或下游 launch 返回值；context 由当前 buffer 捕获 |
| `chat_refresh_cache()` | 无参 | `nil`；刷新 tools/slash cache 并 INFO notify |
| `register_extension(name, extension)` | 名称与 extension 实现 | `nil`；注册异常 pcall 后 ERROR，不向调用方抛出 |
| `has(feature?)` | 字符串、字符串数组或 nil | 字符串表示是否存在；数组要求全部存在；nil/其他类型返回 feature 列表 |
| `version()` | 无参 | 读取并缓存 `version.txt` 的去空白字符串；读取失败返回 nil |

**API 边界场景**：`chat` 仅在 `args.user_prompt` 非空时追加 user message；有 messages 时默认 auto-submit，否则默认不 auto-submit，显式 `auto_submit` 覆盖。`restore` 的 `%d` 错误格式要求调用方传入可格式化的 bufnr；非数字输入的具体错误表现未测试。`has` 的非字符串/表输入返回 feature 列表而非布尔值。

## 3.4 重复 setup 与异常边界

**GIVEN** 同一 Neovim 实例已完成一次 `CodeCompanion.setup`，**WHEN** 再次调用 setup，**THEN** baseline 没有幂等 guard：它再次执行配置归一化、adapter 合并和 command 注册；`nvim_create_user_command` 对已存在的用户命令可能报错。command loop 未由 `pcall` 包裹，因此一旦该错误实际抛出，后续 completion、logger、extension、sticky 阶段不应被假定执行。

**GIVEN** `config.setup(opts)` 因保留字段、深合并输入或 Neovim API 错误抛出/提前返回，**WHEN** setup 调用，**THEN** `CodeCompanion.setup` 不提供总括式错误恢复；`constants` 是明确的 notify ERROR 提前返回，其他配置阶段异常是否抛出取决于底层 API。

**GIVEN** adapter 配置扩展或 logger 初始化失败，**WHEN** setup 执行，**THEN** 这些调用位于未包裹的直接调用路径；baseline 未定义统一降级协议。**GIVEN** completion provider require 失败，**THEN** 仅 WARN 并继续。**GIVEN** 单个 extension load 失败，**THEN** 该失败被 `pcall` 捕获并 ERROR，循环继续其他 extension。

**并发边界**：setup 没有锁、状态机或 running 标记；并发/重入调用及其命令注册、namespace 重建和 extension 重复加载结果未由 baseline 测试覆盖，标记为 open gap，不推断为安全或幂等。

## 3.5 Bootstrap 专项静态验证

本次针对 baseline commit 执行了以下静态检查：

- `git rev-parse HEAD`、`git show -s --format='%H%n%D%n%cI' HEAD`、`git show HEAD:version.txt`：确认 HEAD 为 `558518f8d78a44198cd428f6bf8bf48bfa38d76d`、tag `v18.7.0`、版本 `18.7.0`。
- `git cat-file -e "558518f8d78a44198cd428f6bf8bf48bfa38d^{commit}:<path>"`：确认 `plugin/codecompanion.lua`、`lua/codecompanion/{init,config,commands,health}.lua` 与 `tests/config.lua` 存在。
- `nvim --headless -u NONE +'set rtp^=...' +'lua assert(loadfile(.../lua/codecompanion/init.lua))' +'lua assert(loadfile(.../lua/codecompanion/config.lua))' +'qa!'`：Lua 文件语法加载通过。
- `GIT_PAGER=cat git diff --check -- .supermax/specs/modules/bootstrap-configuration/spec.md .supermax/specs/modules/bootstrap-configuration/index.md`：文档 whitespace 检查通过。

最近的上游测试流程仍不可用：`module 'mini.test' not found`，随后 Makefile 流程超时；因此没有动态 setup/idempotency 通过证据。

## 3. 失败、边界与外部依赖

| 情况 | 观察到的行为/结论 | 证据状态 |
|---|---|---|
| 重复 plugin load | 立即 return | baseline source-confirmed |
| Neovim < 0.11 | notify error 后 return；health 抛 error | baseline source-confirmed |
| FileType callback 的 buffer race | 无效 buffer 安全 return | baseline source-confirmed |
| BufEnter 排除项 | 不更新 current context | baseline source-confirmed |
| 无效 prompt alias | `log:warn`，不创建 prompt | baseline init evidence |
| 缺必需依赖/parser/library | health error | baseline source-confirmed |
| 缺可选依赖/parser/library | health warn | baseline source-confirmed |
| adapter schema/command completion 解析失败 | 返回空 completion | baseline source-confirmed |
| 重复 setup、setup 异常恢复、并发调用 | 源码无 guard；命令重复注册可能抛错；provider/extension 各自 pcall 隔离；并发未定义 | baseline static / open gap |

## 4. 默认值与配置影响摘要

Baseline provider/default breadth is non-normative evidence. Target defaults expose only OpenAI Chat Completions, OpenAI Responses, Anthropic Messages and Gemini native API, plus explicit timeout/proxy/model-cache/capability settings defined by `provider-contract`. Unsupported provider namespaces and interaction defaults are removed.

配置影响：provider 选择影响 Command completion 与 Chat 请求；keymap false 影响 Chat 可用按键；buffer variable exclusions 影响 current context 和 `ContextChanged`；`opts.send_code` 影响 `add` 是否插入选区代码；extensions/sticky/completion/log 配置影响 setup 注册副作用。

## 5. Coverage Matrix

| Operation | Normal | State/data | Failure/edge | External deps | Concurrency/idempotency | Validation | Status |
|---|---|---|---|---|---|---|---|
| plugin bootstrap | yes | partial | yes | partial | partial | static | partial |
| config merge/normalize | yes | yes | yes | n/a | missing | static | partial |
| public commands | yes | partial | partial | adapter/schema | missing | source only | partial |
| public Lua API | partial | partial | partial | interactions | missing | source only | missing |
| health | yes | n/a | yes | plenary/parser/curl/file/rg | n/a | source only | partial |
| docs/events | partial | missing | missing | n/a | n/a | inventory | partial |

## 6. Coverage Gaps / 未解决缺口

- defaults 已按 bootstrap/API 可观察影响分组补充；未逐一展开每个 tool/slash/variable/prompt 条目的动态 callback，因其行为属于后续交互模块。
- 未对所有动态 callback（窗口尺寸、token_count、rules enabled、adapter/schema）完成跨模块状态转移要求。
- 重复 setup 的确切 Neovim 命令注册错误文本、部分失败后的最终配置状态尚未通过 headless fixture 确认。
- 未发现 bootstrap/setup/health 专项 baseline 测试；现有命令测试不覆盖目标 setup contract。
- 未运行通过最近上游测试：依赖缺失 `module 'mini.test' not found`，随后 headless 进程在 Makefile 测试流程中超时终止；不得宣称测试通过。
- 未执行 latest-upstream delta、SuperMax downstream delta、跨模块最终审计。

## 7. 验证计划与实际结果

### 计划

1. 在 checkout 确认 HEAD、tag 与 `version.txt`。
2. 对 baseline 文件执行静态符号/路径核验。
3. 运行最近可用的 upstream bootstrap/configuration tests；若无专项测试，记录精确缺口。
4. 若测试依赖可恢复，补运行 baseline 可用的配置/入口静态或 headless 检查，并记录精确命令。

### 实际结果

- 身份验证通过：
  - `git -C ~/.local/share/nvim/lazy/codecompanion.nvim rev-parse HEAD` → `558518f8d78a44198cd428f6bf8bf48bfa38d76d`
  - `git show -s --format='%H%n%cI%n%D' ...` → baseline、`2026-02-18T08:00:51Z`、`HEAD, tag: v18.7.0`
  - `git show ...:version.txt` → `18.7.0`
- 静态验证通过：baseline 中存在 `plugin/codecompanion.lua`、`lua/codecompanion/{init,config,commands,health}.lua`、`tests/config.lua` 与命令测试路径。
- Upstream test harness blocked: `module 'mini.test' not found` (`scripts/minimal_init.lua:7`); `MiniTest` remained nil and the Makefile flow timed out after 300 seconds.

## 8. Source Trace

所有下列引用均以 baseline commit `558518f8d78a44198cd428f6bf8bf48bfa38d76d` 为前缀：

- `plugin/codecompanion.lua`: loaded guard、Neovim gate、highlights、`FileType`、`TermEnter`、`BufEnter`、treesitter registration。
- `lua/codecompanion/config.lua`: `defaults`（约行 12 起）、`M.setup`（约行 1074）、`M.can_send_code`、metatable `__index`。
- `lua/codecompanion/init.lua`: baseline setup, Chat, Actions, prompt and state APIs; removed interaction APIs are not target surface.
- `lua/codecompanion/commands.lua`: baseline command descriptors; target retains Chat and Actions entrypoints and redefines Commands inside the runtime.
- `lua/codecompanion/health.lua`: `M.check`、`deps`、`parsers`、`libraries`。
- `tests/config.lua`: baseline configuration fixture.
- `README.md`: checkhealth/setup user guidance；`doc/configuration/others.md`: `send_code` configuration examples；`doc/usage/events.md`: public event names and timing descriptions。

## 9. Latest-upstream 与 downstream 分离状态

### Latest-upstream

未检查。固定比较点 `2b959b2bf5fdb13e3b333c078ba549996e477b7c` 不得混入本 baseline requirements。

### SuperMax downstream

未检查。`lua/util/hooks/`、`lua/util/codecompanion/`、`lua/codecompanion/_extensions/`、`lua/util/mcphub/` 均明确排除。

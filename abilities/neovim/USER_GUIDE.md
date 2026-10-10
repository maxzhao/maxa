# Neovim Lua 执行与 LSP 只读查询

Agent 加载 `neovim` 后，通过 `run(scope="@neovim:lua")` 在当前 Neovim 中执行 Lua，通过现有 `search` 查询符号、定义、引用和一层调用关系，通过 `read` 查询悬停信息和诊断。LSP 查询自行启动或复用已启用、已安装的服务器；不需要先打开代码文件，不会安装服务器、保存源码或丢弃未保存编辑。

## 在当前 Neovim 执行 Lua

示例请求：“加载 neovim，通过 Lua 查看当前 buffer 编号和已加载模块，不要修改编辑器状态。”

执行时使用 `run` 的 `title` 和 `scope="@neovim:lua"`，源码放在 `command`；原独立 `lua` 工具及其 `code` 参数已移除。不传 `args`、`cwd`、`timeout` 或 `opts`。

Lua 不是只读查询，也不是沙箱：它可以修改编辑器状态或文件，执行失败不会回滚此前的副作用。执行为同步方式，阻塞代码会阻塞 Neovim，没有硬超时或可取消的后台执行。无输出会明确提示；长输出返回预览和完整临时文件路径。

## LSP 符号查询

| 范围 | scope |
| --- | --- |
| 整个项目 | `@neovim:symbols` |
| Lua 语言 | `@neovim:symbols:lua` |
| 含点号的原生 filetype | 将 `.` 写成 `_`，例如 `@neovim:symbols:yaml_docker-compose` |
| 相对路径文件 | `@neovim:symbols:lua/maxa/abilities/catalog.lua` |
| 显式相对路径 | `@neovim:symbols:./lua/maxa/abilities/catalog.lua` |
| 绝对路径文件 | `@neovim:symbols:/absolute/path/xxx.lua` |

冒号后有文件后缀名则判断为文件，否则判断为语言。语言映射来自实际配置，不会把原有下划线随意改成点号。

示例请求：

- “使用 neovim 搜索整个项目中的 normalize 符号。”
- “只搜索项目里的 Lua 符号，最多返回 10 个。”
- “搜索 lua/maxa/abilities/catalog.lua 的 parse_metadata 符号，不要让我手动打开文件。”

项目搜索要求服务器支持 `workspace/symbol`；文件搜索要求 `textDocument/documentSymbol`。不支持、启动失败或启动／请求／筛选总计超过 10 秒会明确报错，不会悄悄改成文件内容搜索。

查询使用互斥的 `text`／`regex`，支持非空字符串或字符串列表；旧 `patterns`／`literal` 已删除。文件符号的 `text` 按名称做大小写敏感字面子串匹配；项目 `text` 使用服务器原生匹配。所有 `regex` 使用 ripgrep 默认 Rust 正则，不使用 Lua pattern 或 Vim regex。项目正则先用空查询获取服务器候选，再筛选符号名，结果明确标注完整性未知；零匹配不能证明项目中不存在目标。服务器拒绝空查询、缺少 rg 或正则错误时明确报错。候选达到 10,000 条／名称 1 MB 安全上限会标明截断。

结果包含路径、1-based 行号和 UTF-8 字节列号。项目内路径是相对路径，显式指定的项目外文件保留绝对路径。索引完整性取决于服务器，不能保证穷尽所有符号。普通文件搜索和读取不变；扩展只对当前 Chat/workspace 生效。

## 定义、引用与调用关系

提供明确的文件、行号和 UTF-8 字节列号；不要只给符号名或要求使用当前编辑器光标。地址最后两个冒号分隔坐标，文件名内部可以包含冒号。

| 目标 | `search.scope` |
| --- | --- |
| 定义 / 声明 / 实现 / 类型定义 | `@neovim:definition:<file>:<line>:<column>`；操作可换成 `declaration`、`implementation`、`type-definition` |
| 不含声明的引用 | `@neovim:references:<file>:<line>:<column>` |
| 包含声明的引用 | `@neovim:references-with-declaration:<file>:<line>:<column>` |
| 一层调用者 / 被调用者 | `@neovim:incoming-calls:<file>:<line>:<column>` / `@neovim:outgoing-calls:<file>:<line>:<column>` |

这些位置查询省略 `text`／`regex` 即不过滤；`text` 对完整结果行做大小写敏感字面子串 OR 匹配，`regex` 对同一结果行做 Rust 正则筛选。`text="*"` 只匹配真实星号，不再是不过滤哨兵。结果标明 provider 和范围；调用关系同时标明 caller、callee 和 caller 文件中的调用位置。多个候选都保留，不递归构建调用图。`output=files` 只列去重后的目标文件，`max_results` 在筛选后限制结果数并标明截断。

示例请求：“加载 neovim，查找 `tools/blender-cli/foundation.js:200:27` 的定义，再查询 `:38:17` 的引用和一层调用者；不要修改文件。”

## 悬停与诊断

- `read.path=@neovim:hover:<file>:<line>:<column>`：按 provider 分别返回类型、签名和文档，不打开浮窗。
- `read.path=@neovim:diagnostics:<file>`：优先请求 pull 诊断，否则观察 push/cache；每个 provider 返回条数和 `current`、`stale` 或 `unknown` 新鲜度。
- `read.path=@neovim:diagnostics`：只读当前已知的项目 LSP 缓存，不启动全项目检查，不混入其他工作区或非 LSP 诊断。

只有 `current` 且零条才能说明该 provider 当前报告无诊断；空缓存、无版本报告、`stale`、`unknown` 都不能证明文件或项目无错误。源码优先采用已加载 buffer 的最新文本，否则用磁盘文本，并标明来源；查询期间文本变化会明确报错。

长报告沿用 `read` 的 20,000 字节分块与 `next_cursor`。继续读取时保持地址、policy、Chat 和 workspace 不变，且不传行范围；它继续已冻结的报告，不重新查询服务器。行范围指报告文本的行。快照最多保留 5 分钟、每 Chat 8 份 / 4 MB，重启后不保留；过期后重新读取。普通 `temporary`/`persist` 结果生命周期不变。

示例请求：“使用 neovim 查看该位置的悬停信息，并报告这个文件的诊断与新鲜度；不要将空缓存描述为项目干净。”

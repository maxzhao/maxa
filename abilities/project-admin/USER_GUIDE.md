# Project Admin 用户指南

`project-admin` 统一管理 Maxa 项目的 `.maxa/` 结构和基于 Obsidian 的项目知识库。直接说明目标即可，无需知道内部文档或脚本路径；Agent 会按场景读取操作指南。

## 项目治理

适合初始化、修复、迁移、升级项目结构和入口规则。

示例：

- “初始化当前项目的 `.maxa`，只创建必需目录。”
- “补齐缺失的 index/log，保留已有内容。”
- “检查 AGENTS.md 和实际项目配置是否一致。”
- “把旧 `.maxa/knowledge` 按 v0 到 v1 指南迁到根 Vault。”
- “这个项目需要 research 目录，为它建立索引和来源笔记。”
- “检查 Justfile 与 justfile.md 是否一致。”

初始化和 sync 都先检查 Git，包括因已有 `.maxa/` 从初始化转入 sync 的情况。未处于 Git 管理下时，说明功能限制并询问是否初始化 Git、继续无 Git 或取消；已有仓库不再创建嵌套仓库。流程切换复用有效检查结果和明确决定，不重复询问。本地初始化验证通过后，符合外部操作资格的项目会询问是否通过 Syncthing 多设备同步 `.maxa/`，同意后按确认的设备范围设置。已有明确同步决定不重复询问。

初始化建立 `inbox/`、`specs/`、`weave/`、`tasks/`、`drafts/`、`translate-cache/`、`attachments/`、`canvases/`。内容区 `ideas/`、`reports/`、`research/`、`rules/` 按实际需要建立。已有旧内容区需明确迁移，sync 不自动搬文档或创建平行体系。

`.maxa/AGENTS.md` 保留稳定、低上下文规则；`.maxa/index.md` 路由到直属知识区索引。父索引不复制深层目录内容。迁移先确认内容归属和冲突，保留来源与可恢复副本。

## 知识查询、收录和整理

知识默认留在当前项目的 `.maxa/`，不写入全局 Vault，也不在项目间同步 Markdown 笔记。

示例：

- “查项目知识库里这个模块的规格、调研和历史决策，先走入口和索引。”
- “把这批资料收录为带来源的 source-summary 和 synthesis。”
- “新笔记用英文 slug 文件名，中文或中英混合语义 title。”
- “整理 inbox capture，先给聚类和合并方案，再处理确认的内容。”
- “检查这份笔记能否从根索引被 Agent 找到，修复入口。”

收录先查重复，保留来源、事实/推断/未确认问题，更新最近索引和所属日志。查询结果只有在你要求保存时才直接持久化，否则先询问。

经验是否值得捕获由 `self-improvement` 判断；本能力负责通用知识维护。TaskAdmin 任务仍由 `task-admin` 执行，不导出重复知识/TODO 文件。

## 知识编织 weave

文章保留在语义内容区；`weave/` 是 LLM 维护的主题地图、概念节点与关系网络，不收录全文。人负责选材、提要求和反馈，LLM 维护派生节点。收录与编织分开；查询和检查默认只读。

示例：

- “把 research 和 rules 中关于工具可靠性的知识编织起来，不改来源。”
- “更新这个主题的 weave，只处理上次以后变动的来源。”
- “先找到主题，再沿链接核对相关规格和证据。”
- “查这篇文章的反向链接，找到相关 weave 节点和其他资料。”
- “检查 weave 的尺寸、来源时效和断链，只诊断。”
- “修复这个主题的关系和引用，不重建其他主题。”
- “把旧 wiki 内容迁到语义内容区，建立 weave，彻底移除旧目录和兼容入口。”

完整 UTF-8 文件预算：索引 2048 bytes；概念 3072；主题通常 4096、最大 6144。先删除重复和回归来源细节，再按独立问题拆分，不机械切碎文章。实际 token 数随模型变化。查询支持主题优先与来源优先；未编织资料仍可直接检索。

编织不自动修改来源、移动文件、扫描 Syncthing 或接受新规格。旧内容迁移先逐篇分类与防覆盖检查，保留有价值的正文和来源，再修复普通路径/元数据及 Obsidian 链接；完成后不保留旧目录、平行索引或专门旧体系归档。Git/TaskAdmin/Chat 历史不改写。

## 体检与图谱

体检默认只诊断，不移动、重命名、删除、归档、整理 capture 或处理 feedback。

示例：

- “做一次 Vault 体检，只诊断，说明文件侧和图谱覆盖。”
- “检查 frontmatter、title、断链和入口可达性。”
- “列出笔记路径和 title，标出不合规项。”
- “Obsidian 不可用，先做 quick 文件侧检查。”
- “查这份笔记的 backlinks 和 outgoing links。”
- “用已注册项目 Vault 的 CLI 修改这份笔记的 property。”

图谱操作使用验证后的项目 Vault，不依赖当前活动 Vault。缺失注册或目标冲突会明确报错；查询不会隐式注册或改绑。

## Feedback

反馈队列与普通 capture 整理相互独立。

示例：

- “列出当前项目 pending feedback，不处理。”
- “处理反馈，先核对目标和选中文本，再最小修改。”
- “监听 feedback，有新反馈就处理，直到我停止。”

处理后记录目标修改、反馈状态、changed_files 和日志。引用不匹配或缺少证据时先询问；仍无法处理则标记 failed，不猜测正文。

## Obsidian 文档功能

示例：

- “给笔记补 wikilink、callout、embed 和 aliases。”
- “创建 `.base` 表格，按状态筛选阅读笔记。”
- “创建 `.canvas`，用文件节点引用长正文，检查连线和 ID。”
- “新增 TODOseq 项，带优先级、SCHEDULED 和 DEADLINE。”

TODOseq 维护笔记中的任务语法，不替代 TaskAdmin 的执行状态。

## 插件开发与分发

开发源为项目 `obsidian-plugins/<plugin-id>/`，发布目标为当前项目 `.maxa/.obsidian/plugins/<plugin-id>/` 的真实目录。

示例：

- “修改 grab-note，构建并发布到当前项目 Vault。”
- “这次只改源码，不发布。”
- “先 dry-run 查看插件配置分发目标，再应用。”
- “把当前项目的安全 Obsidian 插件配置分发到其他项目 Vault。”
- “只分发到指定 Syncthing folder id。”

运行时相关插件修改需要构建/语法检查、发布和运行时文件验证，除非你明确要求只改源码。分发仅复制受管理的 `.obsidian/` 插件和安全配置，不复制 Markdown 知识；默认保留目标私有 `data.json`。未指定目标范围的插件分发覆盖可发现的项目 Vault，排除源项目。

## 外部服务与多 Worktree

- Git 主 checkout（不是名称为 `main` 的分支）或独立非 Git 项目可注册/操作外部 Obsidian 与 Syncthing。
- Linked Worktree 使用自己的文件，不转向主 Vault、不创建替代注册。Git 跟踪的知识通过显式 Git 合并流转；草稿/缓存保持本地。
- 首次注册需明确请求，注册冲突不会自动改绑。身份无法确认时拒绝外部操作。
- WSL/Linux 原生路径由 WSL Syncthing 管理，Windows 挂载路径由 Windows Syncthing 管理，不双端注册。
- 日常编辑依赖文件监听；只有明确要求强制/即时/手动扫描才触发 scan。

示例：“检查当前 checkout 的外部操作资格，只诊断，不改注册。”或“修复这个 Worktree 的本地治理文件，不操作主 Vault。”

Obsidian 本体、CLI 与无头服务由 Maxa runtime 根目录的 `install.sh` 安装配置，不由本能力安装。项目 Vault 的显式注册、所有权验证与图谱操作仍由本能力管理；安装软件不会自动注册项目 Vault。

## 大代码文件盘点

示例：“用 project-admin 列出 Git 跟踪的大代码文件，按模块分类，先给语义拆分建议。”

默认阈值 50k bytes，使用 `scc` 分类。不会机械按行数拆分，也不会把盘点请求当作重构授权。

## 请求中可说明

- 操作目标：治理、查询、收录、整理、体检、反馈、文档格式或插件。
- 是否允许修复、移动、归档、覆盖同步，还是只诊断/dry-run。
- 目标笔记、选中文本、插件 ID、项目路径或 Syncthing folder id。
- 大批量修改是否先讨论方案再执行。

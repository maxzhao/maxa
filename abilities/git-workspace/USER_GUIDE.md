# Git Workspace 使用指南

Git Workspace 用于在同一台机器、同一用户环境下，为项目创建基于 `git worktree` 的隔离开发目录。

## 启用工作区模式

你可以这样说：

- “为当前项目启用 git workspace 模式”
- “帮我初始化 git workspace 配置”
- “创建一个 workspace 用来开发 feature-a”

Agent 会先给出建议配置，并询问你确认：

- workspace 放在哪里；
- workspace 和分支如何命名；
- 是否从当前 checkout 的 HEAD 创建；
- 哪些未被 Git 管理的文件需要复制，例如 `.vscode/`；
- 哪些本地文件需要始终链接到主工作区维护的唯一副本，例如 `.env`。

只有这些内容明确后，Agent 才会创建 `.maxa/workspaces.yml`。

## 声明 workspace 身份与职责

需要让 LLM 自动了解当前 checkout 时，可以要求 Agent 在同一份 `.maxa/workspaces.yml` 中增加显式定义：

```yaml
workspaces:
  - name: main
    path: /home/user/projects/example
    type: main
    responsibility: 共享基础、治理和最终集成
  - name: feature-a
    path: /home/user/projects/example-workspaces/example-feature-a
    type: child
    responsibility: 实现功能 A
```

每个 workspace 都直接读取自身目录中的配置。当前项目绝对路径精确匹配定义时，生成的模型上下文才包含名称、`main|child` 类型和职责；缺失、无效或未匹配时不生成 workspace 标签。创建 workspace 不会自动添加定义，也不会根据分支或目录名猜测职责。

## 创建 workspace

示例：

- “创建一个名为 feature-auth 的 git workspace”
- “在新的 workspace 中开发登录功能”

创建成功后，Agent 会复制配置中指定的未跟踪文件，为链接项创建指向主工作区文件的符号链接。如果当前项目已初始化 TaskAdmin，还会在**新工作区**创建或复用同名 tag、绑定该工作区并切换，然后按顺序运行初始化命令；来源工作区的 tag 不变。未初始化 TaskAdmin 时会明确跳过 tag 配置，保留原有创建流程。已有 tag 与别的工作区绑定或包含未绑定的既有任务时不会强行覆盖；如果 Worktree 创建后配置 tag 失败，将保留工作区并报告尚未完成的配置。每条初始化命令可指定相对于新 Workspace 根目录的执行目录。目标已存在时会跳过并提醒，不会覆盖；链接源不存在时会失败，不会创建悬空链接。初始化命令失败时，后续命令停止，但 Workspace 会保留以便修复。

## Worktree 与知识库同步

新 Worktree 会继承项目知识文件，但不会注册到 Obsidian/Syncthing，也无需每次人工配置。只有 Git 主 checkout 可以进行外部 Vault 操作；Worktree 通过文件工具维护自身 `.maxa/`，受 Git 管理的知识通过显式 Git 合并进入主 checkout，忽略的草稿/缓存仍留在本地。

可以说：“创建 workspace，并保持知识库注册仍归主 checkout。”不要把整个 `.maxa/` 链接/复制到其他 checkout，也不要在初始化命令中加入 Vault 注册。误调用受保护的外部操作会直接拒绝，而不是改变主 checkout 的注册。

## 配合 TaskAdmin 检查工作区

TaskAdmin 负责 tag 与任务的元数据及绑定。进入已有子工作区管理任务前，Agent 会确认它的身份，并通过 TaskAdmin 切换到与子工作区同名的 tag；主工作区可以保持自己的任意 tag，不要求使用 `master`。执行已绑定任务时则是另一项检查：Git Workspace 验证对应工作区是否存在、当前 checkout 是否正确，不会因此自动切换工作区或修改绑定。任务级绑定仍优先于 tag 绑定。

你可以这样说：

- “检查任务 3 当前绑定的 workspace 是否与 checkout 一致。”
- “验证 TaskAdmin 任务 4 的工作区后再执行。”

检查失败时，Agent 会报告预期与当前路径并阻止实现修改；不会在任务执行过程中自动创建、切换或改写绑定。需要设置或清除绑定时，直接要求 Agent 修改 TaskAdmin tag 或任务绑定。

## 合并时的规格检查

可以说：“把主工作区同步到 feature-a，先检查规格是否满足合并条件。”或“把 feature-a 合回主工作区，阻止未接受的规格进入。”

Agent 会先确认来源、目标和方向，再检查来源工作区及实际待合入的 Git 版本：

- **主 → 子**：变更行为必须已提升为正式规格，`.maxa/specs/changes/` 必须不存在或完全为空；归档记录、归档目录、索引和占位文件也不能保留。仅标记 `accepted` 或删除变更文件不代表已完成提升。
- **子 → 主**：`changes` 下所有变更 proposal 和 delta spec（包括归档记录）都必须明确为 `status: accepted`；草稿、其他状态、缺失或无法读取的状态都会阻止合并。

这项检查也适用于快进合并和用于同步的 rebase，不改变脚本复制未跟踪文件的 `sync` 或创建 workspace 流程。未使用 `.maxa/specs/` 的项目跳过规格检查。条件不满足时，Agent 会停止合并并列出阻塞项，不会自动删除归档或改状态来绕过检查；规格提升和归档处理仍由另行授权的 SpecAdmin 操作负责。

## 合并不同 workspace 中的 TaskAdmin 任务

可以说：“合并 feature-a 和 feature-b，并收敛两个 workspace 中重复或冲突的 TaskAdmin 任务。”

Agent 会根据 Git merge base、task 的 tag/整数 ID、plan、TODO、依赖和实现证据完成任务对账：新建 ID 冲突先在待合并分支重编号，同一任务的分支更新进行语义合并，重复工作收敛到一个 canonical task，不同工作即使同名也保留为独立任务。合并前会记录**目标工作区**当前活动的 TaskAdmin tag，合并后检查并恢复该 tag，包括快进合并；不会把主工作区强制切到 `master` 或来源子工作区的 tag。Agent 会自行完成引用更新、依赖修复和验证，不会要求你人工比较文件；只有仓库证据无法解决且会改变产品结果的冲突决策，才会向你提出一个明确问题。

## 注意事项

- 这是本地单用户开发方式，不是安全沙箱。
- 可以复制或链接 `.env` 等本地文件，但 Agent 不会输出文件内容。
- 清理 workspace 前会检查未提交、未跟踪、未推送内容；有风险时会拒绝自动清理。

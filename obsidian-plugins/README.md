# 自维护 Obsidian 插件

本目录集中维护由 Maxa 自己维护的 Obsidian 社区插件源码与构建产物。项目 `obsidian-plugins/` 是开发源头；当前项目 `.maxa/` Vault 通过 `project-admin` 的发布脚本接收真实插件目录，不使用指向项目目录的软链接。

## 插件列表

- `disable-unresolved-link`：阻止点击未解析链接时创建新笔记。
- `grab-note`：在阅读视图选中块、添加本地反馈草稿，并通过侧窗批量生成 feedback 文件。
- `sync-conflict-resolver`：基于 Syncthing `.stversions` 做冲突处理，提供可视化 diff/merge UI。

## 标准工程结构

每个插件目录都是独立的 Obsidian 插件工程：

```text
<plugin-id>/
├── manifest.json          # Obsidian 插件元信息，id 必须等于目录名
├── src/main.ts            # 源码入口
├── main.js                # esbuild 构建产物，Obsidian 实际加载
├── package.json           # npm 脚本与开发依赖
├── tsconfig.json          # TypeScript 配置
├── esbuild.config.mjs     # Obsidian 插件构建配置
├── styles.css             # 可选，Obsidian 运行时样式
└── .gitignore             # 排除 node_modules / 日志
```

开发时修改 `src/main.ts`，不要手写 `main.js`；`main.js` 由构建脚本生成。

## 构建

单个插件：

```bash
cd obsidian-plugins/grab-note
npm install
npm run build
```

三个插件统一构建：

```bash
for plugin in disable-unresolved-link grab-note sync-conflict-resolver; do
  (cd "obsidian-plugins/$plugin" && npm install && npm run build)
done
```

开发监听模式：

```bash
cd obsidian-plugins/grab-note
npm run dev
```

## 开发期发布到当前项目 Vault

发布目标：`.maxa/.obsidian/plugins/`。插件目录必须是真实目录，不能是指向项目外部的软链接。脚本从项目 `obsidian-plugins/` 发布运行时产物，排除源码、依赖、构建配置和默认私有 `data.json`。

```bash
# 手动维护命令：dry-run
uv run --project abilities/project-admin python abilities/project-admin/scripts/sync_dev_plugins_to_project_vault.py --project-root "$PWD" --json

# apply；不隐含强制 Syncthing scan
uv run --project abilities/project-admin python abilities/project-admin/scripts/sync_dev_plugins_to_project_vault.py --project-root "$PWD" --apply
```

## 与项目知识库插件同步的关系

项目插件分发以当前项目 `.maxa/.obsidian/` 为来源，只复制安全插件/配置到其他项目 Vault，不复制 Markdown 知识。目标插件目录同样为真实目录。

默认保留目标私有 `data.json`，除非在 `project-admin` 的 `scripts/obsidian_plugin_sync_allowlist.json` 中显式允许。

## 修改后的验证

修改插件后建议至少验证：

```bash
# 1. 三个插件都能从源码构建
for plugin in disable-unresolved-link grab-note sync-conflict-resolver; do
  (cd "obsidian-plugins/$plugin" && npm run build)
  node --check "obsidian-plugins/$plugin/main.js"
done

# 2. 开发期同步 dry-run
uv run --project abilities/project-admin python abilities/project-admin/scripts/sync_dev_plugins_to_project_vault.py --project-root "$PWD" --json

# 3. 项目知识库同步 dry-run
uv run --project abilities/project-admin python abilities/project-admin/scripts/sync_project_plugins.py --source-project-root "$PWD" --json
```

如果插件行为发生变化，还需要发布到当前项目 Vault 后，在 Obsidian 中重载插件或重启 Obsidian 进行手动交互验证。

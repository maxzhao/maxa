---
title: Backlot 中英文客户端 i18n 增量
created: 2026-10-13
updated: 2026-10-13
type: source
doc_role: spec
authority: proposed
status: draft
change_id: openmontage-backlot-i18n
capability: openmontage-project-support
taskadmin_tag: master
taskadmin_id: 123
validation:
  automated: not-run
  human: not-run
---

# Delta: Backlot i18n

## ADDED Requirements

- **界面语言选择**：Backlot 只提供 `zh` 和 `en`。有效客户端手动偏好优先；没有有效偏好时按浏览器语言偏好顺序选择第一个受支持语言，`zh-*`→`zh`、`en-*`→`en`，无匹配回退英文。手动切换立即更新当前界面，并在客户端持久化，刷新和同源项目列表/看板导航保持一致；存储不可用或无效时不得阻断页面，按浏览器默认处理。不增加服务器语言/用户配置。
- **翻译边界**：HTML `lang`、标题、界面控件/提示/状态/审核/回放/弹层/tooltip使用相应语言。技术标识、路径、API/schema key及用户项目标题/脚本/资料保持原文；格式化固定状态文案可以翻译其显示，不改变状态值。实时更新不能把界面重置到另一语言，原有播放/回放/主题交互保持。
- **项目更新**：新初始化项目包含相同语言资源。明确授权的当前浏览项目可以更新 UI，但须记录源码/identity 修改并保留制作文件、审批/费用及服务归属；其他项目不自动迁移。当前 LAN 服务保持供用户浏览。

## Validation

- 真实浏览器以无偏好的中文/英文语言配置加载，观察默认/lang/title；手动两向切换后刷新和列表↔看板导航，观察客户端偏好和原文内容。
- 实际受影响审核/回放/播放或主题控件观察，无页面/控制台错误；静态语法/契约检查仅为补充，不新写 UI测试或 mock app。

## Source Trace

- [提案](../../proposal.md)；正式 owner [OpenMontage](../../../../abilities/extensions/openmontage/project-support.md)，task `master/123`。

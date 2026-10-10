---
title: Backlot 中英文界面与客户端语言选择
created: 2026-10-13
updated: 2026-10-13
doc_role: change-proposal
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

# Backlot zh/en

用户最新请求替代直接中文化：支持中文/英文，根据浏览器选择默认语言，允许手动切换，偏好只保存在客户端。

- 在项目列表与制作看板复用最小静态语言资源/选择机制；不增加 i18n 框架、服务器语言状态或登录体系。
- 翻译界面控件、状态、提示、回放/审核/弹层、标题/lang；不翻译项目脚本/标题/资料、API/schema key、工具/模型/文件标识。
- 更新未来初始化模板及用户正在浏览的明确项目，记录源码归属更新；其他已有项目不自动迁移。保留当前 LAN 监听、端口、媒体/审批/费用和只读性质，服务留给用户浏览。
- [拟议规则](./specs/openmontage/spec.md)；正式 owner [项目支持](../../abilities/extensions/openmontage/project-support.md)。实现/验证由 task master/123 拥有。
- 验证使用真实浏览器默认语言、手动切换、刷新/列表↔看板、内容保留和受影响交互，不新建测试 runner、mock app 或媒体调用。

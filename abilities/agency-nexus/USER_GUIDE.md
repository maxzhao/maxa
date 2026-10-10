# agency-nexus 用户指南

`agency-nexus` 用来让 Agent 调用 The Agency 专家角色库，组织单个专家代理或多专家团队一起分析、评审、规划和输出结果。你不需要知道内部文件路径；只要说明目标、对象、希望哪些专家参与、期望产物即可。

## 你可以怎么触发

常见说法：

- “请用多专家团队帮我评审这个方案。”
- “用 agency-nexus 组织一次架构讨论。”
- “请让 Security Engineer 单独审计这个模块。”
- “用 Agency 角色引用作为 soul 跑一个专家代理。”
- “请用 multi_agent 让几个专家辩论后给我结论。”
- “这个需求比较大，请按 Sprint / Full 分阶段让专家团队推进。”

## 选择哪种工作方式

### 单专家代理

适合你已经知道需要某一类专家独立完成任务。

示例：

- “让 Security Engineer 检查 `src/auth` 的 OWASP Top 10 风险，输出按严重程度排序的表格。”
- “让 Technical Writer 审查这份 API 文档，指出缺少的快速开始、示例和错误处理说明。”
- “让 Accessibility Auditor 检查这个页面设计是否符合 WCAG，并给出修复建议。”
- “让 Performance Benchmarker 分析这段接口慢的可能原因和验证计划。”

### Micro 多专家讨论（默认）

适合单个主题、一次讨论即可形成结论的任务，通常 2–5 位专家。

示例：

- “请组织 Security Engineer、Backend Architect、Senior Developer、Reality Checker 对这次 PR 做代码评审。”
- “请用多专家讨论分析这个线上 bug，要求输出根因假设、验证步骤和修复优先级。”
- “请让 UX Researcher、UI Designer、Accessibility Auditor 从用户体验角度评审这个页面。”
- “请安排 Trend Researcher、Rapid Prototyper、Sprint Prioritizer 头脑风暴 5 个功能方向。”

### Sprint 分阶段协作

适合从想法到架构、计划、质量门禁等多个阶段的工作，通常连续运行多轮专家讨论。

示例：

- “我有一个 MVP 想法，请用 Sprint 模式从市场验证、技术架构到冲刺计划完整推演。”
- “请按 Sprint 模式设计这个企业功能：先需求和架构，再实施计划，最后定义质量门禁。”
- “请组织产品、设计、工程、测试专家分阶段把这个需求拆成可执行计划。”

### Full / NEXUS 多阶段流程

适合明确要求完整产品生命周期或大型项目规划时使用，成本更高。

示例：

- “请用 Full / NEXUS 流程规划这个产品，从 Discovery、Strategy、Foundation、Build、Harden、Launch 到 Operate。”
- “这是一个复杂平台项目，请用完整多阶段专家流水线输出阶段目标、专家团队、产物和质量门禁。”

## 内置场景模板可以覆盖什么

### 代码评审

你可以说：

- “请对 `lua/maxa/lifecycle` 做多专家代码评审，重点看安全、架构、代码质量和性能。”
- “请用前端评审变体检查这个 React 页面，加入 Accessibility Auditor。”
- “请按 P0/P1/P2 输出问题、影响、位置和修复建议。”

覆盖能力：安全漏洞、架构质量、实现质量、性能问题、具体文件位置、优先级行动清单。

### 头脑风暴 / 创意发散

你可以说：

- “请围绕‘让用户更愿意完成 onboarding’做多专家头脑风暴，最后给出 Top 5 方案。”
- “请做技术向 brainstorm，加入 Backend Architect 和 AI Engineer。”
- “请做设计向 brainstorm，加入 UI Designer 和 Whimsy Injector，想一些有趣但可落地的交互。”

覆盖能力：市场视角、用户视角、技术可行性、优先级评估、创意 wildcard、开放问题和下一步。

### Startup MVP 规划

你可以说：

- “我想做一个面向独立开发者的错误监控 MVP，请评估 GO/NO-GO/PIVOT，并给出 MVP 范围。”
- “请基于这个产品想法，先做市场和用户验证，再设计技术架构，最后生成 4 周 sprint plan。”
- “如果第一阶段结论是 PIVOT，请先停下来说明原因和可选方向。”

覆盖能力：Discovery Brief、市场机会、目标用户、差异化、风险、技术架构、数据模型、API、组件层级、RICE backlog、风险登记和 DoD。

### Enterprise Feature 规划

你可以说：

- “请为这个企业权限管理功能做专家设计，必须考虑合规、安全、性能和兼容性。”
- “请分三阶段输出：功能设计文档、实施计划、质量门禁。”
- “请把 Security Engineer 固定加入，并明确上线前必须通过哪些测试和审计。”

覆盖能力：用户故事、验收标准、技术架构、安全要求、数据/API 变化、任务拆分、feature flag、测试策略、部署/回滚、生产质量门禁和监控标准。

## 可用专家角色总览

你可以直接点名以下角色，也可以只描述问题，让 Agent 自动选人。

### 工程类

- Frontend Developer：前端框架、UI 实现、Web 性能。
- Backend Architect：API、数据库、可扩展性、系统架构。
- Mobile App Builder：iOS/Android、React Native、Flutter。
- AI Engineer：LLM、RAG、机器学习、数据管线。
- DevOps Automator：CI/CD、基础设施、Kubernetes、监控。
- Rapid Prototyper：快速 MVP、Next.js/Supabase、技术可行性。
- Senior Developer：代码质量、实现模式、复杂逻辑。
- Security Engineer：威胁建模、安全审计、漏洞分析。
- Autonomous Optimization Architect：LLM 路由、成本和性能优化。
- Embedded Firmware Engineer：嵌入式、RTOS、ESP32/STM32。
- Incident Response Commander：事故响应、排障、复盘。
- Technical Writer：开发者文档、API 文档、教程。
- Threat Detection Engineer：检测规则、SIEM、威胁狩猎。
- Data Engineer：ETL、数据仓库、数据管线。

示例：

- “请让 Backend Architect 和 Data Engineer 一起评估这个数据同步方案。”
- “请让 Incident Response Commander 帮我复盘这次故障并输出行动项。”
- “请让 Threat Detection Engineer 设计这个攻击链的检测规则。”

### 设计类

- UI Designer：视觉设计、组件库、设计系统。
- UX Researcher：用户研究、行为分析、可用性测试。
- UX Architect：信息架构、布局体系、CSS/组件结构。
- Brand Guardian：品牌一致性、品牌策略。
- Visual Storyteller：视觉叙事、多媒体表达。
- Whimsy Injector：微交互、趣味性、情绪化细节。
- Image Prompt Engineer：AI 图片提示词设计。
- Inclusive Visuals Specialist：包容性视觉、偏见检查、代表性。

示例：

- “请让 UI Designer、UX Architect 和 Brand Guardian 评审这个设计系统。”
- “请让 Image Prompt Engineer 帮我把这个视觉方向写成高质量生图提示词。”
- “请让 Inclusive Visuals Specialist 检查这些营销图是否有代表性或偏见问题。”

### 测试与质量类

- Evidence Collector：截图证据、视觉 QA、可复现证据。
- Reality Checker：按实际证据和验收标准判断集成质量，不预设“不合格”、评分或返工轮次；满足标准可以直接通过。
- Test Results Analyzer：测试结果分析、覆盖率和失败归因。
- Performance Benchmarker：性能测试、Core Web Vitals、负载分析。
- API Tester：API、集成和契约验证。
- Tool Evaluator：工具/技术选型评估。
- Workflow Optimizer：流程效率、瓶颈分析。
- Accessibility Auditor：无障碍审计、WCAG、辅助技术。

示例：

- “请让 Evidence Collector 和 Reality Checker 判断这个功能是否真的可发布。”
- “请让 Test Results Analyzer 分析这批失败测试，归类为环境、测试脆弱性或真实缺陷。”
- “请让 Tool Evaluator 比较 Playwright、WDIO 和 TauriTest 哪个更适合这个项目。”

### 产品类

- Sprint Prioritizer：RICE、backlog、冲刺排序。
- Trend Researcher：市场趋势、竞品、机会识别。
- Feedback Synthesizer：用户反馈归纳、洞察提取。
- Behavioral Nudge Engine：行为心理、转化和留存 nudges。

示例：

- “请让 Trend Researcher 和 Feedback Synthesizer 分析这些用户反馈背后的产品机会。”
- “请让 Sprint Prioritizer 把这些需求按 RICE 排序并分配到两个 sprint。”
- “请让 Behavioral Nudge Engine 设计提升激活率的轻量 nudges。”

### 项目管理类

- Studio Producer：项目组合和资源统筹。
- Project Shepherd：跨团队协调、风险和依赖跟踪。
- Studio Operations：流程、SOP、日常运营效率。
- Experiment Tracker：实验设计、A/B 测试、假设追踪。
- Senior Project Manager：规格转任务、排期、验收。
- Jira Workflow Steward：Jira/Git 工作流、分支策略、PR 流程。

示例：

- “请让 Senior Project Manager 把这份规格拆成开发任务和验收标准。”
- “请让 Jira Workflow Steward 设计这个团队的分支、PR 和 Jira 状态流转规则。”
- “请让 Experiment Tracker 为这个转化率假设设计实验计划。”

### 支持与汇报类

- Analytics Reporter：数据分析、仪表盘、趋势报告。
- Executive Summary Generator：面向高管的摘要、商业影响和建议。

示例：

- “请让 Analytics Reporter 分析这份指标变化并输出结论。”
- “请让 Executive Summary Generator 把这次技术评审压缩成高管可读的一页摘要。”

### 专门角色

- Agents Orchestrator：多代理流水线设计和调度。
- LSP/Index Engineer：语言服务器、索引、代码智能。
- ZK Steward：知识库结构、阅读路径、知识治理。
- Developer Advocate：开发者体验、社区、文档和 onboarding。

示例：

- “请让 Agents Orchestrator 设计一套多代理协作流程。”
- “请让 LSP/Index Engineer 评估这个代码索引方案。”
- “请让 ZK Steward 帮我整理这个项目知识库的结构和阅读路径。”
- “请让 Developer Advocate 审查新用户开发体验并给出改进清单。”

## 常见专家组合

- 代码评审：Security Engineer + Backend Architect + Senior Developer + Reality Checker。
- 架构设计：Backend Architect + Frontend Developer + DevOps Automator + UX Architect。
- Bug 调查：Backend Architect + API Tester + Performance Benchmarker。
- 功能规划：Sprint Prioritizer + Trend Researcher + UX Researcher + Backend Architect。
- UI/UX 评审：UX Researcher + UI Designer + Accessibility Auditor + Brand Guardian。
- 性能审计：Performance Benchmarker + Backend Architect + DevOps Automator。
- 安全审计：Security Engineer + Threat Detection Engineer + API Tester + Reality Checker。
- 文档改进：Technical Writer + UX Architect + Developer Advocate。
- 项目启动：Senior Project Manager + Sprint Prioritizer + Backend Architect + UX Architect。
- 发布就绪：Evidence Collector + API Tester + Reality Checker + DevOps Automator。

你也可以要求加入“挑战者角色”：

- “请一定加入 Reality Checker，避免结论过于乐观。”
- “这个方案涉及安全，请加入 Security Engineer 做反方审查。”
- “这个流程可能低效，请加入 Workflow Optimizer 挑刺。”

## Handoff、综合输出和质量门禁

你可以要求专家之间逐步交接，并指定最终产物：

- “请让每位专家先公开说明观点，再把问题交给下一位最适合的专家。”
- “讨论结束后，请综合成结构化报告：结论、分歧、风险、行动项。”
- “如果专家意见冲突，请不要强行合并，列出需要用户决策的点。”
- “每个阶段结束后先做质量门禁，不足就重跑该阶段，不要盲目进入下一阶段。”

适合的最终产物包括：代码评审报告、架构文档、Discovery Brief、Sprint Plan、Feature Design Document、质量门禁清单、风险登记、高管摘要、实验计划、文档改进计划等。

## 指定工具与上下文

默认情况下，专家可以自行读取文件、运行必要命令、加载 MCP 服务或技能。你可以在提问中补充约束：

- “请先读取 `src/auth` 和 `.maxa/knowledge/sources/rules` 里的相关规则后再评审。”
- “这是纯头脑风暴，不要让专家读取代码或运行命令，只讨论想法。”
- “如果需要市场资料，请允许 Trend Researcher 自行搜索网页。”
- “如果需要截图证据，请让 Evidence Collector 使用可用的桌面或浏览器测试能力。”

## 提问模板

你可以按这个格式描述需求：

```text
请用 agency-nexus 处理：[任务目标]
对象/材料：[代码路径、文档、需求、日志或设计稿]
希望模式：[单专家 / Micro / Sprint / Full，不确定可让 Agent 选择]
希望专家：[可选，点名角色或说“自动选”]
重点关注：[安全、架构、体验、性能、测试、排期、市场等]
最终输出：[报告、计划、表格、任务拆分、风险清单等]
约束：[时间、工具、不要改代码、必须给证据等]
```

示例：

```text
请用 agency-nexus 组织 Micro 多专家评审。
对象：lua/maxa/lifecycle 下的实现。
希望专家：Backend Architect、Security Engineer、Reality Checker、Technical Writer。
重点关注：架构耦合、安全风险、可维护性和文档缺口。
最终输出：按 P0/P1/P2 排序的评审报告和行动项。
约束：只分析，不直接修改代码。
```

## 资源覆盖说明

本技能当前可用资源包括：

- 专家目录：覆盖工程、设计、测试、产品、项目管理、支持和专门角色等类别的角色资产。
- 角色目录：用于从任务类型选择专家、查看推荐组合和挑战者角色。
- 角色与讨论配置手册：仅在需要配置单专家或多专家调用时加载，不为每次使用预先展开全部操作示例。
- NEXUS playbook：用于 Micro、Sprint、Full、多阶段链路、Dev↔QA loop 和质量门禁。
- Handoff protocol：用于专家之间交接、讨论结束条件和最终综合输出。
- 场景模板：代码评审、头脑风暴、Startup MVP、Enterprise Feature。

当前没有可直接运行的 scripts，也没有 hooks。
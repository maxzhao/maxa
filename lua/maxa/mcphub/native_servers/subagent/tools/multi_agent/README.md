# Multi-Agent Collaborative Discussion System

多 Agent 协作讨论系统，基于 MaxaAI 实现。多个 AI Agent 围绕任务进行循环讨论，通过 Handoff Tool 动态路由，支持会话持久化和用户干预。

## 概述

### 核心特性

- **多 Agent 协作**: 支持 2-N 个 Agent 参与讨论
- **动态路由**: Agent 通过 Handoff Tool 决定下一个发言者
- **Summary 传递**: 每个 Agent 能看到其他 Agent 的观点摘要
- **会话持久化**: 支持保存和恢复讨论会话
- **用户干预**: 支持暂停、插入消息、继续讨论

### 架构

```
MultiAgentCoordinator
├── agents: { A: AgentChat, B: AgentChat, C: AgentChat }
├── display_chat: Chat (with DisplayAdapter)
├── summary_store: { round -> { agent -> summary } }
└── event_emitter: 处理 Handoff 事件
```

## MCP Tool 接口

### 工具名称

`multi_agent`

### 参数说明

| 参数          | 类型   | 必填     | 说明                        |
| ------------- | ------ | -------- | --------------------------- |
| `id`          | string | 否       | 会话 ID，用于继续之前的讨论 |
| `agents`      | array  | 首次必填 | Agent 配置列表              |
| `task`        | string | 首次必填 | 公共讨论目标，代理未设置个人目标时使用 |
| `messages`    | array  | 否       | 共享 user/assistant/context 背景；一次加载，传给所有讨论代理与最终代理，并持久化 |
| `termination` | object | 否       | 终止条件配置                |
| `routing`     | object | 否       | 路由配置                    |

#### agents 配置

```json
{
  "agents": [
    {
      "name": "Researcher",
      "role": "Technical Researcher - 负责技术调研和方案探索",
      "soul": "可选：#ability[/path]、显式路径或完整内联 Soul",
      "goal_prompt": "可选的个人目标，作为每轮最后一条用户消息",
      "adapter": "powerful",
      "icon": "🔬"
    }
  ]
}
```

| 字段            | 类型   | 必填 | 说明                                |
| --------------- | ------ | ---- | ----------------------------------- |
| `name`          | string | ✅   | Agent 名称，用于显示和 Handoff 目标 |
| `role`          | string | ✅   | 角色描述，定义 Agent 的职责         |
| `soul`          | string | 否   | `#ability[/path]`、显式路径或完整内联 Soul；匹配失败不回退 |
| `goal_prompt`   | string | 否   | 默认使用 task；讨论记录和私信之后追加为最后一条用户消息，不修改 Runtime/Soul |
| `adapter`       | string | 否   | 已配置的 adapter preset key；使用与 run_agent 相同的父会话解析，未知 preset 报错 |
| `icon`          | string | 否   | 显示图标 (默认: 🤖)                 |

`instructions` 已移除并明确报错；个人任务迁移到 `goal_prompt`，最终任务使用 `final_prompt`。讨论协议作为用户背景提供，系统层仅保留 Runtime + Soul。

#### termination 配置

```json
{
  "termination": {
    "max_rounds": 10,
    "max_messages": 50
  }
}
```

| 字段           | 类型   | 默认值 | 说明         |
| -------------- | ------ | ------ | ------------ |
| `max_rounds`   | number | 10     | 最大讨论轮次 |
| `max_messages` | number | -      | 最大消息总数 |

#### routing 配置

```json
{
  "routing": {
    "initial_agent": "Researcher"
  }
}
```

| 字段            | 类型   | 默认值       | 说明             |
| --------------- | ------ | ------------ | ---------------- |
| `initial_agent` | string | 第一个 Agent | 首先发言的 Agent |

### 返回值

```json
{
  "success": true,
  "data": {
    "id": "ma_1234567890",
    "content": "格式化的讨论内容",
    "summaries": [
      {
        "agent": "Researcher",
        "round": 1,
        "summary": "Agent 的观点摘要"
      }
    ],
    "is_finished": true,
    "stats": {
      "total_rounds": 3,
      "total_messages": 12
    }
  }
}
```

| 字段          | 类型    | 说明                    |
| ------------- | ------- | ----------------------- |
| `id`          | string  | 会话 ID，可用于后续恢复 |
| `content`     | string  | 格式化的完整讨论内容    |
| `summaries`   | array   | 结构化的 Summary 列表   |
| `is_finished` | boolean | 讨论是否正常结束        |
| `stats`       | object  | 统计信息                |

## 使用示例

### 基本用法: 创建 3 Agent 讨论

```lua
-- 通过 MCP Tool 调用
call_tool({
  tool = "subagent__multi_agent",
  params = {
    agents = {
      {
        name = "Researcher",
        role = "Technical Researcher - 负责技术调研，探索可行方案",
        icon = "🔬"
      },
      {
        name = "Architect",
        role = "System Architect - 负责架构设计，评估技术方案",
        icon = "🏗️"
      },
      {
        name = "Reviewer",
        role = "Critical Reviewer - 负责审查方案，发现潜在问题",
        icon = "🔍"
      }
    },
    task = "设计一个高性能的缓存系统，需要支持 LRU 淘汰策略和分布式部署",
    termination = {
      max_rounds = 5
    }
  }
})
```

### 高级用法: 恢复会话

```lua
-- 使用之前的 session_id 继续讨论
call_tool({
  tool = "subagent__multi_agent",
  params = {
    id = "ma_1234567890",  -- 之前返回的会话 ID
    task = "请进一步讨论缓存一致性问题"  -- 可选：追加新的讨论任务
  }
})
```

### 高级用法: 自定义 Agent 配置

```lua
call_tool({
  tool = "subagent__multi_agent",
  params = {
    agents = {
      {
        name = "CodeExpert",
        role = "Code Expert - 专注于代码实现细节",
        soul = "你是一位资深的代码专家，专注于代码质量和最佳实践。",
        adapter = "coding",
        icon = "💻"
      },
      {
        name = "SecurityExpert",
        role = "Security Expert - 专注于安全性分析",
        soul = "你是一位安全专家，专注于发现和防范安全漏洞。",
        goal_prompt = "审查认证安全，聚焦 OWASP Top 10，以风险表格输出。",
        icon = "🔒"
      }
    },
    task = "审查这段认证代码的安全性",
    routing = {
      initial_agent = "SecurityExpert"  -- 从安全专家开始
    }
  }
})
```

## 讨论流程

### 正常流程

```
1. 创建 Coordinator 和 Agents
2. 第一个 Agent 收到任务，开始讨论
3. Agent 完成发言后，通过 Handoff Tool 指定下一个发言者
4. 下一个 Agent 收到其他 Agent 的 Summary，继续讨论
5. 重复步骤 3-4，直到:
   - Agent handoff 到 "user" (正常结束)
   - 达到 max_rounds 限制
   - 达到 max_messages 限制
6. 返回完整讨论内容和结构化 Summary
```

### Handoff Tool

每个 Agent 都配备 Handoff Tool，用于控制讨论流程：

```json
{
  "name": "handoff",
  "parameters": {
    "target": "下一个发言者的名称，或 'user' 结束讨论",
    "summary": "当前 Agent 的观点摘要",
    "reason": "选择该目标的原因"
  }
}
```

### 终止条件

讨论在以下情况下终止：

1. **正常结束**: Agent 调用 `handoff(target="user")`
2. **轮次限制**: 达到 `max_rounds` 配置
3. **消息限制**: 达到 `max_messages` 配置
4. **超时**: 讨论时间超过限制 (每轮 60 秒)

## 模块结构

```
lua/maxa/mcphub/native_servers/subagent/tools/
├── multi_agent.lua                    # MCP Tool 入口
└── multi_agent/
    ├── coordinator.lua                # 核心协调器
    ├── agent_chat.lua                 # 隐藏 Chat 封装
    ├── display_adapter.lua            # 自定义适配器
    ├── handoff_tool.lua               # Handoff Tool
    ├── summary_store.lua              # Summary 管理
    └── session_manager.lua            # 持久化管理
```

### 模块职责

| 模块                  | 职责                              |
| --------------------- | --------------------------------- |
| `multi_agent.lua`     | MCP Tool 入口，参数验证，异步等待 |
| `coordinator.lua`     | 核心协调器，事件驱动，状态管理    |
| `agent_chat.lua`      | 隐藏 Chat 封装，Handoff 检测      |
| `display_adapter.lua` | 自定义适配器，动态 formatted_name |
| `handoff_tool.lua`    | Handoff Tool 定义，事件发送       |
| `summary_store.lua`   | Summary 管理，轮次上下文构建      |
| `session_manager.lua` | 会话持久化，JSON 存储             |

## 测试

### 运行所有测试

```bash
# 单元测试
nvim --headless -c "luafile lua/util/mcphub/subagent/tools/multi_agent/display_adapter_spec.lua" -c "qa!"
nvim --headless -c "luafile lua/util/mcphub/subagent/tools/multi_agent/summary_store_spec.lua" -c "qa!"
nvim --headless -c "luafile lua/util/mcphub/subagent/tools/multi_agent/agent_chat_spec.lua" -c "qa!"
nvim --headless -c "luafile lua/util/mcphub/subagent/tools/multi_agent/coordinator_spec.lua" -c "qa!"

# busted 框架测试
nvim --headless -c "PlenaryBustedFile lua/util/mcphub/subagent/tools/multi_agent/handoff_tool_spec.lua" -c "qa!"
nvim --headless -c "PlenaryBustedFile lua/util/mcphub/subagent/tools/multi_agent/session_manager_spec.lua" -c "qa!"

# 集成测试
nvim --headless -c "luafile lua/util/mcphub/subagent/tools/multi_agent/integration_spec.lua" -c "qa!"

# E2E 测试
nvim --headless -c "luafile lua/util/mcphub/subagent/tools/multi_agent/e2e_spec.lua" -c "qa!"
```

### 测试覆盖

| 测试类型 | 测试数量 | 覆盖内容                                                                          |
| -------- | -------- | --------------------------------------------------------------------------------- |
| 单元测试 | 50+      | DisplayAdapter, SummaryStore, AgentChat, Coordinator, SessionManager, HandoffTool |
| 集成测试 | 17       | 3-Agent 动态讨论流程, Handoff 事件驱动, Summary 传递                              |
| E2E 测试 | 17       | 完整场景: 创建、讨论、终止、持久化、恢复                                          |

## 注意事项

1. **Agent 数量**: 建议 2-5 个 Agent，过多会增加讨论复杂度
2. **轮次限制**: 默认 10 轮，可根据任务复杂度调整
3. **超时处理**: 每轮最多 60 秒，超时会自动终止
4. **会话恢复**: 使用返回的 `id` 可以恢复之前的讨论
5. **资源清理**: 讨论结束后会自动清理资源

## 版本历史

- **v1.0.0**: 初始版本，支持多 Agent 协作讨论
- **v1.1.0**: 添加会话持久化和恢复功能
- **v1.2.0**: 添加用户干预功能 (暂停/继续/插入消息)

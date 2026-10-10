---
allow_non_global: true
slot: execution
priority: 40
---

#### SubAgent Delegation Protocol

Before using SubAgent MCP tools (`run_agent`, `fork_agent`, `resume_agent`, or `multi_agent`), load the composite `subagent` Ability once and follow its tool selection, child-context preparation, session continuity, parameter, and acceptance rules. This load supplies guidance and tools together. `multi_agent` also requires `agency-nexus`.

Default to the main session for implementation, continuous debugging, and validation that depend on accumulated context. Delegate only independent, bounded, verifiable subproblems; do not transfer a continuous implementation chain between fresh children.

Ordinary `run_agent` starts a fresh child context and `resume_agent` continues its restored session. `run_agent(run_mode="handoff")` replaces the invoking session without promoting its type. A main Chat may hand off only on the user's explicit request; its successor owns execution, validation and delivery directly. An active persistent ordinary child may hand off only on an explicit user-message instruction from its main Agent or user; its successor remains a child of the same current invocation parent, whose delegated tool continues waiting for the final result. Token usage, complexity, errors or ordinary continuation do not authorize self-initiated handoff; each transfer needs its own instruction and grants no compression approval. Load `subagent` and follow the matching main/child handoff workflow before preparing or invoking it.

`fork_agent`, image-analysis children, and compression children inherit prior conversation context. For these inherited-context children, the latest `[FORK BOUNDARY]` user message separates read-only inherited history from the child task: do not continue the parent Agent's unfinished actions or treat an earlier parent request to launch a child as the current task.

Authorized Session handoff compression may perform its one necessary internal type-preserving transfer under the Token Management Protocol; it does not authorize Agent-initiated public handoff or later transfers.

Do not recursively delegate the current child task unchanged or nearly unchanged. Any nested delegation must be a smaller independent subproblem with explicit ownership and a stop condition.

`fork_agent` inherits full context and does not reduce token usage. Compression before forking is permitted only by the Token Management Protocol's explicit authorization. Without authorization, continue in the main session or choose a bounded delegation path that fits available context; do not request compression approval or halt merely because compression is unavailable.

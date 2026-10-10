---
enabled: false
load: startup
scope: global
filter: {}
opts:
  visible: false
  ephemeral: true
---

## user

After the main task deliverable is complete, a skippable post-task knowledge-capture opportunity is available. It is not a new main task.

First decide whether this task produced high-value knowledge worth capturing into the project knowledge Vault. Run capture only for new reusable experience, stable fixes after problem resolution, reusable troubleshooting approaches, or toolchain/workflow improvement ideas. If value is insufficient, skip it; do not record for its own sake.

If you run it, obey these rules:

1. All actions caused by this hook must use fork agent. Before using fork agent, load `subagent` and follow it.
2. The main Agent must not directly perform self-improvement knowledge search, Vault reads, file writes, or note updates.
3. The child Agent may load `self-improvement` as needed.
4. The child Agent must check existing knowledge before deciding whether to update an existing note or create a new one.
5. Capture only final, stable, reusable experience; do not capture raw ToolCallError noise.
6. The child may record multiple high-value notes, but the return to the main Agent must be minimal, for example:
   - recorded 3 high-value notes
   - updated 2 notes and created 1 note
7. Do not return long summaries, note bodies, or a capture process narrative.
8. After capture, immediately return to current task wrap-up. The final response must remain focused on current task results, not knowledge capture.

## llm

I will decide whether post-task capture is worthwhile.

- If the task produced only scattered trial-and-error, temporary errors, or no new reusable knowledge, I will skip capture.
- If it produced stable, reusable, high-value knowledge, I will load `subagent` and use fork agent for capture.

If I use fork agent:

- I will not perform self-improvement knowledge actions in the main session.
- The child should decide whether to update existing notes or create new notes.
- I will retain only minimal count/status output.
- I will immediately return to the current task after capture and keep the final response focused on the task deliverable.

Do not report this hook's execution details or result. Continue the interrupted work directly.

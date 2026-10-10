-- Session workspace-only prepare/segment/apply operation; historical content uses indices.
return {
  name = "handoff_compact",
  description = "Prepare, segment or apply an active handoff compression workspace. Copies source history by index; apply switches to a saved successor after the tool batch.",
  inputSchema = {
    type = "object",
    properties = {
      save_id = { type = "string", description = "Source session ID shown by the workspace." },
      phase = { type = "string", enum = { "prepare", "plan", "apply" }, description = "Operation within the current workspace." },
      goal_prompt = { type = "string", description = "Successor's self-contained continuation goal; required for prepare." },
      handoff_text = { type = "string", description = "Concise task state; alternative to handoff_file." },
      handoff_file = { type = "string", description = "Readable nonempty handoff Markdown file; alternative to handoff_text." },
      context_files = { type = "array", items = { type = "string" }, description = "Required files to preload into the successor." },
      abilities = { type = "array", items = { type = "string" }, description = "Required Ability identifiers to load in the successor." },
      guidance = { type = "array", items = { type = "string" }, description = "Required exact Ability references to load after their Abilities." },
      segments = { type = "array", items = { type = "object", properties = {
        start_index = { type = "integer" }, end_index = { type = "integer" },
        description = { type = "string" },
        profile = { type = "string", enum = { "conservative", "balanced", "aggressive", "delete" } },
      }, required = { "start_index", "end_index", "description", "profile" } }, description = "Ordered source index intervals with brief content and retention tier; required for plan." },
      profile = { type = "string", enum = { "conservative", "balanced", "aggressive" }, description = "Chosen retention tier; required for apply, must match the user/config selection." },
      summary_text = { type = "string", description = "LLM-written useful information from omitted regions; alternative to summary_file, empty if none." },
      summary_file = { type = "string", description = "Readable LLM-written omitted-history summary file; alternative to summary_text." },
    }, required = { "save_id", "phase" },
  },
  handler = function(req, res)
    return require("maxa.session.handoff_compaction").handle(req, res)
  end,
}

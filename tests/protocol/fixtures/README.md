# Protocol Fixtures

Directory layout and envelope contract for maxa phase-1 protocol fixtures.

Authority: `.supermax/specs/protocol-fixture-contract.md` (authority: draft).
All fixtures are data assets consumed by `tests/protocol/runner.lua`
(headless fixture runner; adapter execution lands in W4-W7).

## Layout

```
fixtures/
├── openai_chat/          # OpenAI Chat Completions (9 scenarios)
├── openai_responses/     # OpenAI Responses (10 scenarios)
├── anthropic_messages/   # Anthropic Messages (8 scenarios)
└── gemini/               # Gemini native (11 scenarios)
```

Each directory holds one YAML file per scenario. Scenario ids follow the
contract names, e.g. `openai-chat/tool-arguments-fragmented.yaml` or
`gemini/safety-block.yaml`. The runner discovers every `*.yaml` recursively,
so nested grouping is allowed.

## Common fixture envelope

Every fixture SHALL contain:

```yaml
id: protocol-scenario-id
protocol: openai_chat|openai_responses|anthropic_messages|gemini
mode: streamed|non_streamed
request:
  normalized_messages: []   # normalized runtime messages (content-parts, W2+)
  normalized_tools: []      # normalized tool schemas
  provider_options: {}      # adapter/provider options for this request
  expected_body: {}         # expected provider request body snapshot
response:
  chunks: []                # stream chunks fed one at a time (streamed mode)
  expected_events: []       # ordered normalized events produced by the adapter
  expected_message: {}      # final normalized assistant message snapshot
  expected_tool_calls: []   # normalized tool call records
  expected_usage: {}        # normalized usage snapshot
  expected_terminal: completed|failed|cancelled|incomplete
```

`provider_options` and `expected_body` may be empty objects (`{}`) when the
scenario does not assert a request snapshot.

## Comparison rules (contract)

- JSON object key order is irrelevant; array order is significant.
- Empty JSON objects MUST remain objects, not arrays.
- Omitted optional fields and explicit `null` are distinct when the provider
  protocol distinguishes them.
- Stream chunks SHALL be fed one at a time. Adapters MUST NOT depend on
  receiving a concatenated transcript.
- Every scenario ends in exactly one normalized terminal event.
- Tool arguments are accumulated as UTF-8 bytes/text and decoded only at the
  tool-runtime validation boundary.
- Provider payload objects never become persisted normalized messages.

## Runner behavior

W1 runner scope: discovery, YAML decode (via `maxa.runtime.config.yaml` /
vendored TinyYaml), envelope validation, and the comparison helpers
(`deep_eq` / `diff_desc` / `assert_eq` / `expect`). Adapter execution and
event/message/usage assertions are added with W4-W7.

Run:

```bash
just test-protocol
# or directly (lazy-wait wrapper not required):
NVIM_APPNAME=nvim-maxa nvim --headless -l tests/protocol/runner.lua
```

Unit tests for the W1 infrastructure (offline, no fixtures needed):

```bash
NVIM_APPNAME=nvim-maxa nvim --headless -l tests/protocol/unit_sse.lua
NVIM_APPNAME=nvim-maxa nvim --headless -l tests/protocol/unit_transport.lua
```

## Live-recorded fixtures (phase-1 W9)
`<protocol>/live-stream.yaml` (openai_chat / openai_responses /
anthropic_messages) are real DeepSeek stream transcripts recorded on 2026-08-04
and replayed as ordinary layer-1 fixtures: chunks, `expected_events`,
`expected_message`, and `expected_usage` are exact snapshots of the recorded
run, so replay is deterministic (no live variance). They prove the adapters
parse the real provider wire format, including `reasoning_content` deltas
(openai_chat), semantic `event:` frames (responses), and thinking
`content_block_delta`s (anthropic). Regenerate with the W9 recording script
(requires `DEEPSEEK_TEST_KEY` and network; do not rerun lightly).
## Import-guard note

Fixtures are pure data. The runner, unit scripts, and all future adapter tests
must never `require` `codecompanion.*`, `mcphub.*`, or `lua/util/hooks/*`; the
runtime import-guard (`maxa.runtime.guard`) enforces this on load.

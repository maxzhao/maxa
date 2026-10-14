# Maxa

**An AI workspace inside Neovim.**

**English** · [简体中文](README.zh-CN.md) · [Video](https://www.bilibili.com/video/BV1LXpm6QEDw/)

[![Watch the video on BiliBili](https://i2.hdslb.com/bfs/archive/ac018a410a1352cc57db2eef539a5dbf09769011.jpg@308w_174h)](https://www.bilibili.com/video/BV1LXpm6QEDw/)

The name Maxa comes from _Max's Agent_. Maxa brings AI conversations, code completion, implementation, and project maintenance into the same Neovim environment.

Its agent can read and change code, run commands, use external tools, delegate independent work, and retain context across long tasks. Project-local files keep ideas, specifications, progress, and knowledge with the project.

Maxa is mainly for people who work in the terminal, especially developers who already use Neovim. It uses LazyVim as the editor foundation, with its own agent runtime and integrated MCP support.

## Why I built it

Before I started experimenting with Vibe Coding in the second half of 2025, Neovim was already my main development environment. I tried Copilot and CodeCompanion, moving from AI completion to conversations and then to agents working directly on projects.

As I started using this for real work, I kept adding the things I needed: better session management, more tools, longer-running workflows, and ways to preserve project knowledge. Eventually, maintaining those extensions around upstream interfaces took too much effort.

I decided to incorporate the parts that matched my needs and maintain the core runtime in Maxa. This gave me room to develop the agent and its workflows together. Maxa benefits from that upstream work, as well as MCPHub and the wider Neovim ecosystem.

For me, this is also a way to build my own IDE with AI. I want to shape my working environment alongside the projects I develop in it.

## What Maxa can do

### Work through Chat in the editor

Chat is Maxa's main entry point. It accepts selected code, files, buffers, terminal output, Quickfix entries, symbols, and images when the model supports them. The agent can search the project, edit files, run commands, and use loaded tools, with its work visible in the same editor.

Maxa presents tool output and reasoning separately, with controls to interrupt a request or stop after the current operation. Session and context usage are available for inspection. Independent tool calls can run in parallel; background work can be checked or cancelled.

For example:

> Find the cause of this error, make the smallest fix, and run the relevant checks.

### Keep working when a conversation gets long

Maxa saves conversations so work can continue from earlier progress. Its history includes browsing, search, restoration, and a tree of main and child sessions.

Session tools support persistent forks, temporary scratch branches, saving or merging added messages, and rewinding or resending inputs. Context monitoring, summarization, compaction, and recovery help continue work when a conversation grows or a request fails. Optional lineage tracing can be exported to Obsidian Canvas and Markdown.

Rewinding changes the conversation history; completed file edits and command effects remain in your working environment. Review those changes separately, using version control for file changes and handling command effects as needed.

### Delegate work, or bring different perspectives together

Maxa can delegate independent work with a clear deliverable to subagents. It supports fresh children, forks of the current context, and resuming saved child sessions, with task-specific context and tool restrictions.

Multi-agent discussions bring together different models or specialist roles from The Agency to compare views on a design, review, or idea. Discussion helps shape the approach; implementation and verification follow as their own steps.

### Extend the agent—and the editor itself

Maxa organizes extensions as **Abilities**. An Ability can combine instructions, references, templates, scripts, MCP tools, and lifecycle hooks. The agent loads the relevant capability when it needs it, keeping the conversation focused on the current work.

Packages use `SKILL.md`, with optional Maxa metadata in `ABILITY.yaml`. There are global packages and project-local packages, and projects can control their availability. Each Chat explicitly loads an Ability to authorize access to its MCP tools.

The agent can find existing capabilities, inspect them, and help integrate and validate them. It can also modify Maxa and the editor configuration. The Neovim Ability supports Lua execution in the current editor and LSP queries for symbols, definitions, references, hover information, diagnostics, and one-hop call relations.

Standard Skill files provide a portable instruction format. The Maxa runtime supplies its tool execution, hooks, and capability-addressing features. Lua executes directly in the current Neovim process with access to editor state and the user's permitted files and commands.

### Keep ideas, tasks, specifications, and knowledge with the project

Maxa uses the project-local `.maxa/` directory to keep work recoverable and knowledge discoverable:

- **TaskAdmin** keeps implementation plans, live TODO state, tags, dependencies, and completion evidence.
- **SpecAdmin** keeps behavior specifications and proposed changes separate from implementation progress, and helps check code/spec convergence before promotion.
- **ProjectAdmin** initializes and maintains project structure and the project-local knowledge Vault.
- **Weave** provides compact topic and concept navigation for agents while preserving the underlying sources.
- **Self Improvement** captures confirmed, reusable lessons for later review.
- **Git Workspace** supports optional local Git worktree development and task/workspace checks. Each worktree has separate files and branches within the same user environment.

Maxa's Obsidian integration provides another way to read and maintain project knowledge. It includes guarded Vault operations, links and properties, Bases and Canvas, feedback, and optional Syncthing setup. Knowledge belongs to each project, with explicit capture and review workflows.

The published repository also includes six Obsidian plugins: block feedback capture, semantic graph labels, document translation, a TODOseq card board, unresolved-link protection, and visual Syncthing conflict resolution.

### Work with media, webpages, and applications

With the relevant backends configured, Maxa can generate and edit images, analyze local images, synthesize speech, and generate video. The GenAI Ability also includes reference-image workflows, iterative edits, prompt design, and reusable visual templates.

For research, `web-fetch` handles search, downloads, readable extraction, and dynamic-page fetching. The Browser integration can operate Chromium/CDP pages and supported Tauri WebViews, inspect network and application state, and use Tauri IPC. Visual checks use an actual rendering browser or WebView; the lightweight backend focuses on JavaScript, DOM, and network extraction. Document-to-Markdown conversion is available through the configured MarkItDown MCP service.

Maxa's bundled WinGUI bridge runs Windows commands and launches GUI applications from WSL. Desktop screenshots, mouse/keyboard input, windows, clipboard, and virtual desktops are available through WinCtl when its Windows-side server is set up.

### Stay involved away from the keyboard

When the agent needs a decision, Maxa routes the question to Chat and, when configured, to the matching Telegram topic. The first valid reply wins. Telegram can also deliver completion notifications and accept further input while the exact Chat is open, listening, and idle.

Maxa accepts files or text through Telegram, while `/upload` opens a browser upload page. That page supports file uploads, URL imports, and browser-permitted camera, audio, and screen capture. Submitted files are inserted into Chat as project paths. Cross-device browser access requires hostname, TLS, and network configuration; the default is local-only.

SSH provides multi-device access to the same working environment.

## Make it your own

My preferred way to use Maxa is to **fork this repository and maintain your own version**.

A fork gives your personal requirements a place to grow. Keep your configuration and specific changes there, and use AI to help understand, modify, and validate them.

For agent capabilities, I prefer reviewed code that I can maintain in my own repository. AI can help inspect compatibility and security risks, with code review and validation guiding adoption and updates. The editor builds on normal Neovim plugin dependencies and integrations.

When bringing in upstream Maxa changes, review them against your local modifications. An agent can help reconcile conflicts and verify the resulting behavior with relevant checks.

## Getting started

### Current installation path

The included installer targets **WSL2 with Ubuntu 24.04**, using a normal user with sudo access, on **x86_64 or aarch64**. Maxa requires **Neovim 0.11+**.

**Back up your existing Neovim configuration before deploying this repository, and clone into a fresh directory to preserve your current setup.** The installer downloads dependencies, uses sudo to install system software, and configures Obsidian and Syncthing user services when systemd is available. Review [`install.sh`](install.sh) before running it.

1. Fork this repository on GitHub, then clone your fork into an available `~/.config/nvim` directory. Replace `<your-fork-url>` with your repository URL:

   ```bash
   git clone <your-fork-url> ~/.config/nvim
   ```

2. Install dependencies inside the target WSL environment:

   ```bash
   bash ~/.config/nvim/install.sh
   ```

   Downloads use direct connections by default. For an installation-only proxy, explicitly pass `--proxy http://<host>:<port>`; this flag selects the download proxy for the installer.

3. On a fresh checkout, create the startup configuration from the published example:

   ```bash
   cp ~/.config/nvim/lua/plugins/ai.example ~/.config/nvim/lua/plugins/ai.lua
   ```

   **For an existing installation, preserve your current `ai.lua` and adapt it as needed.** This is your local, Git-ignored startup configuration, maintained separately from dependency installation.

4. Configure your credentials in `~/.config/nvim/.env` and review [`lua/plugins/ai.example`](lua/plugins/ai.example) for providers, models, and presets. The installer preserves an existing `.env`, or initializes one from `.env.example`. The example uses DeepSeek and reads `DEEPSEEK_API_KEY`. Keep real credentials out of commits.

5. Start Neovim and let its editor plugins install. Open `:Maxa` for Chat, `:MaxaHistory` for saved conversations, and `:MaxaConfig` for project settings. Use `:checkhealth maxa` to inspect core editor dependencies.

After dependency installation, configure the integrations you want to use: initialize a project's `.maxa/` through ProjectAdmin, register its Vault and sync folders, select media providers, or set up Windows and Telegram services.

If you already use LazyVim, compare the runtime and startup example with your existing setup and integrate the parts you want to use.

### A few useful entry points

| Entry                          | Purpose                                                    |
| ------------------------------ | ---------------------------------------------------------- |
| `:Maxa`                        | Open a Chat                                                |
| `:Maxa Add`                    | Add visually selected code to Chat                         |
| `:MaxaHistory`                 | Browse saved conversations                                 |
| `:MaxaConfig`                  | Manage project abilities, defaults, and MCP connections    |
| `:MaxaTranslateBuffer`         | Translate a supported project document and reuse its cache |
| `/load`, `/pick_ability`       | Load or select capabilities                                |
| `/fork`, `/scratch`, `/rewind` | Branch or revisit a conversation                           |
| `/upload`, `/tg_upload`        | Attach files or text through configured input paths        |

## Included Abilities

These are the Skill packages in this published version. Each link opens its Chinese user guide, with natural-language examples for describing your goal.

| Area                      | Abilities                                                                                                                                                                                                                                                                     |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Agents and sessions       | [SubAgent](abilities/subagent/USER_GUIDE.md), [Agency NEXUS](abilities/agency-nexus/USER_GUIDE.md), [Session](abilities/session/USER_GUIDE.md)                                                                                                                                |
| Project workflows         | [ProjectAdmin](abilities/project-admin/USER_GUIDE.md), [TaskAdmin](abilities/task-admin/USER_GUIDE.md), [SpecAdmin](abilities/spec-admin/USER_GUIDE.md), [Git Workspace](abilities/git-workspace/USER_GUIDE.md), [Self Improvement](abilities/self-improvement/USER_GUIDE.md) |
| Building capabilities     | [Ability Creator](abilities/ability-creator/USER_GUIDE.md), [MCP Creator](abilities/mcp-creator/USER_GUIDE.md), [Prompt Engineering](abilities/prompt-engineering/USER_GUIDE.md), [Resource Scout](abilities/resource-scout/USER_GUIDE.md)                                    |
| Browsing and environments | [Browser](abilities/browser/USER_GUIDE.md), [Web Fetch](abilities/web-fetch/USER_GUIDE.md), [Neovim](abilities/neovim/USER_GUIDE.md), [WSL Windows](abilities/wsl-windows/USER_GUIDE.md), [WinCtl](abilities/winctl/USER_GUIDE.md)                                            |
| Generative media          | [GenAI](abilities/genai/USER_GUIDE.md)                                                                                                                                                                                                                                        |

You can also extend this collection with MCP-only capabilities.

## Published version and optional services

Maxa's published repository provides the reusable runtime and its integrations. Use the published startup example as a reference and maintain your own configuration in `ai.lua`.

Enable Telegram by configuring its bridge, bot, and authorized user. Choose suitable providers for media tools and prepare the dependencies for browser and document tools. WinCtl uses a separately prepared Windows server. Configure Obsidian/Syncthing project registration and cross-device upload access when you want those integrations.

**The agent executes with your user's operating-system permissions**, including access to files, commands, and applications. Ability loading authorizes capabilities within a Chat; tools and Lua run in the existing editor and user environment. Review third-party code and changes, protect credentials, and keep backups and version control for important work. Login, payment, and interactive CAPTCHA steps require your participation when encountered.

## License and acknowledgements

Maxa is distributed under [Apache-2.0](LICENSE). Incorporated third-party code retains its applicable upstream licensing; retained license texts include [CodeCompanion.nvim](LICENSES/codecompanion.nvim-Apache-2.0.txt) and [MCPHub.nvim](LICENSES/mcphub.nvim-MIT.txt).

Thanks to [LazyVim](https://github.com/LazyVim/LazyVim), [CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim), [MCPHub.nvim](https://github.com/ravitemer/mcphub.nvim), and the projects behind the integrated tools. Their work made Maxa possible.

---

**English** · [简体中文](README.zh-CN.md) · [Video](https://www.youtube.com/watch?v=jNQXAC9IVRw)

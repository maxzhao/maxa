# ClawHub Guide

Purpose: use ClawHub as an acquisition source for OpenClaw/AgentSkill candidates. ClawHub is an "npm for AI Agents" style registry with semantic search, versioning, CLI, and API access.

Links:

| Item | URL |
| --- | --- |
| Site | `https://clawhub.ai/` |
| Docs | `https://docs.openclaw.ai/tools/clawhub` |
| GitHub | `https://github.com/openclaw/clawhub` |

ClawHub website pages are SPA-rendered. Do not scrape pages for search results; use CLI or API.

## Install CLI

Use the environment's actual proxy when required; do not hardcode proxy values into shared docs.

```bash
export HTTP_PROXY=<proxy-url>
export HTTPS_PROXY=<proxy-url>
export ALL_PROXY=<proxy-url>

npm i -g clawhub
# or
pnpm add -g clawhub
```

## Auth

```bash
clawhub login                 # browser GitHub OAuth
clawhub login --token <token> # token auth
clawhub whoami
clawhub logout
```

Do not echo or store tokens in shared artifacts.

## Search

CLI semantic search:

```bash
clawhub search "calendar"
clawhub search "react performance" --limit 20
```

API search after loading `web-fetch`:

```text
GET https://clawhub.ai/api/search?q=<query>
```

Expected JSON shape includes fields such as `slug`, `displayName`, `summary`, `score`, and `updatedAt` when available.

## Acquire Skill

Before install/update/adaptation, load and follow `ability-creator`:

```text
load(target="ability-creator")
```

`clawhub install` only acquires files. Final target directory, frontmatter, resource layout, validation, and cleanup must follow `ability-creator` plus `references/setup/install-guide.md`.

```bash
clawhub install <slug>
clawhub install <slug> --version <version>
clawhub install <slug> --force
```

Default behavior: installs under `./abilities/` in the current working directory. Treat it as an acquisition staging area, not final placement.

Recommended acquisition flow:

```bash
# 1. Acquire to temporary/current workdir staging.
clawhub install <slug>

# 2. Copy to a separate normalization staging dir.
cp -a ./abilities/<slug> <staging-dir>/<slug>

# 3. Continue with Resource Scout install handoff + ability-creator normalization.
```

Before copying into any final target, check whether the target skill already exists and has local modifications.

## Update

```bash
clawhub update <slug>
clawhub update --all
clawhub update <slug> --version <version>
```

Update workflow:

1. Check current target directory for local changes.
2. Acquire the new version to staging.
3. Diff against the installed target.
4. Reapply local Maxa adaptation.
5. Run load test and `ability-creator` lint.

Do not let marketplace CLI overwrite the final target without local-change review.

## Other Commands

```bash
clawhub list
clawhub publish <path>
clawhub sync
clawhub delete <slug> --yes
clawhub undelete <slug> --yes
```

## Environment And Options

| Name | Purpose |
| --- | --- |
| `CLAWHUB_WORKDIR` | override default workdir |
| `CLAWHUB_DISABLE_TELEMETRY=1` | disable sync install-count telemetry |
| `CLAWHUB_SITE` | override site URL |
| `CLAWHUB_REGISTRY` | override registry API URL |
| `CLAWHUB_CONFIG_PATH` | override config/token path |
| `--workdir <dir>` | workdir, default current directory |
| `--dir <dir>` | skills dir, default `skills` |
| `--site <url>` | site URL |
| `--registry <url>` | registry API URL |
| `--no-input` | non-interactive mode |
| `-V, --cli-version` | CLI version |

## Handoff Checklist

After acquiring a candidate:

- Record slug, source URL/API result, version, and acquisition command.
- Move only through a staging dir; do not use `./abilities/` as final target.
- Load `ability-creator` before editing or installing.
- Normalize structure/frontmatter/resources/scripts.
- Remove acquisition residue after confirming no local changes.
- Test `load(target="<skill-name>", force_reload=true)`.
- Run the `ability-creator` linter.

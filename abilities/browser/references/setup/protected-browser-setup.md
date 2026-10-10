# Protected Browser One-Time Setup

Purpose: prepare a real-browser backend for `browser_start(mode="protected")`. Ordinary web-access tasks should use `read(path="#browser[/references/browser-backends.md]")`, not this setup guide.

Prerequisite: `load(target="browser")` before MCP calls. Shell blocks below are manual installation/platform administration or isolated setup diagnostics, not cataloged Ability scripts. The inline Python snippets use the loaded Ability's uv project; there is no shipped callable setup script to substitute with an `@` address. Executable/profile paths remain physical paths.

Protected mode targets Cloudflare/bot-check/non-interactive security checks by launching real Chromium with patched ChromeDriver and exposing a CDP endpoint for `browser` tools.

## Target Result

After setup, this should work:

```yaml
run:
  title: "Start protected browser backend"
  scope: tool
  command: "@browser:browser_start"
  args: '{"mode":"protected","warmupUrl":"https://example.com"}'
```

Expected:

```json
{
  "status": "ready",
  "mode": "protected",
  "connected": true,
  "smoke": { "ok": true }
}
```

## Components

1. Python environment with `undetected-chromedriver`.
2. Chrome/Chromium browser.
3. Patched ChromeDriver matching Chrome major version.
4. Xvfb when Linux/WSL has no graphical `DISPLAY`.
5. Browser proxy for external sites when needed; local CDP/ChromeDriver communication must not go through proxy.

Recommended paths, not hard contracts:

```text
~/.local/share/undetected_chromedriver/undetected_chromedriver
~/.cache/ms-playwright/chromium-*/chrome-linux*/chrome
```

If paths differ, include these target fields in the object encoded as `args` for titled `run(scope="tool", command="@browser:browser_start")` (parameter fragment, not a standalone call):

```yaml
pythonCommand: /path/to/python
chromeBinary: /path/to/chrome
chromedriverPath: /path/to/undetected_chromedriver
chromeVersionMain: 143
```

Resolve placeholders and home-directory shorthand to concrete machine paths before passing tool parameters; Ability addresses are not filesystem substitutions.

## Step 1: Python Environment

Default: this Ability owns the protected-browser Python runtime through its uv project. The MCP server uses it automatically when `pythonCommand` is omitted and the Ability `pyproject.toml` exists.

Resolve the physical root containing the protected-runtime `pyproject.toml` from the roots returned by `load(target="browser")`; do not assume a Neovim installation path. Substitute that directory for `<BROWSER_ROOT>` below and retain `BROWSER_ROOT` for the later manual snippets. To inspect the dependency declaration, use `read(path="#browser[/pyproject.toml]")`.

Manual inline import diagnostic (not an Ability script):

```bash
export BROWSER_ROOT='<BROWSER_ROOT>'
uv run --project "$BROWSER_ROOT" python - <<'PY'
import undetected_chromedriver as uc
import selenium
print('undetected_chromedriver', getattr(uc, '__version__', 'unknown'))
print('selenium', selenium.__version__)
PY
```

Optional manual external-runtime installation, only when needed (not execution of an Ability Python script):

```bash
python3 -m venv ~/.local/share/browser-protected/venv
~/.local/share/browser-protected/venv/bin/python -m pip install -U pip
~/.local/share/browser-protected/venv/bin/python -m pip install 'undetected-chromedriver>=3.5.5' 'selenium>=4.27.1' 'setuptools>=70'
```

Pass the override with `browser_start.pythonCommand`. A custom Python is acceptable only if it imports `undetected_chromedriver`.

## Step 2: Chrome/Chromium

Chrome/Chromium and ChromeDriver major versions must match.

Sources:

- Playwright Chrome for Testing / Chromium.
- System `google-chrome` / `chromium`.
- Manually downloaded Chrome for Testing.

Check version:

```bash
/path/to/chrome --version
```

Record major version, for example `143`, for `chromeVersionMain`.

## Step 3: Patched ChromeDriver

Example for Chrome 143 Linux x64:

```bash
mkdir -p ~/.local/share/undetected_chromedriver
cd ~/.local/share/undetected_chromedriver

export HTTPS_PROXY=http://127.0.0.1:10808
export HTTP_PROXY=http://127.0.0.1:10808

wget -O chromedriver.zip \
  'https://storage.googleapis.com/chrome-for-testing-public/143.0.7499.25/linux64/chromedriver-linux64.zip'
unzip -o chromedriver.zip
mv chromedriver-linux64/chromedriver undetected_chromedriver
chmod +x undetected_chromedriver
rm -rf chromedriver.zip chromedriver-linux64
```

Patch with the Ability-owned uv environment (manual inline setup operation):

```bash
uv run --project "$BROWSER_ROOT" python - <<'PY'
from undetected_chromedriver.patcher import Patcher
from pathlib import Path

chromedriver = Path('~/.local/share/undetected_chromedriver/undetected_chromedriver').expanduser()
p = Patcher(executable_path=str(chromedriver))
p.auto()
print('patched')
PY
```

Verify:

```bash
~/.local/share/undetected_chromedriver/undetected_chromedriver --version
```

For custom locations, use the same path in `browser_start.chromedriverPath`.

## Step 4: Xvfb

Protected mode defaults to non-headless browser. Linux/WSL without `DISPLAY` needs Xvfb.

Debian/Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y xvfb
```

Verify:

```bash
command -v Xvfb
```

Skip when the environment already has a valid graphical `DISPLAY`.

## Step 5: Preflight

Manual diagnostic, using the physical `BROWSER_ROOT` resolved in Step 1:

```bash
uv run --project "$BROWSER_ROOT" python - <<'PY'
import undetected_chromedriver
print('python ok')
PY

/path/to/chrome --version
~/.local/share/undetected_chromedriver/undetected_chromedriver --version
command -v Xvfb || true
```

Required invariant:

```text
Chrome major version == ChromeDriver supported major version == browser_start.chromeVersionMain
```

Mismatch example:

```text
This version of ChromeDriver only supports Chrome version 143
Current browser version is 145...
```

Fix by replacing Chrome or ChromeDriver with a matching major version.

## Step 6: MCP Verification

After `load(target="browser")` (resolve the example paths before calling):

```yaml
run:
  title: "Verify protected browser backend"
  scope: tool
  command: "@browser:browser_start"
  # pythonCommand omitted by default; MCP uses the Ability uv runtime.
  args: '{"mode":"protected","port":9334,"warmupUrl":"https://example.com","chromeBinary":"/path/to/chrome","chromedriverPath":"<resolved-home>/.local/share/undetected_chromedriver/undetected_chromedriver","chromeVersionMain":143}'
```

Expected:

```json
{
  "status": "ready",
  "mode": "protected",
  "connected": true,
  "smoke": { "ok": true }
}
```

Confirm page tools:

```yaml
run: {title: "Read protected page title", scope: tool, command: "@browser:title", args: '{}'}
```

```yaml
run:
  title: "Inspect protected page text"
  scope: tool
  command: "@browser:evaluate"
  args: '{"script":"document.body ? document.body.innerText.slice(0, 100) : ''''"}'
```

Cleanup:

```yaml
run: {title: "Stop protected browser backend", scope: tool, command: "@browser:browser_stop", args: '{}'}
```

## Proxy

Do not proxy local ChromeDriver/CDP traffic. Pass target-site proxy through `browser_start.proxy`:

```yaml
run:
  title: "Start protected backend with site proxy"
  scope: tool
  command: "@browser:browser_start"
  args: '{"mode":"protected","proxy":"socks5://127.0.0.1:10808"}'
```

Protected helper configures Chrome proxy and bypasses:

```text
localhost;127.0.0.1;[::1]
```

## Troubleshooting

| Symptom | Response |
| --- | --- |
| `undetected_chromedriver import failed` | Run the manual diagnostic `uv run --project "$BROWSER_ROOT" python -c 'import undetected_chromedriver'` using the root resolved in Step 1; if using an override, point `pythonCommand` to a venv with `undetected-chromedriver>=3.5.5`, `selenium>=4.27.1`, and `setuptools>=70`. |
| ChromeDriver/Chrome version mismatch | Pass matching `chromeBinary`, `chromeVersionMain`, and `chromedriverPath`, or replace the mismatched binary. |
| `DISPLAY is not set and Xvfb is not installed` | Install Xvfb or run in a graphical session. |
| CDP endpoint not responding | Check `logPath`, version match, port conflict, Python env, and Chrome launch policy. |
| Page still shows CAPTCHA | Protected mode has no CAPTCHA solver. Stop and report interactive Turnstile/hCaptcha/login/paywall/permission-wall limitations. |

## Local Configuration Template

Use actual machine paths; do not turn one developer machine into a shared default. Replace the illustrated numeric `143` with the installed Chrome major version and the other placeholders with physical executable paths before calling.

```yaml
run:
  title: "Start locally configured protected backend"
  scope: tool
  command: "@browser:browser_start"
  args: '{"mode":"protected","pythonCommand":"<PYTHON_EXECUTABLE>","chromeBinary":"<CHROME_EXECUTABLE>","chromedriverPath":"<PATCHED_CHROMEDRIVER>","chromeVersionMain":143}'
```

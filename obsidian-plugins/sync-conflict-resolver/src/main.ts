// @ts-nocheck
// Sync Conflict Resolver Plugin
// Three-way merge for Syncthing conflicts using .stversions as base.
// Auto-merges clean sections, provides per-conflict resolution UI.

import { Modal, Notice, Plugin, Setting } from "obsidian";

// ─── Diff & Merge Core ───

function diff(a, b) {
  const n = a.length;
  const m = b.length;
  const dp = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      if (a[i] === b[j]) dp[i][j] = dp[i + 1][j + 1] + 1;
      else dp[i][j] = Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }
  const result = [];
  let i = 0, j = 0;
  while (i < n || j < m) {
    if (i < n && j < m && a[i] === b[j]) {
      const lines = [];
      while (i < n && j < m && a[i] === b[j]) { lines.push(a[i]); i++; j++; }
      result.push({ type: "equal", lines });
    } else if (j < m && (i >= n || dp[i][j + 1] >= dp[i + 1][j])) {
      const lines = [];
      while (j < m && !(i < n && a[i] === b[j]) && (i >= n || dp[i][j + 1] >= dp[i + 1][j])) { lines.push(b[j]); j++; }
      result.push({ type: "add", lines });
    } else if (i < n) {
      const lines = [];
      while (i < n && !(j < m && a[i] === b[j]) && (j >= m || dp[i + 1][j] > dp[i][j + 1])) { lines.push(a[i]); i++; }
      result.push({ type: "remove", lines });
    }
  }
  return result;
}

/**
 * Three-way merge returning structured sections instead of text with markers.
 * Each section: { type: 'auto', lines: [] } or { type: 'conflict', ours: [], theirs: [], base: [] }
 */
function merge3Structured(base, ours, theirs) {
  const baseLines = base.split("\n");
  const oursLines = ours.split("\n");
  const theirsLines = theirs.split("\n");

  const diffO = diff(baseLines, oursLines);
  const diffT = diff(baseLines, theirsLines);

  // Build per-base-line edit records
  function buildEdits(d) {
    const edits = []; // { action: 'keep'|'delete'|'replace', line?, newLines?, prepend? }
    for (const chunk of d) {
      if (chunk.type === "equal") {
        for (const line of chunk.lines) edits.push({ action: "keep", line });
      } else if (chunk.type === "remove") {
        for (const line of chunk.lines) edits.push({ action: "delete", line });
      } else if (chunk.type === "add") {
        // Attach to previous edit as appended lines
        if (edits.length > 0) {
          const last = edits[edits.length - 1];
          if (!last.append) last.append = [];
          last.append.push(...chunk.lines);
        } else {
          edits.push({ action: "keep-virtual", prepend: chunk.lines });
        }
      }
    }
    return edits;
  }

  const oEdits = buildEdits(diffO);
  const tEdits = buildEdits(diffT);

  const sections = [];
  let autoLines = [];

  function flushAuto() {
    if (autoLines.length > 0) {
      sections.push({ type: "auto", lines: [...autoLines] });
      autoLines = [];
    }
  }

  const maxLen = Math.max(oEdits.length, tEdits.length);
  for (let i = 0; i < maxLen; i++) {
    const o = oEdits[i] || { action: "keep", line: "" };
    const t = tEdits[i] || { action: "keep", line: "" };

    // Prepend handling
    const oPre = o.prepend || [];
    const tPre = t.prepend || [];
    if (oPre.length > 0 || tPre.length > 0) {
      if (oPre.join("\n") === tPre.join("\n")) {
        autoLines.push(...oPre);
      } else if (oPre.length > 0 && tPre.length === 0) {
        autoLines.push(...oPre);
      } else if (tPre.length > 0 && oPre.length === 0) {
        autoLines.push(...tPre);
      } else {
        flushAuto();
        sections.push({ type: "conflict", ours: oPre, theirs: tPre });
      }
    }

    // Main line
    const oKeep = o.action === "keep" || o.action === "keep-virtual";
    const tKeep = t.action === "keep" || t.action === "keep-virtual";
    const oDel = o.action === "delete";
    const tDel = t.action === "delete";

    if (oKeep && tKeep) {
      autoLines.push(o.line);
    } else if (oKeep && tDel) {
      // theirs deleted — auto accept
    } else if (oDel && tKeep) {
      // ours deleted — auto accept
    } else if (oDel && tDel) {
      // both deleted — agree
    } else {
      // conflict
      flushAuto();
      sections.push({
        type: "conflict",
        ours: o.line != null ? [o.line] : [],
        theirs: t.line != null ? [t.line] : [],
      });
    }

    // Append handling
    const oApp = o.append || [];
    const tApp = t.append || [];
    if (oApp.length > 0 || tApp.length > 0) {
      if (oApp.join("\n") === tApp.join("\n")) {
        autoLines.push(...oApp);
      } else if (oApp.length > 0 && tApp.length === 0) {
        autoLines.push(...oApp);
      } else if (tApp.length > 0 && oApp.length === 0) {
        autoLines.push(...tApp);
      } else {
        flushAuto();
        sections.push({ type: "conflict", ours: oApp, theirs: tApp });
      }
    }
  }

  flushAuto();
  return sections;
}

/**
 * Two-way structured diff (no base).
 */
function merge2Structured(ours, theirs) {
  const d = diff(ours.split("\n"), theirs.split("\n"));
  const sections = [];
  let autoLines = [];

  function flushAuto() {
    if (autoLines.length > 0) {
      sections.push({ type: "auto", lines: [...autoLines] });
      autoLines = [];
    }
  }

  let i = 0;
  while (i < d.length) {
    const chunk = d[i];
    if (chunk.type === "equal") {
      autoLines.push(...chunk.lines);
      i++;
    } else {
      // Collect consecutive remove+add as a single conflict
      const oursL = [];
      const theirsL = [];
      while (i < d.length && d[i].type !== "equal") {
        if (d[i].type === "remove") oursL.push(...d[i].lines);
        if (d[i].type === "add") theirsL.push(...d[i].lines);
        i++;
      }
      flushAuto();
      sections.push({ type: "conflict", ours: oursL, theirs: theirsL });
    }
  }
  flushAuto();
  return sections;
}

// ─── Conflict File Helpers ───

const CONFLICT_REGEX = /^(.+)\.sync-conflict-(\d{8}-\d{6})-([A-Z0-9]{7})(\..+)$/;
const EXTRA_CONFLICT_SCAN_DIRS = [".obsidian"];

function shouldIncludeConflictPath(filePath) {
  if (!CONFLICT_REGEX.test(filePath)) return false;
  if (filePath.startsWith(".obsidian/")) return true;
  return !filePath.split("/").slice(0, -1).some((segment) => segment.startsWith("."));
}

function parseConflictInfo(filePath) {
  const parts = filePath.match(CONFLICT_REGEX);
  if (parts) {
    return {
      isConflict: true,
      originalPath: parts[1] + parts[4],
      conflictPath: filePath,
      timestamp: parts[2],
      deviceId: parts[3],
    };
  }
  return { isConflict: false };
}

// ─── Merge Modal ───

class MergeModal extends Modal {
  constructor(app, sections, originalPath, conflictPath, basePath, onAccept) {
    super(app);
    this.sections = sections;
    this.originalPath = originalPath;
    this.conflictPath = conflictPath;
    this.basePath = basePath;
    this.onAccept = onAccept;
    // Track resolution for each conflict section
    this.resolutions = {};
    this.conflictCount = sections.filter((s) => s.type === "conflict").length;
  }

  onOpen() {
    const { contentEl } = this;
    this.modalEl.style.width = "90vw";
    this.modalEl.style.maxWidth = "900px";
    this.modalEl.style.maxHeight = "85vh";
    this.modalEl.style.display = "flex";
    this.modalEl.style.flexDirection = "column";

    // Header
    contentEl.createEl("h3", { text: "Sync Conflict Merge" });

    // Info bar
    const info = contentEl.createDiv();
    info.style.cssText = "margin-bottom:8px;font-size:0.82em;color:var(--text-muted)";
    info.createEl("div", { text: `Ours (local conflict copy): ${this.conflictPath}` });
    info.createEl("div", { text: `Theirs (current original path): ${this.originalPath}` });
    info.createEl("div", { text: `Base: ${this.basePath || "(none — two-way diff)"}` });

    // Status bar
    this.statusEl = contentEl.createDiv();
    this.statusEl.style.cssText = "padding:6px 12px;margin-bottom:8px;border-radius:4px;font-size:0.9em";
    this.updateStatus();

    // Scrollable sections area
    const scrollArea = contentEl.createDiv();
    scrollArea.style.cssText = "overflow-y:auto;flex:1;min-height:0;max-height:55vh;border:1px solid var(--background-modifier-border);border-radius:4px;padding:4px";

    let conflictIdx = 0;
    for (const section of this.sections) {
      if (section.type === "auto") {
        this.renderAutoSection(scrollArea, section);
      } else {
        this.renderConflictSection(scrollArea, section, conflictIdx);
        conflictIdx++;
      }
    }

    // Bottom buttons
    const btnRow = contentEl.createDiv();
    btnRow.style.cssText = "margin-top:10px;display:flex;gap:8px;justify-content:flex-end";

    if (this.conflictCount > 0) {
      // Batch actions
      const batchDiv = contentEl.createDiv();
      batchDiv.style.cssText = "margin-top:6px;display:flex;gap:8px";

      const allOurs = batchDiv.createEl("button", { text: "All → Ours" });
      allOurs.style.cssText = "font-size:0.82em;padding:2px 8px";
      allOurs.addEventListener("click", () => this.resolveAll("ours"));

      const allTheirs = batchDiv.createEl("button", { text: "All → Theirs" });
      allTheirs.style.cssText = "font-size:0.82em;padding:2px 8px";
      allTheirs.addEventListener("click", () => this.resolveAll("theirs"));
    }

    new Setting(btnRow)
      .addButton((btn) =>
        btn.setButtonText("Accept merge").setCta().onClick(() => {
          const unresolved = this.conflictCount - Object.keys(this.resolutions).length;
          if (unresolved > 0) {
            new Notice(`Still ${unresolved} unresolved conflict(s).`);
            return;
          }
          this.close();
          this.onAccept(this.buildFinalText());
        })
      )
      .addButton((btn) =>
        btn.setButtonText("Cancel").onClick(() => this.close())
      );
  }

  renderAutoSection(container, section) {
    const el = container.createDiv();
    el.style.cssText = "padding:2px 8px;font-family:var(--font-monospace);font-size:0.82em;white-space:pre-wrap;color:var(--text-muted)";

    // Show collapsed if more than 6 lines
    const lines = section.lines;
    if (lines.length <= 6) {
      el.setText(lines.join("\n"));
    } else {
      const preview = [...lines.slice(0, 3), `  ··· ${lines.length - 6} lines ···`, ...lines.slice(-3)];
      el.setText(preview.join("\n"));
      el.style.cursor = "pointer";
      let expanded = false;
      el.addEventListener("click", () => {
        expanded = !expanded;
        el.setText(expanded ? lines.join("\n") : preview.join("\n"));
      });
    }
  }

  renderConflictSection(container, section, idx) {
    const wrapper = container.createDiv();
    wrapper.style.cssText = "margin:6px 0;border:2px solid var(--text-error);border-radius:6px;overflow:hidden";
    wrapper.dataset.conflictIdx = idx;

    // Header with conflict number
    const header = wrapper.createDiv();
    header.style.cssText = "padding:4px 10px;background:var(--background-modifier-error);color:var(--text-on-accent);font-size:0.82em;font-weight:bold;display:flex;justify-content:space-between;align-items:center";
    header.createEl("span", { text: `Conflict #${idx + 1}` });

    // Action buttons in header
    const actions = header.createDiv();
    actions.style.cssText = "display:flex;gap:4px";

    const btnOurs = actions.createEl("button", { text: "Ours" });
    btnOurs.style.cssText = "font-size:0.78em;padding:1px 8px;border-radius:3px;cursor:pointer;background:var(--interactive-accent);color:var(--text-on-accent);border:none";

    const btnTheirs = actions.createEl("button", { text: "Theirs" });
    btnTheirs.style.cssText = "font-size:0.78em;padding:1px 8px;border-radius:3px;cursor:pointer;background:var(--interactive-accent);color:var(--text-on-accent);border:none";

    const btnEdit = actions.createEl("button", { text: "Edit" });
    btnEdit.style.cssText = "font-size:0.78em;padding:1px 8px;border-radius:3px;cursor:pointer;background:var(--interactive-accent);color:var(--text-on-accent);border:none";

    // Content area: ours | theirs side by side
    const body = wrapper.createDiv();
    body.style.cssText = "display:flex;font-family:var(--font-monospace);font-size:0.82em";

    const oursDiv = body.createDiv();
    oursDiv.style.cssText = "flex:1;padding:6px 8px;background:rgba(0,200,0,0.08);white-space:pre-wrap;word-break:break-word;border-right:1px solid var(--background-modifier-border)";
    oursDiv.createEl("div", { text: "OURS", attr: { style: "font-weight:bold;font-size:0.75em;color:var(--text-muted);margin-bottom:2px" } });
    oursDiv.createEl("div", { text: section.ours.join("\n") || "(empty)" });

    const theirsDiv = body.createDiv();
    theirsDiv.style.cssText = "flex:1;padding:6px 8px;background:rgba(200,0,0,0.08);white-space:pre-wrap;word-break:break-word";
    theirsDiv.createEl("div", { text: "THEIRS", attr: { style: "font-weight:bold;font-size:0.75em;color:var(--text-muted);margin-bottom:2px" } });
    theirsDiv.createEl("div", { text: section.theirs.join("\n") || "(empty)" });

    // Resolution indicator
    const resolvedBar = wrapper.createDiv();
    resolvedBar.style.cssText = "display:none;padding:4px 10px;background:var(--background-modifier-success);font-size:0.82em";
    resolvedBar.dataset.resolvedBar = idx;

    // Edit area (hidden by default)
    const editArea = wrapper.createDiv();
    editArea.style.cssText = "display:none;padding:6px";
    const textarea = editArea.createEl("textarea");
    textarea.style.cssText = "width:100%;min-height:80px;font-family:var(--font-monospace);font-size:0.82em;padding:4px;border:1px solid var(--background-modifier-border);border-radius:3px;background:var(--background-primary);color:var(--text-normal);resize:vertical";

    const editConfirm = editArea.createEl("button", { text: "Apply edit" });
    editConfirm.style.cssText = "margin-top:4px;font-size:0.82em;padding:2px 10px;cursor:pointer";

    // Button handlers
    const self = this;

    function markResolved(choice, text) {
      self.resolutions[idx] = text;
      body.style.display = "none";
      editArea.style.display = "none";
      resolvedBar.style.display = "block";
      resolvedBar.empty();
      resolvedBar.createEl("span", { text: `✅ Resolved: ${choice}` });

      // Undo button
      const undo = resolvedBar.createEl("button", { text: "Undo" });
      undo.style.cssText = "margin-left:8px;font-size:0.78em;padding:1px 6px;cursor:pointer";
      undo.addEventListener("click", () => {
        delete self.resolutions[idx];
        body.style.display = "flex";
        resolvedBar.style.display = "none";
        wrapper.style.borderColor = "var(--text-error)";
        self.updateStatus();
      });

      wrapper.style.borderColor = "var(--background-modifier-success)";
      self.updateStatus();
    }

    btnOurs.addEventListener("click", () => markResolved("Ours", section.ours.join("\n")));
    btnTheirs.addEventListener("click", () => markResolved("Theirs", section.theirs.join("\n")));

    btnEdit.addEventListener("click", () => {
      editArea.style.display = "block";
      // Pre-fill with ours content
      textarea.value = section.ours.join("\n");
      textarea.focus();
    });

    editConfirm.addEventListener("click", () => markResolved("Manual edit", textarea.value));
  }

  resolveAll(choice) {
    let idx = 0;
    for (const section of this.sections) {
      if (section.type === "conflict") {
        if (!(idx in this.resolutions)) {
          const text = choice === "ours" ? section.ours.join("\n") : section.theirs.join("\n");
          this.resolutions[idx] = text;

          // Update UI
          const wrapper = this.contentEl.querySelector(`[data-conflict-idx="${idx}"]`);
          if (wrapper) {
            const body = wrapper.querySelector("div:nth-child(2)");
            const resolvedBar = wrapper.querySelector(`[data-resolved-bar="${idx}"]`);
            if (body) body.style.display = "none";
            if (resolvedBar) {
              resolvedBar.style.display = "block";
              resolvedBar.empty();
              resolvedBar.createEl("span", { text: `✅ Resolved: ${choice === "ours" ? "Ours" : "Theirs"}` });
              const undo = resolvedBar.createEl("button", { text: "Undo" });
              undo.style.cssText = "margin-left:8px;font-size:0.78em;padding:1px 6px;cursor:pointer";
              const capturedIdx = idx;
              undo.addEventListener("click", () => {
                delete this.resolutions[capturedIdx];
                if (body) body.style.display = "flex";
                if (resolvedBar) resolvedBar.style.display = "none";
                wrapper.style.borderColor = "var(--text-error)";
                this.updateStatus();
              });
            }
            wrapper.style.borderColor = "var(--background-modifier-success)";
          }
        }
        idx++;
      }
    }
    this.updateStatus();
  }

  updateStatus() {
    const resolved = Object.keys(this.resolutions).length;
    if (this.conflictCount === 0) {
      this.statusEl.style.background = "var(--background-modifier-success)";
      this.statusEl.setText("✅ Clean merge — no conflicts.");
    } else if (resolved === this.conflictCount) {
      this.statusEl.style.background = "var(--background-modifier-success)";
      this.statusEl.setText(`✅ All ${this.conflictCount} conflict(s) resolved.`);
    } else {
      this.statusEl.style.background = "var(--background-modifier-error)";
      this.statusEl.style.color = "var(--text-on-accent)";
      this.statusEl.setText(`⚠ ${this.conflictCount - resolved} of ${this.conflictCount} conflict(s) unresolved.`);
    }
  }

  buildFinalText() {
    const lines = [];
    let conflictIdx = 0;
    for (const section of this.sections) {
      if (section.type === "auto") {
        lines.push(...section.lines);
      } else {
        const resolved = this.resolutions[conflictIdx];
        if (resolved !== undefined) {
          if (resolved.length > 0) lines.push(resolved);
          // empty string = accepted deletion
        }
        conflictIdx++;
      }
    }
    return lines.join("\n");
  }

  onClose() {
    this.contentEl.empty();
  }
}

// ─── Conflict List Modal ───

class ConflictListModal extends Modal {
  constructor(app, conflicts, onSelect) {
    super(app);
    this.conflicts = conflicts;
    this.onSelect = onSelect;
  }

  onOpen() {
    const { contentEl } = this;
    contentEl.createEl("h3", { text: `Sync Conflicts (${this.conflicts.length})` });

    for (const file of this.conflicts) {
      const info = parseConflictInfo(file.path);
      const row = contentEl.createDiv();
      row.style.cssText = "padding:8px 0;border-bottom:1px solid var(--background-modifier-border);cursor:pointer";
      row.addEventListener("mouseenter", () => (row.style.background = "var(--background-modifier-hover)"));
      row.addEventListener("mouseleave", () => (row.style.background = ""));

      row.createEl("div", { text: info.originalPath || file.path, attr: { style: "font-weight:bold" } });
      row.createEl("div", {
        text: `Device: ${info.deviceId || "?"} | Time: ${info.timestamp || "?"}`,
        attr: { style: "font-size:0.8em;color:var(--text-muted)" },
      });

      row.addEventListener("click", () => {
        this.close();
        this.onSelect(file);
      });
    }
  }

  onClose() {
    this.contentEl.empty();
  }
}

// ─── Plugin ───

class SyncConflictResolverPlugin extends Plugin {
  async onload() {
    this.bannerEl = null;
    this.ignoredConflicts = new Set(); // tracks dismissed conflicts for this session

    this.addCommand({
      id: "resolve-sync-conflict",
      name: "Resolve sync conflict",
      checkCallback: (checking) => {
        const file = this.app.workspace.getActiveFile();
        if (!file) return false;

        const info = parseConflictInfo(file.path);
        if (info.isConflict) {
          if (!checking) this.resolveConflict(info.originalPath, info.conflictPath);
          return true;
        }

        const conflicts = this.findConflictFiles(file.path);
        if (conflicts.length > 0) {
          if (!checking) this.resolveConflict(file.path, conflicts[0].path);
          return true;
        }
        return false;
      },
    });

    this.addCommand({
      id: "list-sync-conflicts",
      name: "List all sync conflicts",
      callback: () => this.listAllConflicts(),
    });

    // Monitor file open events for conflict detection
    this.registerEvent(
      this.app.workspace.on("file-open", (file) => {
        this.removeBanner();
        if (!file) return;
        this.checkAndShowBanner(file);
      })
    );

    // Also monitor vault changes (new conflict files synced in)
    this.registerEvent(
      this.app.vault.on("create", (f) => {
        if (CONFLICT_REGEX.test(f.path)) {
          const active = this.app.workspace.getActiveFile();
          if (active) this.checkAndShowBanner(active);
        }
      })
    );
  }

  /**
   * Check if the current file has a conflict and show a banner if so.
   */
  checkAndShowBanner(file) {
    let originalPath, conflictPath;

    const info = parseConflictInfo(file.path);
    if (info.isConflict) {
      originalPath = info.originalPath;
      conflictPath = info.conflictPath;
    } else {
      const conflicts = this.findConflictFiles(file.path);
      if (conflicts.length === 0) return;
      originalPath = file.path;
      conflictPath = conflicts[0].path;
    }

    // Skip if user already dismissed this pair in this session
    const key = originalPath + "|" + conflictPath;
    if (this.ignoredConflicts.has(key)) return;

    this.showBanner(originalPath, conflictPath, key);
  }

  /**
   * Show a persistent banner above the editor content.
   */
  showBanner(originalPath, conflictPath, ignoreKey) {
    this.removeBanner();

    const leaf = this.app.workspace.activeLeaf;
    if (!leaf || !leaf.view || !leaf.view.containerEl) return;

    const container = leaf.view.containerEl;

    const banner = document.createElement("div");
    banner.className = "sync-conflict-banner";
    banner.style.cssText = [
      "display:flex",
      "align-items:center",
      "justify-content:space-between",
      "padding:8px 14px",
      "background:var(--background-modifier-error)",
      "color:var(--text-on-accent)",
      "font-size:0.88em",
      "gap:10px",
      "flex-shrink:0",
    ].join(";");

    // Left: message
    const msg = document.createElement("span");
    msg.textContent = `⚠ Sync conflict detected — this file has a conflicting version from another device.`;
    msg.style.cssText = "flex:1;min-width:0";
    banner.appendChild(msg);

    // Right: buttons
    const btnGroup = document.createElement("div");
    btnGroup.style.cssText = "display:flex;gap:6px;flex-shrink:0";

    const mergeBtn = document.createElement("button");
    mergeBtn.textContent = "Merge";
    mergeBtn.style.cssText = "padding:3px 12px;border-radius:4px;cursor:pointer;font-weight:bold;background:var(--interactive-accent);color:var(--text-on-accent);border:none;font-size:0.88em";
    mergeBtn.addEventListener("click", () => {
      this.removeBanner();
      this.resolveConflict(originalPath, conflictPath);
    });

    const ignoreBtn = document.createElement("button");
    ignoreBtn.textContent = "Dismiss";
    ignoreBtn.style.cssText = "padding:3px 12px;border-radius:4px;cursor:pointer;background:transparent;color:var(--text-on-accent);border:1px solid var(--text-on-accent);font-size:0.88em";
    ignoreBtn.addEventListener("click", () => {
      this.ignoredConflicts.add(ignoreKey);
      this.removeBanner();
    });

    btnGroup.appendChild(mergeBtn);
    btnGroup.appendChild(ignoreBtn);
    banner.appendChild(btnGroup);

    // Insert banner as the first child of the view container
    container.insertBefore(banner, container.firstChild);
    this.bannerEl = banner;
  }

  removeBanner() {
    if (this.bannerEl && this.bannerEl.parentNode) {
      this.bannerEl.parentNode.removeChild(this.bannerEl);
    }
    this.bannerEl = null;
  }

  onunload() {
    this.removeBanner();
  }

  async listExtraConflictFiles() {
    const adapter = this.app.vault.adapter;
    const paths = new Set();

    async function scanDir(dir) {
      let listing;
      try {
        listing = await adapter.list(dir);
      } catch (e) {
        return;
      }

      for (const file of listing.files || []) {
        if (shouldIncludeConflictPath(file)) paths.add(file);
      }

      for (const folder of listing.folders || []) {
        await scanDir(folder);
      }
    }

    for (const dir of EXTRA_CONFLICT_SCAN_DIRS) {
      await scanDir(dir);
    }

    return Array.from(paths).map((path) => ({ path }));
  }

  findConflictFiles(originalPath) {
    return this.app.vault.getFiles().filter((f) => {
      const m = f.path.match(CONFLICT_REGEX);
      return shouldIncludeConflictPath(f.path) && m && m[1] + m[4] === originalPath;
    });
  }

  async findBase(originalPath) {
    const adapter = this.app.vault.adapter;
    const dir = originalPath.substring(0, originalPath.lastIndexOf("/") + 1);
    const fullName = originalPath.substring(originalPath.lastIndexOf("/") + 1);
    const dotIdx = fullName.lastIndexOf(".");
    const name = dotIdx >= 0 ? fullName.substring(0, dotIdx) : fullName;
    const ext = dotIdx >= 0 ? fullName.substring(dotIdx) : "";

    const stDir = ".stversions/" + dir;
    const prefix = "~" + name + "~";

    try {
      const listing = await adapter.list(stDir);
      if (!listing || !listing.files) return null;

      const matches = listing.files
        .map((f) => {
          const fname = f.substring(f.lastIndexOf("/") + 1);
          if (fname.startsWith(prefix) && fname.endsWith(ext)) {
            const ts = fname.substring(prefix.length, fname.length - ext.length);
            return { path: f, timestamp: ts };
          }
          return null;
        })
        .filter(Boolean)
        .sort((a, b) => b.timestamp.localeCompare(a.timestamp));

      return matches.length > 0 ? matches[0].path : null;
    } catch (e) {
      return null;
    }
  }

  async resolveConflict(originalPath, conflictPath) {
    const adapter = this.app.vault.adapter;

    // Syncthing keeps the synced/incoming version at the original path and
    // moves the local conflicting copy to the `.sync-conflict-*` path.
    // Therefore, from the user's merge perspective:
    // - ours   = local conflict copy
    // - theirs = current original-path version
    let oursContent, theirsContent;
    try { oursContent = await adapter.read(conflictPath); }
    catch (e) { new Notice(`Cannot read: ${conflictPath}`); return; }
    try { theirsContent = await adapter.read(originalPath); }
    catch (e) { new Notice(`Cannot read: ${originalPath}`); return; }

    const basePath = await this.findBase(originalPath);
    let sections;

    if (basePath) {
      try {
        const baseContent = await adapter.read(basePath);
        sections = merge3Structured(baseContent, oursContent, theirsContent);
      } catch (e) {
        sections = merge2Structured(oursContent, theirsContent);
      }
    } else {
      sections = merge2Structured(oursContent, theirsContent);
    }

    new MergeModal(
      this.app,
      sections,
      originalPath,
      conflictPath,
      basePath,
      async (finalText) => {
        try {
          await adapter.write(originalPath, finalText);
          const conflictFile = this.app.vault.getAbstractFileByPath(conflictPath);
          if (conflictFile) {
            await this.app.vault.delete(conflictFile);
          } else {
            await adapter.remove(conflictPath);
          }
          new Notice(`✅ Merged → ${originalPath}\n🗑 Deleted ${conflictPath}`);
        } catch (e) {
          new Notice(`❌ Error: ${e.message}`);
        }
      }
    ).open();
  }

  async listAllConflicts() {
    const byPath = new Map();

    for (const file of this.app.vault.getFiles()) {
      if (shouldIncludeConflictPath(file.path)) byPath.set(file.path, file);
    }

    for (const file of await this.listExtraConflictFiles()) {
      if (shouldIncludeConflictPath(file.path)) byPath.set(file.path, file);
    }

    const conflicts = Array.from(byPath.values()).sort((a, b) => a.path.localeCompare(b.path));
    if (conflicts.length === 0) {
      new Notice("No sync conflicts found.");
      return;
    }
    new ConflictListModal(this.app, conflicts, (f) => {
      const info = parseConflictInfo(f.path);
      if (info.isConflict) this.resolveConflict(info.originalPath, info.conflictPath);
    }).open();
  }

}

export default SyncConflictResolverPlugin;

// @ts-nocheck
import { ItemView, MarkdownView, Modal, Notice, Platform, Plugin, TFile, resolveSubpath } from "obsidian";

const BLOCK_SELECTOR = "p, h1, h2, h3, h4, h5, h6, li, blockquote, pre, table, hr, .callout, .math, .contains-task-list";
const FEEDBACK_DIR = "inbox/feedback/pending";
const LOCAL_STATE_PATH = "inbox/feedback/.grab-note-local.json";
const VIEW_TYPE_GRAB_NOTE = "grab-note-feedback-view";

class FeedbackModal extends Modal {
  constructor(app, plugin, options) {
    super(app);
    this.plugin = plugin;
    this.file = options.file;
    this.info = options.info;
    this.context = options.context || null;
    this.initialComment = options.initialComment || "";
    this.mode = options.mode || "add";
    this.onSubmit = options.onSubmit;
    this.metaEl = null;
    this.quotePre = null;
    this.rangeButtons = [];
  }

  onOpen() {
    const { contentEl } = this;
    contentEl.addClass("grab-note-modal");
    contentEl.createEl("h3", { text: this.mode === "edit" ? "✏️ Edit Grab Note" : "📌 Grab Note" });

    this.metaEl = contentEl.createDiv({ cls: "grab-note-meta" });

    const controls = contentEl.createDiv({ cls: "grab-note-range-controls" });
    controls.createEl("span", { text: "Selection range", cls: "grab-note-range-label" });
    this.addRangeButton(controls, "Expand to parent", () => this.adjustRange("expand-parent"));
    this.addRangeButton(controls, "Shrink inward", () => this.adjustRange("shrink-inward"));

    const quote = contentEl.createEl("blockquote", { cls: "grab-note-quote" });
    this.quotePre = quote.createEl("pre");

    const textarea = contentEl.createEl("textarea", {
      cls: "grab-note-input",
      attr: { placeholder: "What would you like to change?", rows: "5" },
    });
    textarea.value = this.initialComment;
    setTimeout(() => textarea.focus(), 50);
    textarea.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
        e.preventDefault();
        this.submit(textarea.value);
      }
    });

    const hint = contentEl.createDiv({
      cls: "grab-note-hint",
      text: "Saved locally first. Use the Grab Note side panel to review and submit all feedback as one file.",
    });
    hint.toggleClass("is-edit", this.mode === "edit");

    const buttons = contentEl.createDiv({ cls: "grab-note-buttons" });
    const submitBtn = buttons.createEl("button", {
      text: this.mode === "edit" ? "Update local note" : "Save locally",
      cls: "mod-cta",
    });
    submitBtn.addEventListener("click", () => this.submit(textarea.value));
    const cancelBtn = buttons.createEl("button", { text: "Cancel" });
    cancelBtn.addEventListener("click", () => this.close());

    this.renderSelection();
  }

  addRangeButton(parent, text, onClick) {
    const btn = parent.createEl("button", { text, cls: "grab-note-range-button" });
    btn.addEventListener("click", onClick);
    this.rangeButtons.push(btn);
  }

  async adjustRange(action) {
    if (!this.context || !this.context.domPath) return;
    const max = this.context.domPath.length - 1;
    if (action === "expand-parent" && this.context.domIndex < max) {
      this.context.domIndex += 1;
    } else if (action === "shrink-inward" && this.context.domIndex > 0) {
      this.context.domIndex -= 1;
    }
    const item = this.context.domPath[this.context.domIndex];
    this.info = item.info;
    this.renderSelection();
  }

  renderSelection() {
    if (this.metaEl) {
      this.metaEl.empty();
      this.metaEl.createEl("div", { text: `📄 ${this.info.file}`, cls: "grab-note-file" });
      this.metaEl.createEl("div", { text: `📍 Lines ${this.info.startLine}–${this.info.endLine}`, cls: "grab-note-lines" });
      if (this.context && this.context.domPath) {
        const total = this.context.domPath.length;
        const current = this.context.domIndex + 1;
        const item = this.context.domPath[this.context.domIndex];
        this.metaEl.createEl("div", {
          text: `↕ Range level ${current}/${total}${item && item.label ? ` · ${item.label}` : ""}`,
          cls: "grab-note-range-meta",
        });
      }
    }
    if (this.quotePre) {
      this.quotePre.textContent = this.info.markdown;
    }
    this.updateRangeButtons();
  }

  updateRangeButtons() {
    if (!this.context) {
      for (const btn of this.rangeButtons) btn.disabled = true;
      return;
    }
    if (!this.context.domPath) {
      for (const btn of this.rangeButtons) btn.disabled = true;
      return;
    }
    const max = this.context.domPath.length - 1;
    const [expandParent, shrinkInward] = this.rangeButtons;
    if (expandParent) expandParent.disabled = this.context.domIndex >= max;
    if (shrinkInward) shrinkInward.disabled = this.context.domIndex <= 0;
  }

  submit(value) {
    const comment = value.trim();
    if (!comment) {
      new Notice("Please enter your feedback");
      return;
    }
    Promise.resolve(this.onSubmit(this.info, comment))
      .then(() => this.close())
      .catch((err) => {
        console.error(err);
        new Notice(`Failed to save feedback: ${err.message || err}`);
      });
  }

  onClose() {
    this.contentEl.empty();
  }
}

class GrabNoteView extends ItemView {
  constructor(leaf, plugin) {
    super(leaf);
    this.plugin = plugin;
  }

  getViewType() {
    return VIEW_TYPE_GRAB_NOTE;
  }

  getDisplayText() {
    return "Grab Note Feedback";
  }

  getIcon() {
    return "message-square";
  }

  async onOpen() {
    this.refresh();
  }

  refresh() {
    const containerEl = this.containerEl.children[1] || this.containerEl;
    containerEl.empty();
    const root = containerEl.createDiv({ cls: "grab-note-sidebar" });

    const header = root.createDiv({ cls: "grab-note-sidebar-header" });
    header.createEl("h3", { text: "Grab Note Feedback" });
    header.createEl("div", {
      cls: "grab-note-sidebar-count",
      text: `${this.plugin.entries.length} local ${this.plugin.entries.length === 1 ? "note" : "notes"}`,
    });

    const actions = root.createDiv({ cls: "grab-note-sidebar-actions" });
    const grabBtn = actions.createEl("button", {
      text: this.plugin.active ? "Stop Grab" : "Start Grab",
      cls: this.plugin.active ? "grab-note-stop-button" : "mod-cta",
    });
    grabBtn.addEventListener("click", () => this.plugin.toggle());

    const submitBtn = actions.createEl("button", { text: "Submit all", cls: "mod-cta" });
    submitBtn.disabled = this.plugin.entries.length === 0;
    submitBtn.addEventListener("click", () => this.plugin.submitEntries());

    const clearBtn = actions.createEl("button", { text: "Clear all" });
    clearBtn.disabled = this.plugin.entries.length === 0;
    clearBtn.addEventListener("click", () => this.plugin.clearEntries());

    const refreshBtn = actions.createEl("button", { text: "Refresh" });
    refreshBtn.addEventListener("click", () => this.refresh());

    if (this.plugin.entries.length === 0) {
      root.createDiv({
        cls: "grab-note-empty",
        text: "No local feedback yet. Enable Grab Mode, select a block, and save a local note.",
      });
      return;
    }

    const list = root.createDiv({ cls: "grab-note-entry-list" });
    for (const entry of this.plugin.entries) {
      this.renderEntry(list, entry);
    }
  }

  renderEntry(parent, entry) {
    const item = parent.createDiv({ cls: "grab-note-entry" });
    item.addEventListener("click", () => this.plugin.locateEntry(entry));

    const top = item.createDiv({ cls: "grab-note-entry-top" });
    top.createEl("div", { cls: "grab-note-entry-title", text: basename(entry.target) });
    top.createEl("div", { cls: "grab-note-entry-lines", text: `L${entry.startLine}–${entry.endLine}` });

    item.createEl("div", { cls: "grab-note-entry-path", text: entry.target });
    item.createEl("div", { cls: "grab-note-entry-selected", text: excerpt(entry.markdown, 180) });
    item.createEl("div", { cls: "grab-note-entry-comment", text: excerpt(entry.comment, 180) });

    const foot = item.createDiv({ cls: "grab-note-entry-foot" });
    foot.createEl("span", { text: `Created ${formatShortTime(entry.created)}` });
    if (entry.updated && entry.updated !== entry.created) {
      foot.createEl("span", { text: `Updated ${formatShortTime(entry.updated)}` });
    }

    const buttons = item.createDiv({ cls: "grab-note-entry-buttons" });
    const editBtn = buttons.createEl("button", { text: "Edit" });
    editBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      this.plugin.editEntry(entry.id);
    });
    const deleteBtn = buttons.createEl("button", { text: "Delete" });
    deleteBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      this.plugin.deleteEntry(entry.id);
    });
  }
}

class GrabNotePlugin extends Plugin {
  constructor() {
    super(...arguments);
    this.active = false;
    this.listeners = [];
    this.highlightEl = null;
    this.pendingSelection = null;
    this.selectionBarEl = null;
    this.entries = [];
    this.lastCanvasContextTarget = null;
  }

  async onload() {
    this.entries = await this.loadEntries();

    this.registerView(VIEW_TYPE_GRAB_NOTE, (leaf) => new GrabNoteView(leaf, this));

    this.addCommand({
      id: "toggle",
      name: "Toggle Grab Mode",
      callback: () => this.toggle(),
    });
    this.addCommand({
      id: "open-feedback-panel",
      name: "Open Feedback Panel",
      callback: () => this.openReviewPane(),
    });
    this.addCommand({
      id: "submit-local-feedback",
      name: "Submit Local Feedback",
      callback: () => this.submitEntries(),
    });
    this.addCommand({
      id: "copy-selection-context",
      name: "Copy Selection Context",
      callback: () => this.copySelectionContext(),
    });
    this.addCommand({
      id: "debug-open-feedback-modal",
      name: "Debug: Open Grab Note Modal",
      callback: () => this.openDebugModal(),
    });

    this.registerEvent(
      this.app.workspace.on("editor-menu", (menu, editor, view) => {
        if (!(view instanceof MarkdownView) || !view.file) return;
        menu.addItem((item) => {
          item
            .setTitle("添加反馈")
            .setIcon("message-square")
            .onClick(() => this.openFeedbackFromContext(editor, view));
        });
        menu.addItem((item) => {
          item
            .setTitle("复制上下文")
            .setIcon("copy")
            .onClick(() => this.copySelectionContext(editor, view));
        });
      })
    );

    this.registerEvent(
      this.app.workspace.on("file-menu", (menu, file) => {
        if (!(file instanceof TFile) || file.extension !== "md") return;
        menu.addItem((item) => {
          item
            .setTitle("添加反馈")
            .setIcon("message-square")
            .onClick(() => this.openFeedbackFromContext(null, null, file));
        });
        menu.addItem((item) => {
          item
            .setTitle("复制上下文")
            .setIcon("copy")
            .onClick(() => this.copySelectionContext(null, null, file));
        });
      })
    );

    this.registerCanvasContextMenus();
    this.registerDomEvent(document, "contextmenu", (event) => this.rememberCanvasContextTargetFromDom(event), true);

    this.addRibbonIcon("crosshair", "Grab Note", () => this.toggle());
    this.addRibbonIcon("message-square", "Grab Note Feedback", () => this.openReviewPane());
  }

  onunload() {
    this.deactivate();
    this.app.workspace.detachLeavesOfType(VIEW_TYPE_GRAB_NOTE);
  }

  toggle() {
    this.active ? this.deactivate() : this.activate();
  }

  activate() {
    const view = this.getMarkdownView();
    const canvasView = this.getActiveCanvasView();
    if ((!view || !view.file) && !canvasView) {
      new Notice("Open a note or canvas first");
      return;
    }
    if (canvasView && (!view || !view.file)) {
      new Notice("Canvas 中请右键组件选择“添加反馈”");
      return;
    }
    if (this.active) return;
    this.active = true;
    document.body.addClass("grab-note-active");
    new Notice("🎯 Grab Mode ON — tap any element");
    this.refreshViews();
    this.on(document, "mouseover", (e) => this.onHover(e));
    this.on(document, "mouseout", () => this.clearHighlight());
    this.on(document, "click", (e) => this.onSelect(e), true);
    this.on(document, "touchend", (e) => this.onSelect(e), true);
  }

  deactivate() {
    if (!this.active) return;
    this.active = false;
    document.body.removeClass("grab-note-active");
    this.clearHighlight();
    this.clearSelectionBar();
    this.pendingSelection = null;
    for (const off of this.listeners) off();
    this.listeners = [];
    this.refreshViews();
  }

  on(el, type, fn, capture = false) {
    el.addEventListener(type, fn, capture);
    this.listeners.push(() => el.removeEventListener(type, fn, capture));
  }

  getMarkdownView() {
    const active = this.app.workspace.getActiveViewOfType(MarkdownView);
    if (active && active.file) return active;
    const leaves = this.app.workspace.getLeavesOfType("markdown");
    for (const leaf of leaves) {
      if (leaf.view instanceof MarkdownView && leaf.view.file) return leaf.view;
    }
    return null;
  }

  findBlock(target) {
    let el = target;
    while (el && !el.matches(".markdown-preview-view")) {
      if (el.matches && el.matches(BLOCK_SELECTOR)) return el;
      el = el.parentElement;
    }
    return null;
  }

  onHover(e) {
    if (!this.active) return;
    const block = this.findBlock(e.target);
    if (block) {
      this.clearHighlight();
      block.addClass("grab-note-highlight");
      this.highlightEl = block;
    }
  }

  clearHighlight() {
    if (this.highlightEl) this.highlightEl.removeClass("grab-note-highlight");
    this.highlightEl = null;
  }

  async onSelect(e) {
    if (!this.active) return;
    let target = null;
    if (e instanceof MouseEvent) {
      target = e.target;
    } else if (e instanceof TouchEvent) {
      const t = e.changedTouches[0];
      if (t) target = document.elementFromPoint(t.clientX, t.clientY);
    }
    if (!target) return;
    if (!(target instanceof Element)) return;
    if (target.closest(".modal-container, .side-dock-ribbon")) return;

    const block = this.findBlock(target);
    if (!block) return;

    e.preventDefault();
    e.stopPropagation();
    e.stopImmediatePropagation();

    const view = this.getMarkdownView();
    if (!(view && view.file)) return;

    const hierarchy = await this.resolveDomHierarchy(view.file, block);
    if (!hierarchy) {
      new Notice("Could not locate this block in source");
      return;
    }
    const resolved = hierarchy.domPath[hierarchy.domIndex];

    this.pendingSelection = {
      file: view.file,
      info: resolved.info,
      context: hierarchy,
    };

    new FeedbackModal(this.app, this, {
      mode: "add",
      file: view.file,
      info: resolved.info,
      context: hierarchy,
      onSubmit: async (info, comment) => {
        await this.addEntry(info, comment);
        this.clearHighlight();
        this.pendingSelection = null;
        await this.openReviewPane();
      },
    }).open();
  }

  async openFeedbackFromContext(editor = null, view = null, fallbackFile = null) {
    try {
      const info = await this.resolveCopyContextInfo(editor, view, fallbackFile);
      if (!info) {
        new Notice("Select text, place the cursor in a note, or choose a Canvas component first");
        return;
      }
      if (info.kind === "canvas") {
        const canvasView = this.getActiveCanvasView();
        const canvasFile = canvasView && canvasView.file instanceof TFile ? canvasView.file : fallbackFile;
        if (!(canvasFile instanceof TFile)) {
          new Notice("请先打开 Canvas 文件");
          return;
        }
        await this.openFeedbackModalForInfo(canvasFile, this.canvasFeedbackInfo(canvasFile, info, null), null);
        return;
      }
      const targetFile = this.app.vault.getAbstractFileByPath(info.file);
      if (!(targetFile instanceof TFile)) {
        new Notice(`File not found: ${info.file}`);
        return;
      }
      await this.openFeedbackModalForInfo(targetFile, info, null);
    } catch (err) {
      console.error("Failed to open Grab Note feedback from context", err);
      new Notice(`添加反馈失败：${err.message || err}`);
    }
  }

  async openFeedbackModalForInfo(file, info, context = null) {
    this.pendingSelection = { file, info, context };
    new FeedbackModal(this.app, this, {
      mode: "add",
      file,
      info,
      context,
      onSubmit: async (selectedInfo, comment) => {
        await this.addEntry(selectedInfo, comment);
        this.clearHighlight();
        this.pendingSelection = null;
        await this.openReviewPane();
      },
    }).open();
  }

  async openCanvasFeedbackForTarget(target = null) {
    const view = this.getActiveCanvasView();
    const canvasTarget = target || (view && view.file instanceof TFile ? this.resolveCanvasTarget(view, view.file) : null);
    if (!view || !canvasTarget) {
      new Notice("请先右键或选中一个 Canvas 组件");
      return;
    }
    await this.onSelectCanvas(view, canvasTarget);
  }

  async onSelectCanvas(view, target) {
    if (!(view && view.file instanceof TFile)) return;
    let canvasData = null;
    try {
      canvasData = JSON.parse(await this.app.vault.read(view.file));
    } catch (err) {
      console.error("Failed to parse Canvas JSON", err);
      new Notice("无法解析 Canvas 文件 JSON");
      return;
    }
    const canvasInfo = await this.formatCanvasContext(view.file, canvasData, target);
    if (!canvasInfo) {
      new Notice("无法在 Canvas 文件中找到该组件");
      return;
    }
    const info = this.canvasFeedbackInfo(view.file, canvasInfo, target);
    await this.openFeedbackModalForInfo(view.file, info, null);
  }

  canvasFeedbackInfo(file, canvasInfo, target) {
    return {
      file: file.path,
      startLine: 1,
      endLine: 1,
      markdown: canvasInfo.text,
      canvasComponent: target,
    };
  }

  showSelectionBar(info) {
    this.clearSelectionBar();

    const bar = document.createElement("div");
    bar.className = "grab-note-action-bar";
    bar.setAttribute("role", "dialog");
    bar.setAttribute("aria-label", "Grab Note selected block actions");
    bar.style.cssText = [
      "position:fixed",
      "left:12px",
      "right:12px",
      "bottom:12px",
      "z-index:2147483647",
      "display:flex",
      "align-items:center",
      "justify-content:space-between",
      "gap:10px",
      "padding:10px",
      "border:1px solid var(--background-modifier-border)",
      "border-radius:14px",
      "background:var(--background-primary)",
      "color:var(--text-normal)",
      "box-shadow:0 8px 28px rgba(0,0,0,0.35)",
      "pointer-events:auto",
    ].join(";");

    const summary = document.createElement("div");
    summary.className = "grab-note-action-summary";
    summary.style.cssText = "min-width:0;flex:1";

    const title = document.createElement("div");
    title.className = "grab-note-action-title";
    title.textContent = basename(info.file);
    title.style.cssText = "overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-weight:600;font-size:13px";
    summary.appendChild(title);

    const lines = document.createElement("div");
    lines.className = "grab-note-action-lines";
    lines.textContent = `Lines ${info.startLine}–${info.endLine}`;
    lines.style.cssText = "color:var(--text-muted);font-size:12px;margin-top:2px";
    summary.appendChild(lines);
    bar.appendChild(summary);

    const actions = document.createElement("div");
    actions.className = "grab-note-action-buttons";
    actions.style.cssText = "display:flex;flex-wrap:wrap;justify-content:flex-end;gap:6px";

    const addBtn = this.createActionButton("Add feedback", true);
    addBtn.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      this.openPendingSelectionModal();
    });

    const panelBtn = this.createActionButton("Panel", false);
    panelBtn.addEventListener("click", async (event) => {
      event.preventDefault();
      event.stopPropagation();
      await this.openReviewPane();
    });

    const cancelBtn = this.createActionButton("Cancel", false);
    cancelBtn.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      this.pendingSelection = null;
      this.clearHighlight();
      this.clearSelectionBar();
    });

    actions.appendChild(addBtn);
    actions.appendChild(panelBtn);
    actions.appendChild(cancelBtn);
    bar.appendChild(actions);

    document.body.appendChild(bar);
    this.selectionBarEl = bar;
  }

  createActionButton(text, cta) {
    const button = document.createElement("button");
    button.textContent = text;
    button.type = "button";
    button.className = cta ? "mod-cta" : "";
    button.style.cssText = [
      "min-height:36px",
      "padding:6px 10px",
      "font-size:13px",
      "border-radius:8px",
      "pointer-events:auto",
      "touch-action:manipulation",
    ].join(";");
    return button;
  }

  clearSelectionBar() {
    if (this.selectionBarEl && this.selectionBarEl.parentNode) {
      this.selectionBarEl.parentNode.removeChild(this.selectionBarEl);
    }
    this.selectionBarEl = null;
  }

  openPendingSelectionModal() {
    const selection = this.pendingSelection;
    if (!selection) {
      new Notice("Tap a block first");
      return;
    }
    this.clearSelectionBar();
    new FeedbackModal(this.app, this, {
      mode: "add",
      file: selection.file,
      info: selection.info,
      context: selection.context,
      onSubmit: async (info, comment) => {
        await this.addEntry(info, comment);
        this.clearHighlight();
        this.pendingSelection = null;
        await this.openReviewPane();
      },
    }).open();
  }

  async copySelectionContext(editor = null, view = null, fallbackFile = null) {
    try {
      const info = await this.resolveCopyContextInfo(editor, view, fallbackFile);
      if (!info) {
        new Notice("Select text, place the cursor in a note, or use Grab Mode to choose a block first");
        return;
      }
      const text = info.kind === "canvas" ? info.text : this.formatCopiedContext(info);
      await this.writeClipboard(text);
      if (info.kind === "canvas") {
        new Notice(`已复制 Canvas 上下文：${info.label || "component"}`);
      } else {
        new Notice(`已复制上下文：${info.file} L${info.startLine}-${info.endLine}`);
      }
    } catch (err) {
      console.error("Failed to copy Grab Note context", err);
      new Notice(`复制上下文失败：${err.message || err}`);
    }
  }

  async resolveCopyContextInfo(editor = null, view = null, fallbackFile = null) {
    const activeView = this.app.workspace.activeLeaf && this.app.workspace.activeLeaf.view ? this.app.workspace.activeLeaf.view : null;
    const activeIsMindmap = activeView && activeView.getViewType && activeView.getViewType() === "mindmapView";
    if (!(view instanceof MarkdownView)) view = activeIsMindmap ? null : this.getMarkdownView();
    const file = view && view.file ? view.file : fallbackFile;
    const mode = view && view.getMode ? view.getMode() : null;

    if (editor && view && view.file) {
      const info = this.contextInfoFromEditor(view.file, editor, true);
      if (info) return info;
    }

    if (view && view.file && view.editor && mode !== "preview") {
      const info = this.contextInfoFromEditor(view.file, view.editor, false);
      if (info) return info;
    }

    if (this.pendingSelection && this.pendingSelection.info) {
      if (!file || this.pendingSelection.info.file === file.path) return this.pendingSelection.info;
    }

    const mindmapInfo = await this.contextInfoFromMindmapSelection();
    if (mindmapInfo) return mindmapInfo;

    const canvasInfo = await this.contextInfoFromCanvasSelection();
    if (canvasInfo) return canvasInfo;

    const readingInfo = await this.contextInfoFromReadingSelection(file);
    if (readingInfo) return readingInfo;

    return null;
  }

  registerCanvasContextMenus() {
    const onCanvasMenu = (kind) => (menu, target) => {
      this.rememberCanvasContextTargetFromRuntime(kind, target);
      const canvasTarget = canvasTargetFromRuntime(target, kind);
      if (!menu || !menu.addItem) return;
      menu.addItem((item) => {
        item
          .setTitle("添加反馈")
          .setIcon("message-square")
          .onClick(() => this.openCanvasFeedbackForTarget(canvasTarget));
      });
      menu.addItem((item) => {
        item
          .setTitle("复制上下文")
          .setIcon("copy")
          .onClick(() => this.copySelectionContext());
      });
      if (!canvasTarget && target) console.debug("Grab Note could not resolve canvas menu target", kind, target);
    };

    try {
      this.registerEvent(this.app.workspace.on("canvas:node-menu", onCanvasMenu("node")));
    } catch (err) {
      console.debug("Grab Note canvas:node-menu is unavailable", err);
    }
    try {
      this.registerEvent(this.app.workspace.on("canvas:edge-menu", onCanvasMenu("edge")));
    } catch (err) {
      console.debug("Grab Note canvas:edge-menu is unavailable", err);
    }
  }

  contextInfoFromEditor(file, editor, requireSelection) {
    if (!file || !editor) return null;
    const range = this.getPrimaryEditorRange(editor);
    if (!range) return null;
    const isEmpty = range.from.line === range.to.line && range.from.ch === range.to.ch;
    if (isEmpty && requireSelection) return null;

    if (isEmpty) {
      const lineNo = range.from.line;
      return {
        file: file.path,
        startLine: lineNo + 1,
        endLine: lineNo + 1,
        markdown: editor.getLine(lineNo) || "",
      };
    }

    return {
      file: file.path,
      startLine: range.from.line + 1,
      endLine: range.to.line + 1,
      markdown: editor.getRange(range.from, range.to),
    };
  }

  getPrimaryEditorRange(editor) {
    let from = null;
    let to = null;
    if (editor.listSelections) {
      const selections = editor.listSelections() || [];
      const selected = selections.find((sel) => sel && !sameEditorPos(sel.anchor, sel.head)) || selections[0];
      if (selected) {
        from = selected.anchor;
        to = selected.head;
      }
    }
    if ((!from || !to) && editor.getCursor) {
      from = editor.getCursor("from") || editor.getCursor();
      to = editor.getCursor("to") || from;
    }
    if (!from || !to) return null;
    return normalizeEditorRange(from, to);
  }

  async contextInfoFromReadingSelection(file) {
    if (!(file instanceof TFile)) return null;
    const selection = window.getSelection ? window.getSelection() : null;
    if (!selection || selection.rangeCount === 0 || !String(selection.toString() || "").trim()) return null;

    const range = selection.getRangeAt(0);
    const startEl = nodeToElement(range.startContainer);
    const endEl = nodeToElement(range.endContainer);
    const block = this.findBlock(startEl) || this.findBlock(endEl);
    if (!block) return null;
    const resolved = await this.resolveBlockContext(file, block);
    return resolved ? resolved.info : null;
  }

  async contextInfoFromMindmapSelection() {
    const leaf = this.app.workspace.activeLeaf;
    const view = leaf && leaf.view ? leaf.view : null;
    if (!view || !view.getViewType || view.getViewType() !== "mindmapView") return null;

    const file = view.file;
    const mindmap = view.mindmap;
    const node = mindmap && mindmap.selectNode;
    if (!(file instanceof TFile)) return null;
    if (!node) {
      new Notice("请先选择一个思维导图节点");
      return null;
    }

    const content = await this.app.vault.read(file);
    return this.contextInfoFromMindmapNode(file, content, node, mindmap);
  }

  async contextInfoFromCanvasSelection() {
    const view = this.getActiveCanvasView();
    if (!view) return null;
    const canvasFile = view.file;
    if (!(canvasFile instanceof TFile) || canvasFile.extension !== "canvas") return null;

    const target = this.resolveCanvasTarget(view, canvasFile);
    if (!target) {
      new Notice("请先右键或选中一个 Canvas 组件");
      return null;
    }

    let canvasData = null;
    try {
      canvasData = JSON.parse(await this.app.vault.read(canvasFile));
    } catch (err) {
      console.error("Failed to parse Canvas JSON", err);
      new Notice("无法解析 Canvas 文件 JSON");
      return null;
    }

    const result = await this.formatCanvasContext(canvasFile, canvasData, target);
    if (!result) new Notice("无法在 Canvas 文件中找到该组件");
    return result;
  }

  getActiveCanvasView() {
    const view = this.app.workspace.activeLeaf && this.app.workspace.activeLeaf.view ? this.app.workspace.activeLeaf.view : null;
    if (!view) return null;
    if (view.getViewType && view.getViewType() === "canvas") return view;
    if (view.file instanceof TFile && view.file.extension === "canvas") return view;
    if (view.canvas) return view;
    return null;
  }

  resolveCanvasTarget(view, canvasFile) {
    const cached = this.getCachedCanvasTarget(canvasFile);
    if (cached) return cached;

    const selected = this.findCanvasSelectedRuntimeTarget(view);
    if (selected) return selected;

    const selectedDom = this.findCanvasSelectedDomTarget(view);
    if (selectedDom) return selectedDom;

    return null;
  }

  getCachedCanvasTarget(canvasFile) {
    const target = this.lastCanvasContextTarget;
    if (!target) return null;
    if (Date.now() - target.capturedAt > 10000) return null;
    if (target.canvasPath && canvasFile && target.canvasPath !== canvasFile.path) return null;
    return { kind: target.kind, id: target.id };
  }

  findCanvasSelectedRuntimeTarget(view) {
    const canvas = view && view.canvas ? view.canvas : null;
    const candidates = [
      canvas && canvas.selection,
      canvas && canvas.selected,
      canvas && canvas.selectedNode,
      canvas && canvas.selectedEdge,
      canvas && canvas.getSelection && canvas.getSelection(),
    ];
    for (const candidate of candidates) {
      const target = canvasTargetFromRuntime(candidate);
      if (target) return target;
    }
    return null;
  }

  findCanvasSelectedDomTarget(view) {
    const root = view && view.containerEl ? view.containerEl : document;
    const el = root.querySelector(".is-selected, .mod-selected, .selected, [aria-selected='true']");
    return el ? canvasTargetFromElement(el) : null;
  }

  rememberCanvasContextTargetFromRuntime(kind, runtimeObject) {
    const view = this.getActiveCanvasView();
    const file = view && view.file instanceof TFile ? view.file : null;
    const target = canvasTargetFromRuntime(runtimeObject, kind);
    if (!target || !file) return false;
    this.lastCanvasContextTarget = {
      canvasPath: file.path,
      kind: target.kind,
      id: target.id,
      capturedAt: Date.now(),
    };
    return true;
  }

  rememberCanvasContextTargetFromDom(event) {
    const view = this.getActiveCanvasView();
    if (!view || !(view.file instanceof TFile)) return;
    const root = view.containerEl || document;
    if (event.target && root !== document && !root.contains(event.target)) return;
    const target = canvasTargetFromElement(event.target);
    if (!target) return;
    this.lastCanvasContextTarget = {
      canvasPath: view.file.path,
      kind: target.kind,
      id: target.id,
      capturedAt: Date.now(),
    };
  }

  async formatCanvasContext(canvasFile, canvasData, target) {
    const nodes = Array.isArray(canvasData && canvasData.nodes) ? canvasData.nodes : [];
    const edges = Array.isArray(canvasData && canvasData.edges) ? canvasData.edges : [];
    if (!target.kind || target.kind === "node") {
      const node = nodes.find((item) => item && item.id === target.id);
      if (node) return this.formatCanvasNodeContext(canvasFile, canvasData, node);
    }
    if (!target.kind || target.kind === "edge") {
      const edge = edges.find((item) => item && item.id === target.id);
      if (edge) return this.formatCanvasEdgeContext(canvasFile, canvasData, edge);
    }
    return null;
  }

  async formatCanvasNodeContext(canvasFile, canvasData, node) {
    const header = canvasHeaderLines(canvasFile, "node", node);
    let body = [];
    if (node.type === "text") {
      body = ["", "```markdown", node.text || "", "```"];
    } else if (node.type === "file") {
      const resolved = await this.resolveCanvasFileNodeMarkdown(node);
      if (resolved && resolved.markdown) {
        header.push(`subpath_resolved: true`);
        if (resolved.lines) header.push(`lines: ${resolved.lines}`);
        body = ["", "```markdown", resolved.markdown, "```"];
      } else if (node.subpath) {
        header.push(`subpath_resolved: false`);
      }
    } else if (node.type === "group") {
      const contained = canvasContainedNodes(canvasData, node);
      header.push(`contains: ${contained.length} nodes`);
      body = ["", "## Contained nodes", ...contained.map((item) => `- ${canvasNodeSummary(item)}`)];
    }
    const text = [...header, "</obsidian-canvas-context>", ...body, ""].join("\n");
    return { kind: "canvas", text, label: `${node.type || "node"} ${node.id}` };
  }

  async resolveCanvasFileNodeMarkdown(node) {
    if (!node || node.type !== "file" || !node.file || !node.subpath) return null;
    const file = this.app.vault.getAbstractFileByPath(node.file);
    if (!(file instanceof TFile) || file.extension !== "md") return null;
    const content = await this.app.vault.read(file);
    const cache = this.app.metadataCache.getFileCache(file);
    const resolved = cache && resolveSubpath ? resolveSubpath(cache, node.subpath) : null;
    if (!resolved || !resolved.start) return null;
    const start = resolved.start.offset || 0;
    const end = resolved.end && Number.isFinite(resolved.end.offset) ? resolved.end.offset : content.length;
    const markdown = content.slice(start, end).trimEnd();
    const startLine = content.slice(0, start).split("\n").length;
    const endLine = content.slice(0, end).split("\n").length;
    return { markdown, lines: `${startLine}-${endLine}` };
  }

  formatCanvasEdgeContext(canvasFile, canvasData, edge) {
    const nodes = Array.isArray(canvasData && canvasData.nodes) ? canvasData.nodes : [];
    const from = nodes.find((item) => item && item.id === edge.fromNode);
    const to = nodes.find((item) => item && item.id === edge.toNode);
    const lines = [
      "<obsidian-canvas-context>",
      `canvas: ${canvasFile.path}`,
      `component: edge`,
      `id: ${edge.id}`,
      `fromNode: ${edge.fromNode || ""}`,
      `toNode: ${edge.toNode || ""}`,
    ];
    if (edge.label) lines.push(`label: ${edge.label}`);
    lines.push("</obsidian-canvas-context>", "", "## Relation");
    if (from) lines.push(`- From: ${canvasNodeSummary(from)}`);
    if (to) lines.push(`- To: ${canvasNodeSummary(to)}`);
    lines.push("");
    return { kind: "canvas", text: lines.join("\n"), label: `edge ${edge.id}` };
  }

  contextInfoFromMindmapNode(file, content, node, mindmap) {
    const lines = content.split("\n");
    const range = this.findMindmapNodeLine(lines, node, mindmap);
    if (!range) {
      new Notice("无法定位该思维导图节点对应的 Markdown 源码；可尝试为节点添加 block id 或切回 Markdown 模式选择文本");
      return null;
    }
    if (range.ambiguous) {
      new Notice("找到多个相同节点文本，无法安全定位；可尝试为节点添加 block id");
      return null;
    }
    return {
      file: file.path,
      startLine: range.start + 1,
      endLine: range.end + 1,
      markdown: lines.slice(range.start, range.end + 1).join("\n"),
    };
  }

  findMindmapNodeLine(lines, node, mindmap) {
    const nodeText = mindmapNodeText(node);
    const normalizedNodeText = norm(nodeText);
    if (!normalizedNodeText) return null;

    const nodeId = mindmapNodeId(node);
    if (nodeId) {
      const blockIdPattern = new RegExp(`(?:^|\\s)\\^${escapeRegExp(nodeId)}(?:\\s*$)`);
      const matches = [];
      for (let i = 0; i < lines.length; i++) {
        if (blockIdPattern.test(lines[i])) matches.push({ start: i, end: i });
      }
      if (matches.length === 1) return matches[0];
      if (matches.length > 1) return { ambiguous: true };
    }

    const level = mindmapNodeLevel(node);
    const headLevel = Number(mindmap && mindmap.setting && mindmap.setting.headLevel) || 2;
    const expectedHeadingLevel = level >= 0 && level < headLevel ? level + 1 : 0;

    if (expectedHeadingLevel > 0 && expectedHeadingLevel <= 6) {
      const headingMatches = [];
      for (let i = 0; i < lines.length; i++) {
        if (!isHeadingLine(lines[i])) continue;
        if (expectedHeadingLevel && headingLevel(lines[i]) !== expectedHeadingLevel) continue;
        if (norm(stripMarkdownNodeMarker(lines[i])) === normalizedNodeText) headingMatches.push({ start: i, end: i });
      }
      const resolved = resolveMindmapCandidates(headingMatches, lines, node);
      if (resolved) return resolved;
    }

    const listMatches = [];
    for (let i = 0; i < lines.length; i++) {
      if (!/^\s*(?:[-*+] |\d+[.)] )/.test(lines[i])) continue;
      if (norm(stripMarkdownNodeMarker(lines[i])) === normalizedNodeText) listMatches.push({ start: i, end: i });
    }
    const listResolved = resolveMindmapCandidates(listMatches, lines, node);
    if (listResolved) return listResolved;

    const normalizedMatches = [];
    for (let i = 0; i < lines.length; i++) {
      if (norm(stripMarkdownNodeMarker(lines[i])) === normalizedNodeText) normalizedMatches.push({ start: i, end: i });
    }
    const normalizedResolved = resolveMindmapCandidates(normalizedMatches, lines, node);
    if (normalizedResolved) return normalizedResolved;

    const nodeLineCount = Math.max(2, String(nodeText || "").split(/\r?\n/).length);
    const windowMatches = [];
    for (let start = 0; start < lines.length; start++) {
      const end = Math.min(lines.length - 1, start + nodeLineCount - 1);
      if (norm(lines.slice(start, end + 1).join("\n")) === normalizedNodeText) windowMatches.push({ start, end });
    }
    return resolveMindmapCandidates(windowMatches, lines, node);
  }

  formatCopiedContext(info) {
    return [
      "<obsidian-context>",
      `file: ${info.file}`,
      `lines: ${info.startLine}-${info.endLine}`,
      "</obsidian-context>",
      "",
      "```markdown",
      info.markdown || "",
      "```",
      "",
    ].join("\n");
  }

  async writeClipboard(text) {
    if (!navigator.clipboard || !navigator.clipboard.writeText) {
      throw new Error("Clipboard API is unavailable");
    }
    await navigator.clipboard.writeText(text);
  }

  openDebugModal() {
    const file = this.app.workspace.getActiveFile();
    if (!file) {
      new Notice("Open a note first");
      return;
    }
    new FeedbackModal(this.app, this, {
      mode: "add",
      file,
      info: {
        file: file.path,
        startLine: 1,
        endLine: 1,
        markdown: "Debug modal opened successfully.",
      },
      context: null,
      onSubmit: async (info, comment) => {
        await this.addEntry(info, comment);
        await this.openReviewPane();
      },
    }).open();
  }

  async resolveDomHierarchy(file, block) {
    const base = await this.resolveBlockContext(file, block);
    if (!base) return null;

    const content = await this.app.vault.read(file);
    const ranges = this.buildSourceRanges(file, content);
    const domPath = [];
    const seen = new Set();

    const pushInfo = (info, context, label) => {
      const key = `${info.startLine}:${info.endLine}`;
      if (seen.has(key)) return;
      seen.add(key);
      domPath.push({
        info,
        sourceContext: context,
        label,
      });
    };

    const baseLabel = block.tagName ? block.tagName.toLowerCase() : "selected block";
    pushInfo(base.info, base.context, baseLabel);

    if (base.context && Array.isArray(base.context.ranges) && ranges.length > 0) {
      const startIndex = base.context.startIndex;
      const endIndex = base.context.endIndex;
      const baseStart = ranges[startIndex] ? ranges[startIndex].start : base.info.startLine - 1;

      for (let i = startIndex - 1; i >= 0; i--) {
        const range = ranges[i];
        if (!range) continue;
        const line = content.split("\n")[range.start] || "";
        if (!isHeadingLine(line)) continue;
        const nextHeading = findNextHeadingIndex(ranges, content, i);
        const parentEndIndex = nextHeading >= 0 ? nextHeading - 1 : ranges.length - 1;
        if (parentEndIndex < endIndex) continue;
        if (range.start > baseStart) continue;
        const info = await this.infoFromRange(file, ranges, i, parentEndIndex);
        const headingText = line.replace(/^\s{0,3}#{1,6}\s*/, "").trim();
        pushInfo(info, { ranges, startIndex: i, endIndex: parentEndIndex }, headingText || "parent section");
      }
    }

    const domNodes = [];
    let el = block.parentElement;
    while (el && el.matches && !el.matches(".markdown-preview-view")) {
      domNodes.push(el);
      el = el.parentElement;
    }
    for (const node of domNodes) {
      if (isGrabNoteIgnoredElement(node)) continue;
      const resolved = await this.resolveBlockContext(file, node);
      if (!resolved) continue;
      const label = node.tagName ? node.tagName.toLowerCase() : "parent block";
      pushInfo(resolved.info, resolved.context, label);
    }

    domPath.sort((a, b) => {
      const aSize = a.info.endLine - a.info.startLine;
      const bSize = b.info.endLine - b.info.startLine;
      return aSize - bSize || a.info.startLine - b.info.startLine;
    });

    if (domPath.length === 0) return null;
    return { domPath, domIndex: 0 };
  }

  async resolveSection(file, lineStart, lineEnd) {
    const content = await this.app.vault.read(file);
    const lines = content.split("\n");
    const ranges = this.buildSourceRanges(file, content);
    const start = clamp(lineStart, 0, Math.max(0, lines.length - 1));
    const end = clamp(lineEnd, start, Math.max(0, lines.length - 1));
    let startIndex = ranges.findIndex((r) => r.end >= start);
    if (startIndex < 0) startIndex = 0;
    let endIndex = ranges.findIndex((r) => r.end >= end);
    if (endIndex < 0) endIndex = ranges.length - 1;
    if (endIndex < startIndex) endIndex = startIndex;
    return {
      info: {
        file: file.path,
        startLine: start + 1,
        endLine: end + 1,
        markdown: lines.slice(start, end + 1).join("\n"),
      },
      context: ranges.length > 0 ? { ranges, startIndex, endIndex } : null,
    };
  }

  async resolveBlockContext(file, block) {
    const content = await this.app.vault.read(file);
    const lines = content.split("\n");
    const domText = norm(block.textContent || "");
    if (!domText) return null;

    const ranges = this.buildSourceRanges(file, content);
    let bestIndex = -1;
    let bestScore = 0;
    for (let i = 0; i < ranges.length; i++) {
      const range = ranges[i];
      const secText = norm(lines.slice(range.start, range.end + 1).join(" "));
      const score = matchScore(domText, secText);
      if (score > bestScore && score > 0.3) {
        bestScore = score;
        bestIndex = i;
      }
    }

    if (bestIndex >= 0) {
      const info = await this.infoFromRange(file, ranges, bestIndex, bestIndex);
      return {
        info,
        context: { ranges, startIndex: bestIndex, endIndex: bestIndex },
      };
    }

    for (let i = 0; i < lines.length; i++) {
      const lt = norm(lines[i]);
      if (lt.length > 5 && (domText.includes(lt) || lt.includes(domText))) {
        let end = i;
        while (end + 1 < lines.length && lines[end + 1].trim() !== "") end++;
        const startIndex = Math.max(0, ranges.findIndex((r) => r.end >= i));
        const endIndex = Math.max(startIndex, ranges.findIndex((r) => r.end >= end));
        return {
          info: {
            file: file.path,
            startLine: i + 1,
            endLine: end + 1,
            markdown: lines.slice(i, end + 1).join("\n"),
          },
          context: ranges.length > 0 ? { ranges, startIndex, endIndex } : null,
        };
      }
    }

    return null;
  }

  buildSourceRanges(file, content) {
    const lines = content.split("\n");
    const cache = this.app.metadataCache.getFileCache(file);
    const ranges = [];
    const seen = new Set();

    if (cache && Array.isArray(cache.sections)) {
      for (const sec of cache.sections) {
        if (sec.type === "yaml") continue;
        const start = clamp(sec.position.start.line, 0, Math.max(0, lines.length - 1));
        const end = clamp(sec.position.end.line, start, Math.max(0, lines.length - 1));
        const key = `${start}:${end}`;
        if (!seen.has(key)) {
          seen.add(key);
          ranges.push({ start, end });
        }
      }
    }

    ranges.sort((a, b) => a.start - b.start || a.end - b.end);
    if (ranges.length > 0) return ranges;

    let start = null;
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].trim() === "") {
        if (start !== null) {
          ranges.push({ start, end: i - 1 });
          start = null;
        }
      } else if (start === null) {
        start = i;
      }
    }
    if (start !== null) ranges.push({ start, end: lines.length - 1 });
    return ranges;
  }

  async infoFromRange(file, ranges, startIndex, endIndex) {
    const content = await this.app.vault.read(file);
    const lines = content.split("\n");
    const start = ranges[startIndex].start;
    const end = ranges[endIndex].end;
    return {
      file: file.path,
      startLine: start + 1,
      endLine: end + 1,
      markdown: lines.slice(start, end + 1).join("\n"),
    };
  }

  async contextFromEntry(entry) {
    const file = this.app.vault.getAbstractFileByPath(entry.target);
    if (!(file instanceof TFile)) return null;
    const content = await this.app.vault.read(file);
    const ranges = this.buildSourceRanges(file, content);
    if (ranges.length === 0) return { file, info: entry, context: null };

    const startLine = Math.max(0, entry.startLine - 1);
    const endLine = Math.max(startLine, entry.endLine - 1);
    let startIndex = ranges.findIndex((r) => r.end >= startLine);
    if (startIndex < 0) startIndex = 0;
    let endIndex = ranges.findIndex((r) => r.end >= endLine);
    if (endIndex < 0) endIndex = ranges.length - 1;
    if (endIndex < startIndex) endIndex = startIndex;

    const info = await this.infoFromRange(file, ranges, startIndex, endIndex);
    return { file, info, context: { ranges, startIndex, endIndex } };
  }

  async addEntry(info, comment) {
    const now = new Date().toISOString();
    this.entries.push({
      id: makeId(),
      target: info.file,
      startLine: info.startLine,
      endLine: info.endLine,
      markdown: info.markdown,
      comment,
      created: now,
      updated: now,
    });
    this.entries = sortEntriesNewestFirst(this.entries);
    await this.saveEntries();
    this.refreshViews();
    new Notice("✅ Feedback saved locally");
  }

  async updateEntry(id, info, comment) {
    const entry = this.entries.find((item) => item.id === id);
    if (!entry) return;
    entry.target = info.file;
    entry.startLine = info.startLine;
    entry.endLine = info.endLine;
    entry.markdown = info.markdown;
    entry.comment = comment;
    entry.updated = new Date().toISOString();
    this.entries = sortEntriesNewestFirst(this.entries);
    await this.saveEntries();
    this.refreshViews();
    new Notice("✅ Local feedback updated");
  }

  async deleteEntry(id) {
    this.entries = this.entries.filter((entry) => entry.id !== id);
    await this.saveEntries();
    this.refreshViews();
    new Notice("Feedback deleted");
  }

  async clearEntries() {
    if (this.entries.length === 0) return;
    if (!window.confirm(`Clear all ${this.entries.length} local feedback notes?`)) return;
    this.entries = [];
    await this.saveEntries();
    this.refreshViews();
    new Notice("Local feedback cleared");
  }

  async submitEntries() {
    if (this.entries.length === 0) {
      new Notice("No local feedback to submit");
      return;
    }
    const entries = [...this.entries];
    try {
      await this.ensureFolder(FEEDBACK_DIR);
      for (let i = 0; i < entries.length; i++) {
        const path = await this.getAvailableFeedbackPath(entries[i], i + 1);
        await this.app.vault.create(path, this.formatFeedbackEntry(entries[i]));
      }
      const count = entries.length;
      this.entries = [];
      await this.saveEntries();
      if (this.active) this.deactivate();
      this.refreshViews();
      new Notice(`✅ Submitted ${count} feedback ${count === 1 ? "note" : "notes"}`);
    } catch (err) {
      console.error("Failed to submit Grab Note feedback", err);
      this.entries = sortEntriesNewestFirst(entries);
      await this.saveEntries().catch((saveErr) => console.error("Failed to preserve Grab Note local feedback", saveErr));
      this.refreshViews();
      new Notice(`Submit failed; local feedback kept: ${err.message || err}`);
    }
  }

  async locateEntry(entry) {
    const file = this.app.vault.getAbstractFileByPath(entry.target);
    if (!(file instanceof TFile)) {
      new Notice(`File not found: ${entry.target}`);
      return;
    }
    const leaf = this.getTargetMarkdownLeaf(file) || this.app.workspace.getLeaf("tab");
    const line = Math.max(0, entry.startLine - 1);
    await leaf.openFile(file, {
      active: true,
      eState: {
        line,
        startLoc: { line, col: 0 },
        endLoc: { line: Math.max(line, entry.endLine - 1), col: 0 },
      },
    });
    this.app.workspace.setActiveLeaf(leaf, { focus: true });
    this.scheduleRevealEntry(leaf, entry);
  }

  getTargetMarkdownLeaf(file) {
    const leaves = this.app.workspace.getLeavesOfType("markdown");
    for (const leaf of leaves) {
      if (leaf.view instanceof MarkdownView && leaf.view.file && leaf.view.file.path === file.path) return leaf;
    }
    for (const leaf of leaves) {
      if (leaf.view instanceof MarkdownView) return leaf;
    }
    return null;
  }

  scheduleRevealEntry(leaf, entry) {
    const delays = [120, 300, 700, 1200, 2000];
    delays.forEach((delay, index) => {
      setTimeout(() => this.revealEntryInLeaf(leaf, entry, index === delays.length - 1), delay);
    });
  }

  revealEntryInLeaf(leaf, entry, report = false) {
    const view = leaf.view;
    if (!(view instanceof MarkdownView)) return;
    const startLine = Math.max(0, entry.startLine - 1);
    const endLine = Math.max(startLine, entry.endLine - 1);

    if (view.editor) {
      view.editor.setCursor({ line: startLine, ch: 0 });
      if (view.editor.setSelection) {
        view.editor.setSelection({ line: startLine, ch: 0 }, { line: endLine, ch: Number.MAX_SAFE_INTEGER });
      }
      view.editor.scrollIntoView({ from: { line: startLine, ch: 0 }, to: { line: endLine, ch: 0 } }, true);
    }

    const block = this.findRenderedBlockForEntry(leaf, entry);
    if (block) {
      block.scrollIntoView({ block: "center", behavior: "smooth" });
      this.flashLocatedBlock(block);
      return;
    }

    if (report) {
      const container = leaf && leaf.view && leaf.view.containerEl ? leaf.view.containerEl : document;
      const preview = container.querySelector(".markdown-preview-view") || document.querySelector(".markdown-preview-view");
      const dataLineCount = preview ? preview.querySelectorAll("[data-line]").length : 0;
      const mode = view.getMode ? view.getMode() : "unknown";
      new Notice(`Located line ${entry.startLine}; blue outline unavailable (mode=${mode}, preview=${preview ? "yes" : "no"}, data-line=${dataLineCount})`);
    }
  }

  findRenderedBlockForEntry(leaf, entry) {
    const container = leaf && leaf.view && leaf.view.containerEl ? leaf.view.containerEl : document;
    const preview = container.querySelector(".markdown-preview-view") || document.querySelector(".markdown-preview-view");
    if (!preview) return null;

    const lineBlock = this.findRenderedBlockByLine(preview, entry.startLine, entry.endLine);
    if (lineBlock) return lineBlock;

    const targetText = norm(entry.markdown || "");
    if (!targetText) return null;
    let best = null;
    let bestScore = 0;
    const blocks = preview.querySelectorAll(BLOCK_SELECTOR);
    for (const block of blocks) {
      const blockText = norm(block.textContent || "");
      if (!blockText) continue;
      const score = matchScore(targetText, blockText);
      if (score > bestScore && score > 0.3) {
        bestScore = score;
        best = block;
      }
    }
    return best;
  }

  findRenderedBlockByLine(preview, startLine, endLine) {
    const start = Math.max(0, startLine - 1);
    const end = Math.max(start, endLine - 1);
    const candidates = preview.querySelectorAll("[data-line]");
    let best = null;
    let bestDistance = Number.MAX_SAFE_INTEGER;
    for (const el of candidates) {
      const raw = el.getAttribute("data-line");
      const line = Number.parseInt(raw || "", 10);
      if (!Number.isFinite(line)) continue;
      if (line >= start && line <= end) return this.closestRenderableBlock(el);
      const distance = Math.min(Math.abs(line - start), Math.abs(line - end));
      if (distance < bestDistance) {
        bestDistance = distance;
        best = el;
      }
    }
    return best ? this.closestRenderableBlock(best) : null;
  }

  closestRenderableBlock(el) {
    let current = el;
    while (current && current.matches && !current.matches(".markdown-preview-view")) {
      if (current.matches(BLOCK_SELECTOR)) return current;
      current = current.parentElement;
    }
    return el;
  }

  flashLocatedBlock(block) {
    const previous = document.querySelectorAll(".grab-note-located");
    for (const el of previous) el.removeClass("grab-note-located");
    block.addClass("grab-note-located");
    setTimeout(() => block.removeClass("grab-note-located"), 3500);
  }

  async editEntry(id) {
    const entry = this.entries.find((item) => item.id === id);
    if (!entry) return;
    const resolved = await this.contextFromEntry(entry);
    if (!resolved) {
      new Notice(`File not found: ${entry.target}`);
      return;
    }
    await this.locateEntry(entry);
    new FeedbackModal(this.app, this, {
      mode: "edit",
      file: resolved.file,
      info: resolved.info,
      context: resolved.context,
      initialComment: entry.comment,
      onSubmit: async (info, comment) => this.updateEntry(id, info, comment),
    }).open();
  }

  async openReviewPane() {
    let leaf = this.app.workspace.getLeavesOfType(VIEW_TYPE_GRAB_NOTE)[0];
    if (!leaf) {
      leaf = this.app.workspace.getRightLeaf(false) || this.app.workspace.getRightLeaf(true);
      if (!leaf) {
        new Notice("Could not open Grab Note side panel");
        return;
      }
      await leaf.setViewState({ type: VIEW_TYPE_GRAB_NOTE, active: true });
    }
    this.app.workspace.revealLeaf(leaf);
    this.refreshViews();
  }

  refreshViews() {
    for (const leaf of this.app.workspace.getLeavesOfType(VIEW_TYPE_GRAB_NOTE)) {
      if (leaf.view instanceof GrabNoteView) leaf.view.refresh();
    }
  }

  async loadEntries() {
    const pluginData = await this.loadData().catch(() => null);
    const pluginEntries = Array.isArray(pluginData && pluginData.entries) ? pluginData.entries : [];
    const localEntries = await this.loadLocalEntries();
    return mergeEntries(pluginEntries, localEntries);
  }

  async loadLocalEntries() {
    const file = this.app.vault.getAbstractFileByPath(LOCAL_STATE_PATH);
    if (!(file instanceof TFile)) return [];
    try {
      const data = JSON.parse(await this.app.vault.read(file));
      return Array.isArray(data && data.entries) ? data.entries : [];
    } catch (err) {
      console.error("Failed to load Grab Note local state", err);
      new Notice("Grab Note local state is invalid; starting with plugin data only");
      return [];
    }
  }

  async saveEntries() {
    const data = { entries: this.entries };
    await this.saveData(data);
    await this.saveLocalEntries(data);
  }

  async saveLocalEntries(data) {
    await this.ensureFolder(FEEDBACK_DIR);
    const body = JSON.stringify(data, null, 2);
    await this.app.vault.adapter.write(LOCAL_STATE_PATH, body);
  }

  async ensureFolder(path) {
    const parts = path.split("/").filter(Boolean);
    let current = "";
    for (const part of parts) {
      current = current ? `${current}/${part}` : part;
      const exists = await this.app.vault.adapter.exists(current);
      if (!exists) {
        await this.app.vault.adapter.mkdir(current);
      }
    }
  }

  async getAvailableFeedbackPath(entry, index) {
    const stamp = timestampForFile();
    const suffix = slugify(`${basename(entry.target)}-${entry.startLine}-${index}`);
    let path = `${FEEDBACK_DIR}/${stamp}-${suffix}.md`;
    let counter = 2;
    while (this.app.vault.getAbstractFileByPath(path)) {
      path = `${FEEDBACK_DIR}/${stamp}-${suffix}-${counter}.md`;
      counter += 1;
    }
    return path;
  }

  formatFeedbackEntry(entry) {
    const created = new Date().toISOString();
    const title = `Feedback - ${basename(entry.target)} L${entry.startLine}`;
    return [
      "---",
      `title: ${yamlString(title)}`,
      `created: ${created}`,
      `updated: ${created}`,
      "type: feedback",
      "status: pending",
      "feedback_type: other",
      `target: ${yamlString(entry.target)}`,
      "source_context: obsidian-selection",
      "processed_at:",
      "processed_by:",
      "changed_files: []",
      "confidence: medium",
      "tags:",
      "  - knowledge/feedback",
      "---",
      "",
      `> **TLDR**: Feedback for \`${entry.target}\` lines ${entry.startLine}–${entry.endLine}.`,
      "",
      "## Quoted Text",
      "",
      entry.markdown || "N/A",
      "",
      "## Feedback",
      "",
      entry.comment,
      "",
      "## Expected Action",
      "",
      "Apply the feedback to the target note after verifying the quoted text still matches.",
      "",
      "## Processing Notes",
      "",
      "- result:",
      "- failure_reason:",
      "",
    ].join("\n");
  }
}

function norm(s) {
  return s.replace(/[#*_`~\[\]()!>|\\-]/g, "").replace(/\s+/g, " ").trim().toLowerCase();
}

function escapeRegExp(value) {
  return String(value || "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function mindmapNodeText(node) {
  if (!node) return "";
  const data = node.getData ? node.getData() : node.data;
  return String((data && data.text) || "").trim();
}

function mindmapNodeId(node) {
  if (!node) return "";
  const id = node.getId ? node.getId() : node.id;
  return String(id || "").trim();
}

function mindmapNodeLevel(node) {
  if (!node) return -1;
  const level = node.getLevel ? node.getLevel() : node.level;
  return Number.isFinite(Number(level)) ? Number(level) : -1;
}

function mindmapParentNode(node) {
  if (!node) return null;
  if (node.getParent) return node.getParent();
  return node.parent || node.parentNode || node.pNode || null;
}

function mindmapParentTexts(node) {
  const result = [];
  const seen = new Set();
  let current = mindmapParentNode(node);
  while (current && !seen.has(current)) {
    seen.add(current);
    const text = norm(mindmapNodeText(current));
    if (text) result.push(text);
    current = mindmapParentNode(current);
  }
  return result;
}

function stripMarkdownNodeMarker(line) {
  return String(line || "")
    .replace(/^\s{0,3}#{1,6}\s+/, "")
    .replace(/^\s*(?:[-*+] |\d+[.)] )\s*/, "")
    .replace(/\s+\^[a-z0-9-]+\s*$/i, "")
    .trim();
}

function resolveMindmapCandidates(candidates, lines, node) {
  if (!candidates || candidates.length === 0) return null;
  if (candidates.length === 1) return candidates[0];

  let narrowed = candidates;
  const parents = mindmapParentTexts(node);
  if (parents.length > 0) {
    const scored = candidates.map((candidate) => ({
      candidate,
      score: mindmapParentScore(lines, candidate.start, parents),
    }));
    scored.sort((a, b) => b.score - a.score || a.candidate.start - b.candidate.start);
    if (scored[0].score > 0 && scored[0].score > scored[1].score) return scored[0].candidate;
    if (scored[0].score > 0) {
      narrowed = scored.filter((item) => item.score === scored[0].score).map((item) => item.candidate);
    }
  }

  const siblingIndex = mindmapSameTextSiblingIndex(node);
  if (siblingIndex >= 0 && siblingIndex < narrowed.length) {
    return narrowed.slice().sort((a, b) => a.start - b.start)[siblingIndex];
  }

  const documentIndex = mindmapSameTextDocumentIndex(node);
  if (documentIndex >= 0 && documentIndex < candidates.length) {
    return candidates.slice().sort((a, b) => a.start - b.start)[documentIndex];
  }

  return { ambiguous: true };
}

function mindmapParentScore(lines, start, parents) {
  let score = 0;
  let searchFrom = start - 1;
  for (const parent of parents) {
    for (let i = searchFrom; i >= 0 && i >= start - 120; i--) {
      if (norm(stripMarkdownNodeMarker(lines[i])) === parent) {
        score += 1;
        searchFrom = i - 1;
        break;
      }
    }
  }
  return score;
}

function mindmapSameTextSiblingIndex(node) {
  const parent = mindmapParentNode(node);
  if (!parent || !Array.isArray(parent.children)) return -1;
  const target = norm(mindmapNodeText(node));
  if (!target) return -1;
  let index = -1;
  for (const sibling of parent.children) {
    if (norm(mindmapNodeText(sibling)) !== target) continue;
    index += 1;
    if (sibling === node) return index;
  }
  return -1;
}

function mindmapSameTextDocumentIndex(node) {
  const root = mindmapRootNode(node);
  const target = norm(mindmapNodeText(node));
  if (!root || !target) return -1;
  let index = -1;
  let found = -1;
  const visit = (current) => {
    if (!current || found >= 0) return;
    if (norm(mindmapNodeText(current)) === target) {
      index += 1;
      if (current === node) {
        found = index;
        return;
      }
    }
    for (const child of current.children || []) visit(child);
  };
  visit(root);
  return found;
}

function mindmapRootNode(node) {
  let current = node;
  const seen = new Set();
  while (current && !seen.has(current)) {
    seen.add(current);
    const parent = mindmapParentNode(current);
    if (!parent) return current;
    current = parent;
  }
  return current || null;
}

function canvasTargetFromRuntime(value, preferredKind = null) {
  if (!value) return null;
  if (Array.isArray(value)) {
    for (const item of value) {
      const target = canvasTargetFromRuntime(item, preferredKind);
      if (target) return target;
    }
    return null;
  }
  if (value instanceof Set) return canvasTargetFromRuntime([...value], preferredKind);
  if (value instanceof Map) return canvasTargetFromRuntime([...value.values()], preferredKind);

  const raw = value.node || value.edge || value.data || value;
  const id = String(raw.id || raw.nodeId || raw.edgeId || raw.fileId || value.id || value.nodeId || value.edgeId || "").trim();
  if (!id) return null;
  let kind = preferredKind;
  if (!kind) {
    if (value.edge || raw.fromNode || raw.toNode || raw.from || raw.to) kind = "edge";
    else kind = "node";
  }
  return { kind, id };
}

function canvasTargetFromElement(target) {
  const el = nodeToElement(target);
  if (!el || !el.closest) return null;
  const nodeEl = el.closest("[data-node-id], .canvas-node, .canvas-node-container, .canvas-card, .canvas-group");
  if (nodeEl) {
    const id = attrFirst(nodeEl, ["data-node-id", "data-id", "data-path"]);
    if (id) return { kind: "node", id };
  }
  const edgeEl = el.closest("[data-edge-id], .canvas-edge");
  if (edgeEl) {
    const id = attrFirst(edgeEl, ["data-edge-id", "data-id"]);
    if (id) return { kind: "edge", id };
  }
  const generic = el.closest("[data-id]");
  if (generic) {
    const id = generic.getAttribute("data-id");
    if (id) return { kind: "", id };
  }
  return null;
}

function attrFirst(el, attrs) {
  for (const attr of attrs) {
    const value = el.getAttribute(attr);
    if (value) return value;
  }
  return "";
}

function canvasHeaderLines(canvasFile, component, item) {
  const lines = [
    "<obsidian-canvas-context>",
    `canvas: ${canvasFile.path}`,
    `component: ${component}`,
    `id: ${item.id || ""}`,
  ];
  if (item.type) lines.push(`type: ${item.type}`);
  if (item.file) lines.push(`file: ${item.file}`);
  if (item.subpath) lines.push(`subpath: ${item.subpath}`);
  if (item.url) lines.push(`url: ${item.url}`);
  if (item.label) lines.push(`label: ${item.label}`);
  lines.push(`position: x=${item.x || 0} y=${item.y || 0} width=${item.width || 0} height=${item.height || 0}`);
  return lines;
}

function canvasContainedNodes(canvasData, group) {
  const nodes = Array.isArray(canvasData && canvasData.nodes) ? canvasData.nodes : [];
  return nodes.filter((node) => {
    if (!node || node.id === group.id) return false;
    return node.x >= group.x && node.y >= group.y && node.x + node.width <= group.x + group.width && node.y + node.height <= group.y + group.height;
  });
}

function canvasNodeSummary(node) {
  if (!node) return "unknown";
  let summary = "";
  if (node.type === "text") summary = excerpt(stripMarkdownNodeMarker(node.text || ""), 80);
  else if (node.type === "file") summary = node.subpath ? `${node.file}${node.subpath}` : node.file;
  else if (node.type === "link") summary = node.url;
  else if (node.type === "group") summary = node.label || "group";
  else summary = node.type || "node";
  return `${node.type || "node"} ${node.id} — ${summary || "(empty)"}`;
}

function matchScore(a, b) {
  if (!a || !b) return 0;
  if (a === b) return 1;
  const longer = a.length > b.length ? a : b;
  const shorter = a.length > b.length ? b : a;
  if (longer.includes(shorter)) return shorter.length / longer.length;
  const wa = new Set(a.split(" ").filter(Boolean));
  const wb = new Set(b.split(" ").filter(Boolean));
  const overlap = [...wa].filter((w) => wb.has(w)).length;
  return overlap / Math.max(wa.size || 1, wb.size || 1);
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function sameEditorPos(a, b) {
  return !!a && !!b && a.line === b.line && a.ch === b.ch;
}

function normalizeEditorRange(a, b) {
  if (a.line < b.line || (a.line === b.line && a.ch <= b.ch)) {
    return { from: a, to: b };
  }
  return { from: b, to: a };
}

function nodeToElement(node) {
  if (!node) return null;
  if (node instanceof Element) return node;
  return node.parentElement || null;
}

function makeId() {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

function basename(path) {
  return path.split("/").pop() || path;
}

function slugify(value) {
  return String(value || "feedback")
    .toLowerCase()
    .replace(/\.md$/i, "")
    .replace(/[^a-z0-9\u4e00-\u9fff]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80) || "feedback";
}

function yamlString(value) {
  return JSON.stringify(String(value || ""));
}

function mergeEntries(...entryLists) {
  const merged = [];
  const seen = new Set();
  for (const entries of entryLists) {
    for (const entry of entries || []) {
      if (!entry || !entry.id || seen.has(entry.id)) continue;
      seen.add(entry.id);
      merged.push(entry);
    }
  }
  return sortEntriesNewestFirst(merged);
}

function sortEntriesNewestFirst(entries) {
  return [...(entries || [])].sort((a, b) => entrySortTime(b).localeCompare(entrySortTime(a)));
}

function entrySortTime(entry) {
  return String((entry && (entry.created || entry.updated)) || "");
}

function isHeadingLine(line) {
  return /^\s{0,3}#{1,6}\s+\S/.test(line || "");
}

function headingLevel(line) {
  const match = /^(\s{0,3})(#{1,6})\s+\S/.exec(line || "");
  return match ? match[2].length : 0;
}

function findNextHeadingIndex(ranges, content, headingIndex) {
  const lines = content.split("\n");
  const currentLevel = headingLevel(lines[ranges[headingIndex].start] || "");
  if (!currentLevel) return -1;
  for (let i = headingIndex + 1; i < ranges.length; i++) {
    const line = lines[ranges[i].start] || "";
    const level = headingLevel(line);
    if (level > 0 && level <= currentLevel) return i;
  }
  return -1;
}

function isGrabNoteIgnoredElement(el) {
  if (!el || !el.matches) return true;
  return el.matches(".markdown-preview-view, .markdown-preview-section, .mod-header, .metadata-container, .frontmatter, .cm-embed-block, .modal-container, .side-dock-ribbon");
}

function excerpt(text, max) {
  const compact = String(text || "").replace(/\s+/g, " ").trim();
  if (compact.length <= max) return compact;
  return `${compact.slice(0, Math.max(0, max - 1))}…`;
}

function formatShortTime(value) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString();
}

function timestampForFile() {
  const d = new Date();
  const pad = (n, len = 2) => String(n).padStart(len, "0");
  return [
    d.getFullYear(),
    pad(d.getMonth() + 1),
    pad(d.getDate()),
    "-",
    pad(d.getHours()),
    pad(d.getMinutes()),
    pad(d.getSeconds()),
    "-",
    pad(d.getMilliseconds(), 3),
  ].join("");
}

function quoteBlock(markdown) {
  return String(markdown || "").split("\n").map((line) => `> ${line}`).join("\n");
}

export default GrabNotePlugin;

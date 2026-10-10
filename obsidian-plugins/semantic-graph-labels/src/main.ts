// Semantic Graph Labels Plugin
// Displays semantic note titles from frontmatter in graph and local graph without renaming files.

import { Plugin, TFile } from "obsidian";

type GraphLikeView = {
  getViewType?: () => string;
  renderer?: {
    nodes?: Map<string, GraphNodeLike> | GraphNodeLike[];
    onIframeLoad?: () => void;
    restart?: () => void;
  };
};

type GraphNodeLike = {
  id?: string;
  getDisplayText?: () => string;
};

type PatchedPrototype = {
  getDisplayText?: () => string;
  __semanticGraphLabelsOriginalGetDisplayText?: () => string;
  __semanticGraphLabelsPatched?: boolean;
};

const DISPLAY_KEYS = ["display_name", "displayName", "title"];
const GRAPH_VIEW_TYPES = new Set(["graph", "localgraph"]);

export default class SemanticGraphLabelsPlugin extends Plugin {
  private patchedPrototype: PatchedPrototype | null = null;
  private refreshTimer: number | null = null;
  private patchRetryTimer: number | null = null;
  private patchRetryAttempts = 0;
  private readonly maxPatchRetryAttempts = 40;

  async onload() {
    this.registerEvent(this.app.workspace.on("layout-change", () => this.tryPatchAndRefresh({ retry: true })));
    this.registerEvent(this.app.workspace.on("active-leaf-change", () => this.tryPatchAndRefresh({ retry: true })));
    this.registerEvent(this.app.metadataCache.on("resolved", () => this.scheduleRefresh()));
    this.registerEvent(this.app.metadataCache.on("changed", () => this.scheduleRefresh()));
    this.registerEvent(this.app.vault.on("rename", () => this.scheduleRefresh()));
    this.registerEvent(this.app.vault.on("delete", () => this.scheduleRefresh()));

    this.app.workspace.onLayoutReady(() => this.tryPatchAndRefresh({ retry: true }));
    this.tryPatchAndRefresh({ retry: true });
  }

  onunload() {
    if (this.refreshTimer !== null) {
      window.clearTimeout(this.refreshTimer);
      this.refreshTimer = null;
    }
    if (this.patchRetryTimer !== null) {
      window.clearTimeout(this.patchRetryTimer);
      this.patchRetryTimer = null;
    }

    if (this.patchedPrototype?.__semanticGraphLabelsPatched) {
      this.patchedPrototype.getDisplayText = this.patchedPrototype.__semanticGraphLabelsOriginalGetDisplayText;
      delete this.patchedPrototype.__semanticGraphLabelsOriginalGetDisplayText;
      delete this.patchedPrototype.__semanticGraphLabelsPatched;
    }
  }

  private tryPatchAndRefresh(options: { retry?: boolean } = {}) {
    const patched = this.patchGraphNodePrototype();
    if (patched) {
      if (this.patchRetryTimer !== null) {
        window.clearTimeout(this.patchRetryTimer);
        this.patchRetryTimer = null;
      }
      this.patchRetryAttempts = 0;
      this.scheduleRefresh();
      return;
    }

    if (options.retry) {
      this.schedulePatchRetry();
    }
  }

  private schedulePatchRetry() {
    if (this.patchRetryTimer !== null || this.patchedPrototype?.__semanticGraphLabelsPatched) {
      return;
    }
    if (this.patchRetryAttempts >= this.maxPatchRetryAttempts) {
      return;
    }

    this.patchRetryAttempts += 1;
    this.patchRetryTimer = window.setTimeout(() => {
      this.patchRetryTimer = null;
      this.tryPatchAndRefresh({ retry: true });
    }, 500);
  }

  private patchGraphNodePrototype(): boolean {
    if (this.patchedPrototype?.__semanticGraphLabelsPatched) {
      return true;
    }

    const node = this.getFirstGraphNode();
    if (!node?.getDisplayText) {
      return false;
    }

    const prototype = Object.getPrototypeOf(node) as PatchedPrototype;
    if (!prototype?.getDisplayText) {
      return false;
    }

    if (prototype.__semanticGraphLabelsPatched) {
      this.patchedPrototype = prototype;
      return true;
    }

    const plugin = this;
    const original = prototype.getDisplayText;
    prototype.__semanticGraphLabelsOriginalGetDisplayText = original;
    prototype.__semanticGraphLabelsPatched = true;
    prototype.getDisplayText = function patchedGetDisplayText(this: GraphNodeLike) {
      return plugin.resolveDisplayName(this.id) ?? original.call(this);
    };

    this.patchedPrototype = prototype;
    return true;
  }

  private getFirstGraphNode(): GraphNodeLike | null {
    for (const view of this.getGraphViews()) {
      for (const node of this.getRendererNodes(view)) {
        if (node?.getDisplayText) {
          return node;
        }
      }
    }
    return null;
  }

  private getGraphViews(): GraphLikeView[] {
    return this.app.workspace.getLeavesOfType("graph")
      .concat(this.app.workspace.getLeavesOfType("localgraph"))
      .map((leaf) => leaf.view as GraphLikeView)
      .filter((view) => GRAPH_VIEW_TYPES.has(view.getViewType?.() ?? ""));
  }

  private getRendererNodes(view: GraphLikeView): GraphNodeLike[] {
    const nodes = view.renderer?.nodes;
    if (!nodes) {
      return [];
    }
    if (nodes instanceof Map) {
      return Array.from(nodes.values());
    }
    if (Array.isArray(nodes)) {
      return nodes;
    }
    return [];
  }

  private resolveDisplayName(path: string | undefined): string | null {
    if (!path) {
      return null;
    }

    const file = this.app.vault.getAbstractFileByPath(path);
    if (!(file instanceof TFile)) {
      return null;
    }

    const cache = this.app.metadataCache.getFileCache(file);
    const frontmatter = cache?.frontmatter;
    if (!frontmatter) {
      return null;
    }

    for (const key of DISPLAY_KEYS) {
      const value = this.normalizeDisplayValue(frontmatter[key]);
      if (value) {
        return value;
      }
    }

    const aliases = frontmatter.aliases ?? frontmatter.alias;
    const alias = this.pickAlias(aliases);
    return alias;
  }

  private normalizeDisplayValue(value: unknown): string | null {
    if (typeof value !== "string") {
      return null;
    }
    const normalized = value.trim();
    return normalized.length > 0 ? normalized : null;
  }

  private pickAlias(value: unknown): string | null {
    if (Array.isArray(value)) {
      for (const item of value) {
        const alias = this.normalizeDisplayValue(item);
        if (alias && this.containsCjk(alias)) {
          return alias;
        }
      }
      for (const item of value) {
        const alias = this.normalizeDisplayValue(item);
        if (alias) {
          return alias;
        }
      }
      return null;
    }

    return this.normalizeDisplayValue(value);
  }

  private containsCjk(value: string): boolean {
    return /[\u3400-\u9fff\uf900-\ufaff]/.test(value);
  }

  private scheduleRefresh() {
    if (this.refreshTimer !== null) {
      window.clearTimeout(this.refreshTimer);
    }

    this.refreshTimer = window.setTimeout(() => {
      this.refreshTimer = null;
      this.refreshGraphViews();
    }, 100);
  }

  private refreshGraphViews() {
    for (const view of this.getGraphViews()) {
      const renderer = view.renderer;
      if (!renderer) {
        continue;
      }

      if (typeof renderer.onIframeLoad === "function") {
        renderer.onIframeLoad();
      } else if (typeof renderer.restart === "function") {
        renderer.restart();
      }
    }
  }
}

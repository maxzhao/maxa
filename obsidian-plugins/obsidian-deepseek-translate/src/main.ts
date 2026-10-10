import { App, Notice, Plugin, PluginSettingTab, Setting, TFile, WorkspaceLeaf } from "obsidian";

interface DeepSeekTranslateSettings {
  apiKey: string;
  model: string;
  targetLanguage: string;
  temperature: number;
  allowedExtensions: string;
}

interface SourceInfo {
  file: TFile;
  text: string;
  relativePath: string;
  cachePath: string;
  key: string;
}

const DEFAULT_SETTINGS: DeepSeekTranslateSettings = {
  apiKey: "",
  model: "deepseek-v4-flash",
  targetLanguage: "简体中文",
  temperature: 0,
  allowedExtensions: "md, markdown, txt, rst, adoc",
};

const RESULT_LEAF_STATE_KEY = "maxa-deepseek-translate-result";

function trim(value: string): string {
  return String(value || "").replace(/^\s+/, "").replace(/\s+$/, "");
}

function normalizePath(path: string): string {
  return String(path || "").replace(/\\/g, "/").replace(/^\/+/, "").replace(/\/+/g, "/");
}

function splitLines(text: string): string[] {
  if (text === "") {
    return [];
  }
  return text.split("\n");
}

function extension(path: string): string {
  const match = String(path || "").match(/\.([^./\\]+)$/);
  return match ? match[1].toLowerCase() : "";
}

function parseAllowedExtensions(value: string): string[] {
  return String(value || "")
    .split(/[\n,]/)
    .map((item) => item.trim().toLowerCase().replace(/^\./, ""))
    .filter(Boolean);
}

function allowedExtension(path: string, allowedExtensions: string[]): boolean {
  const ext = extension(path);
  return allowedExtensions.some((allowed) => ext === allowed);
}

export function normalizeSemanticContent(text: string): string {
  let normalized = String(text || "").replace(/\r\n/g, "\n").replace(/\r/g, "\n");
  const lines = splitLines(normalized).map((line) => line.replace(/[ \t]+$/g, ""));
  normalized = trim(lines.join("\n"));
  while (true) {
    const nextText = normalized.replace(/\n\n\n+/g, "\n\n");
    if (nextText === normalized) {
      break;
    }
    normalized = nextText;
  }
  return normalized;
}

async function sha256Hex(text: string): Promise<string> {
  const data = new TextEncoder().encode(text);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

export async function semanticHash(text: string): Promise<string> {
  return sha256Hex(normalizeSemanticContent(text));
}

export async function cacheKey(relativePath: string, sourceSemanticHash: string, targetLanguage: string): Promise<string> {
  return sha256Hex([relativePath, sourceSemanticHash, targetLanguage].join("\n"));
}

function pathStartsWith(path: string, prefix: string): boolean {
  const normalizedPath = normalizePath(path);
  const normalizedPrefix = normalizePath(prefix).replace(/\/+$/, "");
  return normalizedPath === normalizedPrefix || normalizedPath.startsWith(`${normalizedPrefix}/`);
}

function resolveCompatibilityPaths(
  filePath: string,
  hasProjectMaxaDirectory: boolean
): { relativePath: string; cacheDir: string } | null {
  const normalized = normalizePath(filePath);
  if (!normalized) {
    return null;
  }

  if (hasProjectMaxaDirectory && (normalized === ".maxa" || pathStartsWith(normalized, ".maxa/translate-cache"))) {
    throw new Error("缓存目录中的翻译结果不能作为源文档翻译");
  }

  if (!hasProjectMaxaDirectory && pathStartsWith(normalized, "translate-cache")) {
    throw new Error("缓存目录中的翻译结果不能作为源文档翻译");
  }

  if (hasProjectMaxaDirectory) {
    return {
      relativePath: normalized,
      cacheDir: ".maxa/translate-cache",
    };
  }

  return {
    relativePath: `.maxa/${normalized}`,
    cacheDir: "translate-cache",
  };
}

function translationMessages(source: SourceInfo, targetLanguage: string) {
  return [
    {
      role: "system",
      content: [
        "You are a translation engine for project documents.",
        `Translate the provided document into ${targetLanguage}.`,
        "Return only the translated document.",
        "Do not add explanations, summaries, prefaces, or code fences around the whole answer.",
        "Preserve Markdown structure, headings, lists, tables, links, inline code, and fenced code blocks.",
        "Do not translate code identifiers, URLs, file paths, command names, or markup syntax.",
      ].join("\n"),
    },
    {
      role: "user",
      content: [`Target language: ${targetLanguage}`, `Source path: ${source.relativePath}`, "", "Document:", source.text].join("\n"),
    },
  ];
}

function extractDeepSeekTranslation(payload: unknown): string | null {
  const root = payload as { choices?: Array<{ message?: { content?: unknown } }> };
  const content = root?.choices?.[0]?.message?.content;
  if (typeof content !== "string") {
    return null;
  }
  const translated = trim(content);
  return translated === "" ? null : translated;
}

export default class DeepSeekTranslatePlugin extends Plugin {
  settings: DeepSeekTranslateSettings;
  private resultLeaf: WorkspaceLeaf | null = null;
  private activeRequests = new Map<string, Promise<void>>();

  async onload() {
    await this.loadSettings();

    this.addCommand({
      id: "translate-current-document",
      name: "Translate current document with DeepSeek",
      callback: () => {
        void this.translateCurrentDocument();
      },
    });

    this.registerEvent(
      this.app.workspace.on("file-menu", (menu, file) => {
        if (!(file instanceof TFile)) {
          return;
        }
        menu.addItem((item) => {
          item
            .setTitle("Translate document with DeepSeek")
            .setIcon("languages")
            .onClick(() => {
              void this.translateCurrentDocument(file);
            });
        });
      })
    );

    this.addSettingTab(new DeepSeekTranslateSettingTab(this.app, this));
  }

  async loadSettings() {
    this.settings = Object.assign({}, DEFAULT_SETTINGS, await this.loadData());
  }

  async saveSettings() {
    await this.saveData(this.settings);
  }

  private async translateCurrentDocument(fileOverride?: TFile): Promise<void> {
    let source: SourceInfo;
    try {
      source = await this.resolveSource(fileOverride);
    } catch (error) {
      new Notice(error instanceof Error ? error.message : String(error));
      return;
    }

    if (this.activeRequests.has(source.key)) {
      new Notice(`正在翻译: ${source.relativePath}`);
      return;
    }

    const running = this.translateResolvedSource(source)
      .catch((error) => {
        new Notice(error instanceof Error ? error.message : String(error));
      })
      .finally(() => {
        this.activeRequests.delete(source.key);
      });
    this.activeRequests.set(source.key, running);
    await running;
  }

  private async resolveSource(fileOverride?: TFile): Promise<SourceInfo> {
    const file = fileOverride || this.app.workspace.getActiveFile();
    if (!file) {
      throw new Error("当前没有可翻译的活动文件");
    }

    const allowedExtensions = parseAllowedExtensions(this.settings.allowedExtensions);
    if (!allowedExtension(file.path, allowedExtensions)) {
      throw new Error(`当前文件后缀不在允许翻译列表中: .${extension(file.path)}`);
    }

    const hasProjectMaxaDirectory = this.app.vault.getAbstractFileByPath(".maxa") !== null;
    const paths = resolveCompatibilityPaths(file.path, hasProjectMaxaDirectory);
    if (!paths) {
      throw new Error("无法解析当前文件的翻译缓存路径");
    }

    const text = await this.app.vault.read(file);
    const sourceSemanticHash = await semanticHash(text);
    const key = await cacheKey(paths.relativePath, sourceSemanticHash, this.settings.targetLanguage);

    return {
      file,
      text,
      relativePath: paths.relativePath,
      cachePath: `${paths.cacheDir}/${key}.md`,
      key,
    };
  }

  private async translateResolvedSource(source: SourceInfo): Promise<void> {
    const cached = this.app.vault.getAbstractFileByPath(source.cachePath);
    if (cached instanceof TFile) {
      await this.openResultFile(cached);
      new Notice(`已复用翻译缓存: ${source.relativePath}`);
      return;
    }
    if (cached) {
      new Notice(`翻译缓存路径不是文件: ${source.cachePath}`);
      return;
    }

    if (!this.settings.apiKey.trim()) {
      new Notice("请先在插件设置中配置 DeepSeek API key");
      return;
    }

    new Notice(`正在翻译: ${source.relativePath}`);
    const translation = await this.requestTranslation(source);
    const existingAfterRequest = this.app.vault.getAbstractFileByPath(source.cachePath);
    if (existingAfterRequest instanceof TFile) {
      await this.openResultFile(existingAfterRequest);
      new Notice(`已复用同步到达的翻译缓存: ${source.relativePath}`);
      return;
    }
    if (existingAfterRequest) {
      new Notice(`翻译缓存路径不是文件: ${source.cachePath}`);
      return;
    }

    await this.ensureFolder(source.cachePath.split("/").slice(0, -1).join("/"));
    const created = await this.app.vault.create(source.cachePath, translation);
    await this.openResultFile(created);
    new Notice(`翻译完成并已写入缓存: ${source.relativePath}`);
  }

  private async requestTranslation(source: SourceInfo): Promise<string> {
    let response: Response;
    try {
      response = await fetch("https://api.deepseek.com/chat/completions", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${this.settings.apiKey.trim()}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: this.settings.model.trim(),
          temperature: this.settings.temperature,
          messages: translationMessages(source, this.settings.targetLanguage),
        }),
      });
    } catch (error) {
      throw new Error(`翻译请求失败: ${error instanceof Error ? error.message : String(error)}`);
    }

    if (!response.ok) {
      const body = await response.text().catch(() => "");
      throw new Error(`翻译请求失败: HTTP ${response.status}${body ? ` ${body.slice(0, 500)}` : ""}`);
    }

    const payload = await response.json().catch((error) => {
      throw new Error(`翻译响应不是有效 JSON: ${error instanceof Error ? error.message : String(error)}`);
    });
    const translation = extractDeepSeekTranslation(payload);
    if (!translation) {
      throw new Error("翻译失败：DeepSeek 未返回可用译文");
    }
    return translation;
  }

  private async ensureFolder(path: string): Promise<void> {
    const normalized = normalizePath(path);
    if (!normalized) {
      return;
    }
    const parts = normalized.split("/").filter(Boolean);
    let current = "";
    for (const part of parts) {
      current = current ? `${current}/${part}` : part;
      if (!this.app.vault.getAbstractFileByPath(current)) {
        await this.app.vault.createFolder(current);
      }
    }
  }

  private async openResultFile(file: TFile): Promise<void> {
    let leaf = this.getResultLeaf();
    if (!leaf) {
      leaf = this.app.workspace.getLeaf("split", "vertical");
      this.resultLeaf = leaf;
    }
    await leaf.openFile(file, { active: true });
    this.markResultLeaf(leaf);
    this.app.workspace.setActiveLeaf(leaf, { focus: true });
    await this.app.workspace.revealLeaf(leaf);
  }

  private getResultLeaf(): WorkspaceLeaf | null {
    if (this.resultLeaf) {
      return this.resultLeaf;
    }

    let found: WorkspaceLeaf | null = null;
    this.app.workspace.iterateAllLeaves((leaf) => {
      if (found) {
        return;
      }
      const state = leaf.getViewState();
      if ((state.state as Record<string, unknown> | undefined)?.[RESULT_LEAF_STATE_KEY]) {
        found = leaf;
      }
    });
    this.resultLeaf = found;
    return found;
  }

  private markResultLeaf(leaf: WorkspaceLeaf): void {
    const state = leaf.getViewState();
    leaf.setViewState({
      ...state,
      state: {
        ...(state.state || {}),
        [RESULT_LEAF_STATE_KEY]: true,
      },
    });
  }
}

class DeepSeekTranslateSettingTab extends PluginSettingTab {
  plugin: DeepSeekTranslatePlugin;

  constructor(app: App, plugin: DeepSeekTranslatePlugin) {
    super(app, plugin);
    this.plugin = plugin;
  }

  display(): void {
    const { containerEl } = this;
    containerEl.empty();

    containerEl.createEl("h2", { text: "DeepSeek Translate" });

    new Setting(containerEl)
      .setName("DeepSeek API key")
      .setDesc("Stored in this plugin's local Obsidian data.json. Do not sync plugin data containing secrets.")
      .addText((text) => {
        text.inputEl.type = "password";
        text
          .setPlaceholder("sk-...")
          .setValue(this.plugin.settings.apiKey)
          .onChange(async (value) => {
            this.plugin.settings.apiKey = value;
            await this.plugin.saveSettings();
          });
      });

    new Setting(containerEl)
      .setName("Model")
      .setDesc("DeepSeek model id. Defaults to deepseek-v4-flash for Neovim parity.")
      .addText((text) =>
        text.setValue(this.plugin.settings.model).onChange(async (value) => {
          this.plugin.settings.model = value.trim() || DEFAULT_SETTINGS.model;
          await this.plugin.saveSettings();
        })
      );

    new Setting(containerEl)
      .setName("Target language")
      .setDesc("Part of the cache key. Changing this creates distinct cache files.")
      .addText((text) =>
        text.setValue(this.plugin.settings.targetLanguage).onChange(async (value) => {
          this.plugin.settings.targetLanguage = value.trim() || DEFAULT_SETTINGS.targetLanguage;
          await this.plugin.saveSettings();
        })
      );

    new Setting(containerEl)
      .setName("Temperature")
      .setDesc("DeepSeek sampling temperature. Default: 0.")
      .addText((text) =>
        text.setValue(String(this.plugin.settings.temperature)).onChange(async (value) => {
          const parsed = Number(value);
          this.plugin.settings.temperature = Number.isFinite(parsed) ? parsed : DEFAULT_SETTINGS.temperature;
          await this.plugin.saveSettings();
        })
      );

    new Setting(containerEl)
      .setName("Allowed extensions")
      .setDesc("Comma-separated extension list. Selection translation is intentionally unsupported; the full active document is translated.")
      .addTextArea((text) =>
        text.setValue(this.plugin.settings.allowedExtensions).onChange(async (value) => {
          this.plugin.settings.allowedExtensions = value;
          await this.plugin.saveSettings();
        })
      );
  }
}

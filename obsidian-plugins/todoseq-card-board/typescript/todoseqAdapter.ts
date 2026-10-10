import { App, TFile } from 'obsidian';
import { TaskParser } from './todoseq/parser/task-parser';
import { KeywordManager, KeywordSettings } from './todoseq/utils/keyword-manager';
import { getDefaultCoefficients, UrgencyCoefficients } from './todoseq/utils/task-urgency';
import { Task, DateRepeatInfo } from './todoseq/types/task';

export const TODOSEQ_PLUGIN_ID = 'todoseq';

export type TodoSeqRuntimeSettings = KeywordSettings & {
  urgencyCoefficients?: UrgencyCoefficients;
  includeCalloutBlocks?: boolean;
  includeCodeBlocks?: boolean;
  includeCommentBlocks?: boolean;
  languageCommentSupport?: boolean;
};

export type TodoSeqRuntime = {
  plugin: unknown;
  settings: TodoSeqRuntimeSettings;
  source: 'plugin-instance' | 'data-json';
};

export type TodoSeqAdapterResult =
  | { ok: true; adapter: TodoSeqAdapter; runtime: TodoSeqRuntime }
  | { ok: false; error: string };

export type TodoSeqBoardTask = {
  path: string;
  line: number;
  rawText: string;
  text: string;
  displayText: string;
  state: string;
  completed: boolean;
  priority: 'high' | 'med' | 'low' | null;
  scheduledDate: Date | null;
  deadlineDate: Date | null;
  closedDate: Date | null;
  scheduledDateRepeat: DateRepeatInfo | null;
  deadlineDateRepeat: DateRepeatInfo | null;
  subtaskCount: number;
  subtaskCompletedCount: number;
  urgency: number | null;
  tags: string[];
  isDailyNote: boolean;
  dailyNoteDate: Date | null;
  embedReference?: string;
  footnoteReference?: string;
  quoteNestingLevel: number;
};

export class TodoSeqDependencyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'TodoSeqDependencyError';
  }
}

export class TodoSeqAdapter {
  readonly keywordManager: KeywordManager;
  readonly parser: TaskParser;

  constructor(
    private readonly app: App | null,
    private readonly settings: TodoSeqRuntimeSettings,
  ) {
    this.keywordManager = new KeywordManager(settings);
    this.parser = TaskParser.create(
      this.keywordManager,
      app,
      settings.urgencyCoefficients ?? getDefaultCoefficients(),
      {
        includeCalloutBlocks: settings.includeCalloutBlocks,
        includeCodeBlocks: settings.includeCodeBlocks,
        includeCommentBlocks: settings.includeCommentBlocks,
        languageCommentSupport: settings.languageCommentSupport,
      },
    );
  }

  static async createFromObsidian(app: App): Promise<TodoSeqAdapterResult> {
    const runtime = await resolveTodoSeqRuntime(app);
    if (!runtime.ok) {
      const message = 'error' in runtime ? runtime.error : 'TODOseq runtime unavailable.';
      return { ok: false, error: message };
    }

    try {
      const adapter = new TodoSeqAdapter(app, runtime.runtime.settings);
      return { ok: true, adapter, runtime: runtime.runtime };
    } catch (error) {
      return {
        ok: false,
        error: `TODOseq settings are not readable by TODOseq Card Board: ${formatError(error)}`,
      };
    }
  }

  scanMarkdown(content: string, path: string, file?: TFile): TodoSeqBoardTask[] {
    if (!this.parser.hasAnyKeyword(content)) {
      return [];
    }

    return this.parser
      .parseFile(content, path, file)
      .filter((task) => !this.keywordManager.isArchived(task.state))
      .map(toTodoSeqBoardTask);
  }
}

export async function resolveTodoSeqRuntime(
  app: App,
): Promise<{ ok: true; runtime: TodoSeqRuntime } | { ok: false; error: string }> {
  const plugins = (app as any).plugins;
  const plugin = plugins?.getPlugin?.(TODOSEQ_PLUGIN_ID);

  if (!plugin) {
    return {
      ok: false,
      error:
        'TODOseq Card Board requires the TODOseq plugin to be installed and enabled. Enable the “todoseq” plugin and reopen this view.',
    };
  }

  const instanceSettings = normalizeTodoSeqSettings(plugin.settings ?? plugin.data ?? plugin.options);
  if (instanceSettings) {
    return {
      ok: true,
      runtime: { plugin, settings: instanceSettings, source: 'plugin-instance' },
    };
  }

  const dataPath = `${app.vault.configDir}/plugins/${TODOSEQ_PLUGIN_ID}/data.json`;
  try {
    const data = await app.vault.adapter.read(dataPath);
    const parsed = JSON.parse(data);
    const dataSettings = normalizeTodoSeqSettings(parsed);
    if (!dataSettings) {
      return {
        ok: false,
        error:
          'TODOseq Card Board found TODOseq, but its settings could not be read from the plugin instance or data.json.',
      };
    }
    return {
      ok: true,
      runtime: { plugin, settings: dataSettings, source: 'data-json' },
    };
  } catch (error) {
    return {
      ok: false,
      error: `TODOseq Card Board found TODOseq, but could not read TODOseq settings (${formatError(error)}).`,
    };
  }
}

export function normalizeTodoSeqSettings(value: unknown): TodoSeqRuntimeSettings | null {
  if (!value || typeof value !== 'object') {
    return null;
  }

  const raw = value as Record<string, unknown>;
  const nested = raw.settings && typeof raw.settings === 'object'
    ? (raw.settings as Record<string, unknown>)
    : raw;

  return {
    additionalInactiveKeywords: asStringArray(nested.additionalInactiveKeywords),
    additionalActiveKeywords: asStringArray(nested.additionalActiveKeywords),
    additionalWaitingKeywords: asStringArray(nested.additionalWaitingKeywords),
    additionalCompletedKeywords: asStringArray(nested.additionalCompletedKeywords),
    additionalArchivedKeywords: asStringArray(nested.additionalArchivedKeywords),
    useExtendedCheckboxStyles: asBoolean(nested.useExtendedCheckboxStyles),
    urgencyCoefficients: asUrgencyCoefficients(nested.urgencyCoefficients),
    includeCalloutBlocks: asBoolean(nested.includeCalloutBlocks),
    includeCodeBlocks: asBoolean(nested.includeCodeBlocks),
    includeCommentBlocks: asBoolean(nested.includeCommentBlocks),
    languageCommentSupport: asBoolean(nested.languageCommentSupport),
  };
}

export function toTodoSeqBoardTask(task: Task): TodoSeqBoardTask {
  return {
    path: task.path,
    line: task.line,
    rawText: task.rawText,
    text: task.text,
    displayText: todoSeqDisplayText(task.text, task.rawText),
    state: task.state,
    completed: task.completed,
    priority: task.priority,
    scheduledDate: task.scheduledDate,
    deadlineDate: task.deadlineDate,
    closedDate: task.closedDate,
    scheduledDateRepeat: task.scheduledDateRepeat,
    deadlineDateRepeat: task.deadlineDateRepeat,
    subtaskCount: task.subtaskCount,
    subtaskCompletedCount: task.subtaskCompletedCount,
    urgency: task.urgency,
    tags: task.tags ?? [],
    isDailyNote: task.isDailyNote,
    dailyNoteDate: task.dailyNoteDate,
    embedReference: task.embedReference,
    footnoteReference: task.footnoteReference,
    quoteNestingLevel: task.quoteNestingLevel ?? 0,
  };
}

export function todoSeqDisplayText(text: string, rawText = ''): string {
  const source = text.trim().length > 0 ? text : rawText;
  const firstLine = source.split(/\r?\n/).find((line) => line.trim().length > 0) ?? '';
  const cleaned = cleanTodoSeqTaskDisplayText(firstLine);

  return cleaned.length > 0 ? cleaned : '(Untitled TODOseq task)';
}

export function cleanTodoSeqTaskDisplayText(value: string): string {
  return value
    .replace(/^\s*(?:[-+*]|\d+[.)])\s+/, '')
    .replace(/^\s*\[[^\]]\]\s+/, '')
    .replace(/^\s*[A-Z][A-Z0-9_-]*\s+/, '')
    .replace(/(^|[ \t])\[#([ABC])\](?=$|[ \t])/g, ' ')
    .replace(/@completed\([^)]*\)/g, ' ')
    .replace(/\[[#A-Z]\]/g, ' ')
    .replace(/(?:^|\s)#[A-Za-z0-9_/-]+/gu, ' ')
    .replace(/(?:^|\s)\^[A-Za-z0-9_-]+(?=\s*$)/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function asStringArray(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) {
    return undefined;
  }
  return value.filter((item): item is string => typeof item === 'string');
}

function asBoolean(value: unknown): boolean | undefined {
  return typeof value === 'boolean' ? value : undefined;
}

function asUrgencyCoefficients(value: unknown): UrgencyCoefficients | undefined {
  if (!value || typeof value !== 'object') {
    return undefined;
  }
  return value as UrgencyCoefficients;
}

function formatError(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  return String(error);
}

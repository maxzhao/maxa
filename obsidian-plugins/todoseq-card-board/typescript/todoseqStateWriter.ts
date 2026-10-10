import { App, MarkdownView, Notice, TFile } from 'obsidian';
import { BoardColumn, TodoSeqKeywordGroup } from './boardDomain';
import { TodoSeqAdapter, TodoSeqBoardTask } from './todoseqAdapter';
import { DateRepeatInfo, Task } from './todoseq/types/task';
import { TaskWriter, TaskWriterPluginHost } from './todoseq/services/task-writer';
import { TaskStateTransitionManager } from './todoseq/services/task-state-transition-manager';
import { StateTransitionSettings } from './todoseq/settings/settings-types';
import { findDateLine, getDateLineIndent, getTaskIndent } from './todoseq/utils/task-line-utils';

export const TODOSEQ_CONFLICT_MESSAGE = '任务已变化，请刷新后重试';

export type TodoSeqPriority = 'high' | 'med' | 'low' | null;

export type TodoSeqStateWriteRequest = {
  task: TodoSeqBoardTask;
  targetColumn: BoardColumn;
  forceVaultApi?: boolean;
};

export type TodoSeqStateUpdateRequest = {
  task: TodoSeqBoardTask;
  targetColumn?: BoardColumn;
  targetKeyword?: string;
  forceVaultApi?: boolean;
};

export type TodoSeqPriorityUpdateRequest = {
  task: TodoSeqBoardTask;
  priority: TodoSeqPriority;
  forceVaultApi?: boolean;
};

export type TodoSeqDateUpdateRequest = {
  task: TodoSeqBoardTask;
  date: Date | null;
  repeat?: DateRepeatInfo | null;
  forceVaultApi?: boolean;
};

export type TodoSeqTagsUpdateRequest = {
  task: TodoSeqBoardTask;
  tags?: string[];
  addTags?: string[];
  removeTags?: string[];
  forceVaultApi?: boolean;
};

export type TodoSeqTaskPatch = {
  state?: string | { targetColumn?: BoardColumn; targetKeyword?: string };
  priority?: TodoSeqPriority;
  scheduledDate?: Date | null;
  scheduledDateRepeat?: DateRepeatInfo | null;
  text?: string;
  deadlineDate?: Date | null;
  deadlineDateRepeat?: DateRepeatInfo | null;
  tags?: string[];
  addTags?: string[];
  removeTags?: string[];
  forceVaultApi?: boolean;
};

export type TodoSeqTaskWriteResult =
  | { ok: true; task: TodoSeqBoardTask; previousId: string; taskItemId: string }
  | { ok: false; error: string; conflict?: boolean };

export type TodoSeqStateWriteResult = TodoSeqTaskWriteResult;

export type TodoSeqStateWriterHost = TaskWriterPluginHost & {
  settings?: TaskWriterPluginHost['settings'] & {
    stateTransitions?: StateTransitionSettings;
  };
};

type ActiveEditor = {
  getLine(line: number): string;
  lineCount?: () => number;
  replaceRange?: (replacement: string, from: { line: number; ch: number }, to?: { line: number; ch: number }) => void;
  getCursor?: () => { line: number; ch: number };
  setCursor?: (position: { line: number; ch: number }) => void;
};

type PreparedTaskContext = {
  ok: true;
  file: TFile;
  task: TodoSeqBoardTask;
  writerTask: Task;
  currentLine: string;
};

const GROUP_DEFAULTS: Record<TodoSeqKeywordGroup, string> = {
  inactive: 'TODO',
  active: 'DOING',
  waiting: 'WAIT',
  completed: 'DONE',
  archived: 'ARCHIVED',
};

const GROUP_TO_KEYWORD_GROUP: Record<TodoSeqKeywordGroup, 'inactiveKeywords' | 'activeKeywords' | 'waitingKeywords' | 'completedKeywords' | 'archivedKeywords'> = {
  inactive: 'inactiveKeywords',
  active: 'activeKeywords',
  waiting: 'waitingKeywords',
  completed: 'completedKeywords',
  archived: 'archivedKeywords',
};

const PRIORITY_TOKEN_BY_VALUE: Record<Exclude<TodoSeqPriority, null>, string> = {
  high: '[#A]',
  med: '[#B]',
  low: '[#C]',
};

const PRIORITY_TOKEN_REGEX = /(^|[ \t])\[#([ABC])\](?=$|[ \t])/;
const SIMPLE_TAG_REGEX = /(?<![\w/:?#[\]])#([A-Za-z0-9_/-]+)/gu;

export class TodoSeqTaskEditorService {
  private readonly writer: TaskWriter;
  private readonly transitionManager: TaskStateTransitionManager;

  constructor(
    private readonly app: App,
    private readonly adapter: TodoSeqAdapter,
    private readonly host: TodoSeqStateWriterHost,
  ) {
    this.writer = new TaskWriter(host, adapter.keywordManager);
    this.transitionManager = new TaskStateTransitionManager(
      adapter.keywordManager,
      host.settings?.stateTransitions,
    );
  }

  resolveTargetKeyword(column: BoardColumn): string {
    if (column.writeTarget?.property === 'state' || column.writeTarget?.property === 'keywordGroup') {
      return normalizeKeyword(column.writeTarget.keyword);
    }

    if (column.kind === 'state' || column.type === 'keyword') {
      return normalizeKeyword(column.defaultKeyword ?? column.keywords[0] ?? '');
    }

    if (column.kind === 'keywordGroup' || column.type === 'group') {
      const group = column.group ?? column.match?.group;
      if (!group) {
        return normalizeKeyword(column.defaultKeyword ?? column.keywords[0] ?? 'TODO');
      }
      const configured = normalizeKeyword(column.defaultKeyword ?? '');
      if (configured) return configured;

      const preferred = GROUP_DEFAULTS[group];
      const keywords = this.adapter.keywordManager.getKeywordsForGroup(GROUP_TO_KEYWORD_GROUP[group]);
      return keywords.includes(preferred) ? preferred : keywords[0] ?? preferred;
    }

    return normalizeKeyword(column.defaultKeyword ?? column.keywords[0] ?? '');
  }

  async updateTaskState(request: TodoSeqStateWriteRequest): Promise<TodoSeqStateWriteResult> {
    return this.updateState({
      task: request.task,
      targetColumn: request.targetColumn,
      forceVaultApi: request.forceVaultApi,
    });
  }

  async updateState(request: TodoSeqStateUpdateRequest): Promise<TodoSeqTaskWriteResult> {
    const targetKeyword = normalizeKeyword(
      request.targetKeyword ?? (request.targetColumn ? this.resolveTargetKeyword(request.targetColumn) : ''),
    );
    if (!targetKeyword) {
      return { ok: false, error: '目标列没有可写回的 TODOseq 状态 keyword。' };
    }

    if (!this.adapter.keywordManager.isKnownKeyword(targetKeyword)) {
      return { ok: false, error: `未知 TODOseq 状态 keyword: ${targetKeyword}` };
    }

    const prepared = await this.prepareTaskContext(request.task);
    if (isFailure(prepared)) return failure(prepared);

    if (!this.transitionManager.canTransition(prepared.writerTask.state) && !this.adapter.keywordManager.isArchived(targetKeyword)) {
      return { ok: false, error: `状态 ${prepared.writerTask.state} 不能转换到 ${targetKeyword}` };
    }

    const updatedTask = await this.writer.updateTaskState(prepared.writerTask, targetKeyword, request.forceVaultApi ?? false);
    const refreshed = await this.refreshTaskAtLine(prepared.file, updatedTask.path, updatedTask.line);
    if (!refreshed) {
      return { ok: false, error: '状态已写回，但刷新任务失败，请刷新看板。' };
    }

    return this.success(request.task, refreshed);
  }

  async updatePriority(request: TodoSeqPriorityUpdateRequest): Promise<TodoSeqTaskWriteResult> {
    const prepared = await this.prepareTaskContext(request.task);
    if (isFailure(prepared)) return failure(prepared);

    const newLine = setPriorityOnLine(prepared.currentLine, prepared.writerTask, request.priority);
    const writeResult = await this.runWrite(() =>
      this.replaceTaskLine(prepared.file, prepared.writerTask, prepared.task, newLine, request.forceVaultApi ?? false),
    );
    if (isWriteFailure(writeResult)) return writeResult;

    const refreshed = await this.refreshTaskAtLine(prepared.file, prepared.task.path, prepared.task.line);
    if (!refreshed) {
      return { ok: false, error: '优先级已写回，但刷新任务失败，请刷新看板。' };
    }
    return this.success(request.task, refreshed);
  }


  async updateText(request: { task: TodoSeqBoardTask; text: string; forceVaultApi?: boolean }): Promise<TodoSeqTaskWriteResult> {
    const prepared = await this.prepareTaskContext(request.task);
    if (isFailure(prepared)) return failure(prepared);

    const text = request.text.trim();
    if (!text) {
      return { ok: false, error: 'Text cannot be empty.' };
    }

    const newLine = setTextOnLine(prepared.currentLine, prepared.writerTask, text);
    const writeResult = await this.runWrite(() =>
      this.replaceTaskLine(prepared.file, prepared.writerTask, prepared.task, newLine, request.forceVaultApi ?? false),
    );
    if (isWriteFailure(writeResult)) return writeResult;

    const refreshed = await this.refreshTaskAtLine(prepared.file, prepared.task.path, prepared.task.line);
    if (!refreshed) {
      return { ok: false, error: '文本已写回，但刷新任务失败，请刷新看板。' };
    }
    return this.success(request.task, refreshed);
  }

  async updateScheduledDate(request: TodoSeqDateUpdateRequest): Promise<TodoSeqTaskWriteResult> {
    return this.updateDateLine('SCHEDULED', request);
  }

  async updateDeadlineDate(request: TodoSeqDateUpdateRequest): Promise<TodoSeqTaskWriteResult> {
    return this.updateDateLine('DEADLINE', request);
  }

  async updateTags(request: TodoSeqTagsUpdateRequest): Promise<TodoSeqTaskWriteResult> {
    const prepared = await this.prepareTaskContext(request.task);
    if (isFailure(prepared)) return failure(prepared);

    const currentTags = uniqueTags(prepared.task.tags ?? []);
    const desiredTags = request.tags !== undefined
      ? uniqueTags(request.tags)
      : uniqueTags([
          ...currentTags,
          ...normalizeTags(request.addTags ?? []),
        ]).filter((tag) => !normalizeTags(request.removeTags ?? []).includes(tag));

    const newLine = setTagsOnLine(prepared.currentLine, prepared.writerTask, desiredTags);
    const writeResult = await this.runWrite(() =>
      this.replaceTaskLine(prepared.file, prepared.writerTask, prepared.task, newLine, request.forceVaultApi ?? false),
    );
    if (isWriteFailure(writeResult)) return writeResult;

    const refreshed = await this.refreshTaskAtLine(prepared.file, prepared.task.path, prepared.task.line);
    if (!refreshed) {
      return { ok: false, error: '标签已写回，但刷新任务失败，请刷新看板。' };
    }
    return this.success(request.task, refreshed);
  }

  async applyPatch(task: TodoSeqBoardTask, patch: TodoSeqTaskPatch): Promise<TodoSeqTaskWriteResult> {
    let current = task;
    const forceVaultApi = patch.forceVaultApi;

    if (patch.state !== undefined) {
      const result = typeof patch.state === 'string'
        ? await this.updateState({ task: current, targetKeyword: patch.state, forceVaultApi })
        : await this.updateState({
            task: current,
            targetColumn: patch.state.targetColumn,
            targetKeyword: patch.state.targetKeyword,
            forceVaultApi,
          });
      if (!result.ok) return result;
      current = result.task;
    }

    if (Object.prototype.hasOwnProperty.call(patch, 'priority')) {
      const result = await this.updatePriority({ task: current, priority: patch.priority ?? null, forceVaultApi });
      if (!result.ok) return result;
      current = result.task;
    }

    if (Object.prototype.hasOwnProperty.call(patch, 'text')) {
      const result = await this.updateText({ task: current, text: patch.text ?? '', forceVaultApi });
      if (!result.ok) return result;
      current = result.task;
    }

    if (Object.prototype.hasOwnProperty.call(patch, 'scheduledDate')) {
      const result = await this.updateScheduledDate({
        task: current,
        date: patch.scheduledDate ?? null,
        repeat: patch.scheduledDateRepeat,
        forceVaultApi,
      });
      if (!result.ok) return result;
      current = result.task;
    }

    if (Object.prototype.hasOwnProperty.call(patch, 'deadlineDate')) {
      const result = await this.updateDeadlineDate({
        task: current,
        date: patch.deadlineDate ?? null,
        repeat: patch.deadlineDateRepeat,
        forceVaultApi,
      });
      if (!result.ok) return result;
      current = result.task;
    }

    if (patch.tags !== undefined || patch.addTags !== undefined || patch.removeTags !== undefined) {
      const result = await this.updateTags({
        task: current,
        tags: patch.tags,
        addTags: patch.addTags,
        removeTags: patch.removeTags,
        forceVaultApi,
      });
      if (!result.ok) return result;
      current = result.task;
    }

    return this.success(task, current);
  }

  private async updateDateLine(dateType: 'SCHEDULED' | 'DEADLINE', request: TodoSeqDateUpdateRequest): Promise<TodoSeqTaskWriteResult> {
    const prepared = await this.prepareTaskContext(request.task);
    if (isFailure(prepared)) return failure(prepared);

    const writeResult = await this.runWrite(() =>
      this.applyDateEdit(
        prepared.file,
        prepared.writerTask,
        prepared.task,
        dateType,
        request.date,
        request.repeat ?? null,
        request.forceVaultApi ?? false,
      ),
    );
    if (isWriteFailure(writeResult)) return writeResult;

    const refreshed = await this.refreshTaskAtLine(prepared.file, prepared.task.path, prepared.task.line);
    if (!refreshed) {
      return { ok: false, error: `${dateType} 已写回，但刷新任务失败，请刷新看板。` };
    }
    return this.success(request.task, refreshed);
  }

  private async prepareTaskContext(task: TodoSeqBoardTask): Promise<PreparedTaskContext | { ok: false; error: string; conflict?: boolean }> {
    const file = this.app.vault.getAbstractFileByPath(task.path);
    if (!(file instanceof TFile)) {
      return { ok: false, error: `找不到任务文件: ${task.path}` };
    }

    const currentLine = await this.readCurrentLine(file, task.line);
    if (!this.matchesExpectedTask(currentLine, task)) {
      new Notice(TODOSEQ_CONFLICT_MESSAGE);
      return { ok: false, error: TODOSEQ_CONFLICT_MESSAGE, conflict: true };
    }

    const refreshed = await this.refreshTaskAtLine(file, task.path, task.line);
    const currentTask = refreshed ?? { ...task, rawText: currentLine };
    const parsedCurrent = this.adapter.parser.parseLineAsTask(currentLine, task.line, task.path);
    if (!parsedCurrent) {
      new Notice(TODOSEQ_CONFLICT_MESSAGE);
      return { ok: false, error: TODOSEQ_CONFLICT_MESSAGE, conflict: true };
    }

    const writerTask: Task = {
      ...parsedCurrent,
      path: currentTask.path,
      line: currentTask.line,
      scheduledDate: currentTask.scheduledDate,
      scheduledDateRepeat: currentTask.scheduledDateRepeat,
      deadlineDate: currentTask.deadlineDate,
      deadlineDateRepeat: currentTask.deadlineDateRepeat,
      closedDate: currentTask.closedDate,
      urgency: currentTask.urgency,
      tags: currentTask.tags,
      isDailyNote: currentTask.isDailyNote,
      dailyNoteDate: currentTask.dailyNoteDate,
      subtaskCount: currentTask.subtaskCount,
      subtaskCompletedCount: currentTask.subtaskCompletedCount,
      file,
    };

    return { ok: true, file, task: currentTask, writerTask, currentLine };
  }

  private async replaceTaskLine(
    file: TFile,
    writerTask: Task,
    expected: TodoSeqBoardTask,
    newLine: string,
    forceVaultApi: boolean,
  ): Promise<void> {
    const editor = forceVaultApi ? null : this.activeEditorForPath(file.path);
    if (editor?.replaceRange) {
      const currentLine = editor.getLine(writerTask.line) ?? '';
      if (!this.matchesExpectedTask(currentLine, expected)) {
        new Notice(TODOSEQ_CONFLICT_MESSAGE);
        throw new Error(TODOSEQ_CONFLICT_MESSAGE);
      }
      editor.replaceRange(
        newLine,
        { line: writerTask.line, ch: 0 },
        { line: writerTask.line, ch: currentLine.length },
      );
      return;
    }

    let conflicted = false;
    await this.app.vault.process(file, (data) => {
      const lines = data.split('\n');
      const currentLine = lines[writerTask.line] ?? '';
      if (!this.matchesExpectedTask(currentLine, expected)) {
        conflicted = true;
        return data;
      }
      lines[writerTask.line] = newLine;
      return lines.join('\n');
    });

    if (conflicted) {
      new Notice(TODOSEQ_CONFLICT_MESSAGE);
      throw new Error(TODOSEQ_CONFLICT_MESSAGE);
    }
  }

  private async applyDateEdit(
    file: TFile,
    writerTask: Task,
    expected: TodoSeqBoardTask,
    dateType: 'SCHEDULED' | 'DEADLINE',
    date: Date | null,
    repeat: DateRepeatInfo | null,
    forceVaultApi: boolean,
  ): Promise<void> {
    const editLines = (lines: string[]): { lines: string[]; conflicted: boolean } => {
      const currentLine = lines[writerTask.line] ?? '';
      if (!this.matchesExpectedTask(currentLine, expected)) {
        return { lines, conflicted: true };
      }

      const taskIndent = getTaskIndent(writerTask);
      const existingIndex = findDateLine(lines, writerTask.line + 1, dateType, taskIndent, this.adapter.keywordManager);

      if (date === null) {
        if (existingIndex >= 0) {
          lines.splice(existingIndex, 1);
        }
        return { lines, conflicted: false };
      }

      const lineIndent = existingIndex >= 0
        ? existingDateLineIndent(lines[existingIndex])
        : getDateLineIndent(writerTask);
      const nextLine = `${lineIndent}${dateType}: ${formatOrgDate(date, repeat)}`;

      if (existingIndex >= 0) {
        lines[existingIndex] = nextLine;
        return { lines, conflicted: false };
      }

      const insertIndex = this.dateInsertIndex(lines, writerTask, dateType, taskIndent);
      lines.splice(insertIndex, 0, nextLine);
      return { lines, conflicted: false };
    };

    const editor = forceVaultApi ? null : this.activeEditorForPath(file.path);
    if (editor?.replaceRange && editor.lineCount) {
      const lines = Array.from({ length: editor.lineCount() }, (_, index) => editor.getLine(index));
      const { lines: nextLines, conflicted } = editLines([...lines]);
      if (conflicted) {
        new Notice(TODOSEQ_CONFLICT_MESSAGE);
        throw new Error(TODOSEQ_CONFLICT_MESSAGE);
      }
      replaceEditorDocument(editor, lines, nextLines);
      return;
    }

    let conflicted = false;
    await this.app.vault.process(file, (data) => {
      const { lines, conflicted: didConflict } = editLines(data.split('\n'));
      conflicted = didConflict;
      return didConflict ? data : lines.join('\n');
    });

    if (conflicted) {
      new Notice(TODOSEQ_CONFLICT_MESSAGE);
      throw new Error(TODOSEQ_CONFLICT_MESSAGE);
    }
  }

  private dateInsertIndex(lines: string[], task: Task, dateType: 'SCHEDULED' | 'DEADLINE', taskIndent: string): number {
    const scheduledIndex = findDateLine(lines, task.line + 1, 'SCHEDULED', taskIndent, this.adapter.keywordManager);
    const deadlineIndex = findDateLine(lines, task.line + 1, 'DEADLINE', taskIndent, this.adapter.keywordManager);
    const closedIndex = findDateLine(lines, task.line + 1, 'CLOSED', taskIndent, this.adapter.keywordManager);

    if (dateType === 'SCHEDULED') {
      if (deadlineIndex >= 0) return deadlineIndex;
      if (closedIndex >= 0) return closedIndex;
      return task.line + 1;
    }

    if (scheduledIndex >= 0) return scheduledIndex + 1;
    if (closedIndex >= 0) return closedIndex;
    return task.line + 1;
  }

  private async runWrite(write: () => Promise<void>): Promise<{ ok: true } | Extract<TodoSeqTaskWriteResult, { ok: false }>> {
    try {
      await write();
      return { ok: true };
    } catch (error) {
      if (error instanceof Error && error.message === TODOSEQ_CONFLICT_MESSAGE) {
        return { ok: false, error: TODOSEQ_CONFLICT_MESSAGE, conflict: true };
      }
      throw error;
    }
  }

  private async readCurrentLine(file: TFile, line: number): Promise<string> {
    const activeEditor = this.activeEditorForPath(file.path);
    if (activeEditor) {
      return activeEditor.getLine(line) ?? '';
    }
    const content = await this.app.vault.cachedRead(file);
    return content.split(/\r?\n/)[line] ?? '';
  }

  private async readFileContent(file: TFile): Promise<string> {
    const activeEditor = this.activeEditorForPath(file.path);
    if (activeEditor?.lineCount) {
      return Array.from({ length: activeEditor.lineCount() }, (_, index) => activeEditor.getLine(index)).join('\n');
    }
    return this.app.vault.cachedRead(file);
  }

  private activeEditorForPath(path: string): ActiveEditor | null {
    const md = this.app.workspace.getActiveViewOfType(MarkdownView);
    const editor = md?.file?.path === path ? (md.editor as ActiveEditor | undefined) : null;
    return editor ?? null;
  }

  private matchesExpectedTask(currentLine: string, expected: TodoSeqBoardTask): boolean {
    if (currentLine === expected.rawText) return true;

    const current = this.adapter.parser.parseLineAsTask(currentLine, expected.line, expected.path);
    if (!current) return false;

    return (
      normalizeText(current.text) === normalizeText(expected.text) &&
      current.state === expected.state &&
      current.priority === expected.priority &&
      (current.embedReference ?? null) === (expected.embedReference ?? null) &&
      (current.footnoteReference ?? null) === (expected.footnoteReference ?? null)
    );
  }

  private async refreshTaskAtLine(file: TFile, path: string, line: number): Promise<TodoSeqBoardTask | null> {
    const content = await this.readFileContent(file);
    return this.adapter.scanMarkdown(content, path, file).find((task) => task.line === line) ?? null;
  }

  private success(previous: TodoSeqBoardTask, refreshed: TodoSeqBoardTask): Extract<TodoSeqTaskWriteResult, { ok: true }> {
    return {
      ok: true,
      task: refreshed,
      previousId: this.taskItemId(previous),
      taskItemId: this.taskItemId(refreshed),
    };
  }

  private taskItemId(task: TodoSeqBoardTask): string {
    return `${task.path}:${task.line}`;
  }
}

export class TodoSeqStateWriter extends TodoSeqTaskEditorService {}

function isWriteFailure(value: { ok: true } | Extract<TodoSeqTaskWriteResult, { ok: false }>): value is Extract<TodoSeqTaskWriteResult, { ok: false }> {
  return value.ok === false;
}

function isFailure(value: PreparedTaskContext | { ok: false; error: string; conflict?: boolean }): value is { ok: false; error: string; conflict?: boolean } {
  return value.ok === false;
}

function failure(error: { ok: false; error: string; conflict?: boolean }): Extract<TodoSeqTaskWriteResult, { ok: false }> {
  return error;
}

function setTextOnLine(line: string, task: Task, text: string): string {
  const bodyStart = taskBodyStartIndex(line, task);
  const bodyEnd = trailingReferenceIndex(line, task);
  const references = bodyEnd < line.length ? ` ${line.slice(bodyEnd).trim()}` : '';
  return `${line.slice(0, bodyStart)}${text}${references}`.replace(/[ 	]+$/u, '');
}

function taskBodyStartIndex(line: string, task: Task): number {
  const stateIndex = line.indexOf(task.state);
  if (stateIndex === -1) {
    return line.length;
  }
  const afterState = stateIndex + task.state.length;
  const afterPriority = line.slice(afterState).match(/^[ 	]+\[#([ABC])\]/u);
  if (afterPriority) {
    return afterState + afterPriority[0].length + (line[afterState + afterPriority[0].length] === ' ' ? 1 : 0);
  }
  return afterState + (line[afterState] === ' ' ? 1 : 0);
}

function setPriorityOnLine(line: string, task: Task, priority: TodoSeqPriority): string {
  if (priority === null) {
    return removePriorityToken(line);
  }

  const token = PRIORITY_TOKEN_BY_VALUE[priority];
  if (PRIORITY_TOKEN_REGEX.test(line)) {
    return line.replace(PRIORITY_TOKEN_REGEX, (_match, prefix: string) => `${prefix}${token}`);
  }

  const stateIndex = line.indexOf(task.state);
  if (stateIndex === -1) {
    return `${line} ${token}`;
  }
  const insertAt = stateIndex + task.state.length;
  return `${line.slice(0, insertAt)} ${token}${line.slice(insertAt)}`;
}

function removePriorityToken(line: string): string {
  return line
    .replace(/(^|[ \t])\[#([ABC])\]([ \t]?)/u, (_match, prefix: string) => prefix)
    .replace(/[ \t]+$/u, '');
}

function setTagsOnLine(line: string, task: Task, desiredTags: string[]): string {
  const desired = uniqueTags(desiredTags);
  let next = line;

  for (const range of tagRanges(next).reverse()) {
    if (!desired.includes(range.tag) || tagRanges(next).filter((candidate) => candidate.tag === range.tag && candidate.index < range.index).length > 0) {
      next = removeInlineRange(next, range.index, range.index + range.raw.length);
    }
  }

  const existing = uniqueTags(tagRanges(next).map((range) => range.tag));
  const missing = desired.filter((tag) => !existing.includes(tag));
  if (missing.length === 0) return next;

  const insertion = ` ${missing.map((tag) => `#${tag}`).join(' ')}`;
  const insertAt = trailingReferenceIndex(next, task);
  return `${next.slice(0, insertAt).replace(/[ \t]+$/u, '')}${insertion}${insertAt < next.length ? ' ' : ''}${next.slice(insertAt).replace(/^[ \t]+/u, '')}`;
}

function tagRanges(line: string): Array<{ tag: string; raw: string; index: number }> {
  SIMPLE_TAG_REGEX.lastIndex = 0;
  const ranges: Array<{ tag: string; raw: string; index: number }> = [];
  let match: RegExpExecArray | null;
  while ((match = SIMPLE_TAG_REGEX.exec(line)) !== null) {
    const tag = normalizeTag(match[1]);
    if (tag && !['A', 'B', 'C'].includes(tag)) {
      ranges.push({ tag, raw: match[0], index: match.index });
    }
  }
  return ranges;
}

function removeInlineRange(line: string, start: number, end: number): string {
  const hasSpaceBefore = start > 0 && /[ \t]/.test(line[start - 1]);
  const hasSpaceAfter = end < line.length && /[ \t]/.test(line[end]);
  if (hasSpaceBefore && hasSpaceAfter) {
    return `${line.slice(0, start)}${line.slice(end + 1)}`;
  }
  if (hasSpaceBefore && end === line.length) {
    return `${line.slice(0, start - 1)}${line.slice(end)}`;
  }
  return `${line.slice(0, start)}${line.slice(end)}`;
}

function trailingReferenceIndex(line: string, task: Task): number {
  const candidates = [task.embedReference, task.footnoteReference, task.tail]
    .filter((value): value is string => Boolean(value))
    .map((value) => line.lastIndexOf(value))
    .filter((index) => index >= 0);
  return candidates.length > 0 ? Math.min(...candidates) : line.length;
}

function normalizeTags(tags: string[]): string[] {
  return tags.map(normalizeTag).filter((tag): tag is string => Boolean(tag));
}

function uniqueTags(tags: string[]): string[] {
  return Array.from(new Set(normalizeTags(tags)));
}

function normalizeTag(tag: string): string {
  return tag.replace(/^#/u, '').trim();
}

function existingDateLineIndent(line: string): string {
  const lineIndent = line.match(/^(\s*)/)?.[1] ?? '';
  const lineQuotePrefix = line.match(/^(\s*(>\s*)+)/)?.[1] ?? '';
  return lineQuotePrefix || lineIndent;
}

function formatOrgDate(date: Date, repeat: DateRepeatInfo | null): string {
  const days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  const dayName = days[date.getDay()];
  const hours = String(date.getHours()).padStart(2, '0');
  const minutes = String(date.getMinutes()).padStart(2, '0');
  const timeStr = date.getHours() === 0 && date.getMinutes() === 0 ? '' : ` ${hours}:${minutes}`;
  const repeatStr = repeat ? ` ${repeat.raw}` : '';
  return `<${year}-${month}-${day} ${dayName}${timeStr}${repeatStr}>`;
}

function replaceEditorDocument(editor: ActiveEditor, previous: string[], next: string[]): void {
  const lastLine = Math.max(previous.length - 1, 0);
  const lastCh = previous[lastLine]?.length ?? 0;
  editor.replaceRange?.(next.join('\n'), { line: 0, ch: 0 }, { line: lastLine, ch: lastCh });
}

function normalizeKeyword(keyword: string): string {
  return keyword.trim().toUpperCase();
}

function normalizeText(text: string): string {
  return text.trim().replace(/\s+/g, ' ');
}

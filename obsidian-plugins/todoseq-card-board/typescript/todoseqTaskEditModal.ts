import { App, Modal, Notice, Setting } from 'obsidian';
import { TodoSeqAdapter, TodoSeqBoardTask } from './todoseqAdapter';
import { TodoSeqPriority, TodoSeqTaskEditorService, TodoSeqTaskPatch, TodoSeqTaskWriteResult } from './todoseqStateWriter';

export type TodoSeqTaskEditModalSave = (task: TodoSeqBoardTask, patch: TodoSeqTaskPatch) => Promise<TodoSeqTaskWriteResult>;
export type TodoSeqTaskEditModalRefresh = (previousId: string, task: TodoSeqBoardTask) => Promise<void> | void;

export type TodoSeqTaskEditModalOptions = {
  app: App;
  adapter: TodoSeqAdapter;
  task: TodoSeqBoardTask;
  service: TodoSeqTaskEditorService;
  onSaved: TodoSeqTaskEditModalRefresh;
};

type TodoSeqTaskEditPatchResult = { ok: true; patch: TodoSeqTaskPatch } | { ok: false; error: string };
type TodoSeqDateParseResult = { ok: true; date: Date | null } | { ok: false; error: string };

function isPatchError(result: TodoSeqTaskEditPatchResult): result is { ok: false; error: string } {
  return result.ok === false;
}

function isWriteError(result: TodoSeqTaskWriteResult): result is Extract<TodoSeqTaskWriteResult, { ok: false }> {
  return result.ok === false;
}

function isDateParseError(result: TodoSeqDateParseResult): result is { ok: false; error: string } {
  return result.ok === false;
}

export type TodoSeqTaskEditFormState = {
  text: string;
  state: string;
  priority: TodoSeqPriority;
  scheduledDate: string;
  deadlineDate: string;
  tagsText: string;
};

export class TodoSeqTaskEditModal extends Modal {
  private state: TodoSeqTaskEditFormState;
  private errorEl: HTMLElement | null = null;
  private saveButton: HTMLButtonElement | null = null;

  constructor(private readonly options: TodoSeqTaskEditModalOptions) {
    super(options.app);
    this.state = formStateFromTask(options.task);
  }

  onOpen(): void {
    const { contentEl } = this;
    contentEl.empty();
    contentEl.addClass('todoseq-card-board-task-edit-modal');

    contentEl.createEl('h2', { text: 'Edit TODOseq card' });
    contentEl.createEl('p', {
      cls: 'todoseq-card-board-task-edit-subtitle',
      text: 'Board-friendly editor. SCHEDULED and DEADLINE are independent TODOseq fields.',
    });

    this.errorEl = contentEl.createDiv({ cls: 'todoseq-card-board-task-edit-error' });
    this.errorEl.hide();

    this.buildEditableFields(contentEl);
    this.buildReadOnlyFields(contentEl);
    this.buildActions(contentEl);
  }

  onClose(): void {
    this.contentEl.empty();
  }

  private buildEditableFields(contentEl: HTMLElement): void {
    new Setting(contentEl)
      .setName('Text')
      .setDesc('TODOseq task text without the state keyword.')
      .addTextArea((text) => {
        text.inputEl.addClass('todoseq-card-board-task-edit-text');
        text.setValue(this.state.text);
        text.onChange((value) => {
          this.state.text = value;
        });
      });

    new Setting(contentEl)
      .setName('State')
      .setDesc('Keyword candidates come from TODOseq settings.')
      .addDropdown((dropdown) => {
        for (const keyword of this.options.adapter.keywordManager.getAllKeywords()) {
          dropdown.addOption(keyword, keywordLabel(keyword, this.options.adapter));
        }
        dropdown.setValue(this.state.state);
        dropdown.onChange((value) => {
          this.state.state = value;
        });
      });

    new Setting(contentEl)
      .setName('Priority')
      .setDesc('TODOseq priority token [#A] / [#B] / [#C].')
      .addDropdown((dropdown) => {
        dropdown
          .addOption('', 'None')
          .addOption('high', 'High ([#A])')
          .addOption('med', 'Medium ([#B])')
          .addOption('low', 'Low ([#C])')
          .setValue(this.state.priority ?? '')
          .onChange((value) => {
            this.state.priority = parsePriority(value);
          });
      });

    new Setting(contentEl)
      .setName('SCHEDULED')
      .setDesc('Independent TODOseq SCHEDULED date. Empty removes SCHEDULED.')
      .addText((text) => {
        text.inputEl.type = 'date';
        text.setValue(this.state.scheduledDate);
        text.onChange((value) => {
          this.state.scheduledDate = value;
        });
      });

    new Setting(contentEl)
      .setName('DEADLINE')
      .setDesc('Independent TODOseq DEADLINE date. Empty removes DEADLINE.')
      .addText((text) => {
        text.inputEl.type = 'date';
        text.setValue(this.state.deadlineDate);
        text.onChange((value) => {
          this.state.deadlineDate = value;
        });
      });

    new Setting(contentEl)
      .setName('Tags')
      .setDesc('Space or comma separated tags. # is optional.')
      .addText((text) => {
        text.setPlaceholder('#work #next');
        text.setValue(this.state.tagsText);
        text.onChange((value) => {
          this.state.tagsText = value;
        });
      });
  }

  private buildReadOnlyFields(contentEl: HTMLElement): void {
    const task = this.options.task;
    const container = contentEl.createDiv({ cls: 'todoseq-card-board-task-edit-readonly' });
    container.createEl('h3', { text: 'Read-only TODOseq details' });

    const items: Array<[string, string]> = [
      ['CLOSED', formatDate(task.closedDate) ?? 'None'],
      ['Urgency', task.urgency === null ? 'None' : String(Math.round(task.urgency * 10) / 10)],
      ['Subtasks', `${task.subtaskCompletedCount}/${task.subtaskCount}`],
      ['Source', `${task.path}:${task.line + 1}`],
      ['Daily note', task.isDailyNote ? formatDate(task.dailyNoteDate) ?? 'Yes' : 'No'],
      ['Embed', task.embedReference ?? 'None'],
      ['Footnote', task.footnoteReference ?? 'None'],
      ['Quote/callout nesting', String(task.quoteNestingLevel)],
    ];

    for (const [label, value] of items) {
      const row = container.createDiv({ cls: 'todoseq-card-board-task-edit-readonly-row' });
      row.createSpan({ cls: 'todoseq-card-board-task-edit-readonly-label', text: label });
      row.createSpan({ cls: 'todoseq-card-board-task-edit-readonly-value', text: value });
    }
  }

  private buildActions(contentEl: HTMLElement): void {
    const actions = contentEl.createDiv({ cls: 'todoseq-card-board-task-edit-actions' });
    const cancel = actions.createEl('button', { text: 'Cancel' });
    cancel.addEventListener('click', () => this.close());

    this.saveButton = actions.createEl('button', {
      text: 'Save',
      cls: 'mod-cta todoseq-card-board-task-edit-save',
    });
    this.saveButton.addEventListener('click', () => {
      void this.save();
    });
  }

  private async save(): Promise<void> {
    if (this.saveButton) this.saveButton.disabled = true;
    this.showError(null);

    const patchResult = buildTodoSeqTaskEditPatch(this.options.task, this.state);
    if (isPatchError(patchResult)) {
      this.showError(patchResult.error);
      if (this.saveButton) this.saveButton.disabled = false;
      return;
    }

    const result = await this.options.service.applyPatch(this.options.task, patchResult.patch);
    if (result.ok) {
      await this.options.onSaved(result.previousId, result.task);
      new Notice('TODOseq task updated.');
      this.close();
      return;
    }

    if (isWriteError(result)) this.showError(result.error);
    if (this.saveButton) this.saveButton.disabled = false;
  }

  private showError(message: string | null): void {
    if (!this.errorEl) return;
    if (!message) {
      this.errorEl.setText('');
      this.errorEl.hide();
      return;
    }
    this.errorEl.setText(message);
    this.errorEl.show();
  }
}

export function formStateFromTask(task: TodoSeqBoardTask): TodoSeqTaskEditFormState {
  return {
    text: task.text,
    state: task.state,
    priority: task.priority,
    scheduledDate: formatDateInput(task.scheduledDate),
    deadlineDate: formatDateInput(task.deadlineDate),
    tagsText: task.tags.map((tag) => `#${tag}`).join(' '),
  };
}

export function buildTodoSeqTaskEditPatch(
  task: TodoSeqBoardTask,
  state: TodoSeqTaskEditFormState,
): TodoSeqTaskEditPatchResult {
  const text = state.text.trim();
  if (!text) {
    return { ok: false, error: 'Text cannot be empty.' };
  }

  const scheduled = parseDateInput(state.scheduledDate, 'SCHEDULED');
  if (isDateParseError(scheduled)) return scheduled;
  const deadline = parseDateInput(state.deadlineDate, 'DEADLINE');
  if (isDateParseError(deadline)) return deadline;

  const tags = parseTagsInput(state.tagsText);
  const patch: TodoSeqTaskPatch = {};

  if (state.state !== task.state) patch.state = state.state;
  if (state.priority !== task.priority) patch.priority = state.priority;
  if (text !== task.text) patch.text = text;
  if (dateChanged(task.scheduledDate, scheduled.date)) patch.scheduledDate = scheduled.date;
  if (dateChanged(task.deadlineDate, deadline.date)) patch.deadlineDate = deadline.date;
  if (!arraysEqual(task.tags, tags)) patch.tags = tags;

  return { ok: true, patch };
}

function keywordLabel(keyword: string, adapter: TodoSeqAdapter): string {
  const group = adapter.keywordManager.getGroup(keyword);
  return group ? `${keyword} (${group.replace(/Keywords$/, '')})` : keyword;
}

function parsePriority(value: string): TodoSeqPriority {
  if (value === 'high' || value === 'med' || value === 'low') return value;
  return null;
}

function parseTagsInput(value: string): string[] {
  const tags = value
    .split(/[\s,]+/u)
    .map((tag) => tag.trim().replace(/^#+/u, ''))
    .filter((tag) => tag.length > 0);
  return Array.from(new Set(tags));
}

function parseDateInput(value: string, label: 'SCHEDULED' | 'DEADLINE'): TodoSeqDateParseResult {
  if (!value.trim()) return { ok: true, date: null };
  const match = value.match(/^(\d{4})-(\d{2})-(\d{2})$/u);
  if (!match) return { ok: false, error: `${label} must use YYYY-MM-DD.` };
  const date = new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
  if (Number.isNaN(date.getTime())) return { ok: false, error: `${label} is not a valid date.` };
  return { ok: true, date };
}

function formatDateInput(date: Date | null): string {
  if (!date) return '';
  return `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())}`;
}

function formatDate(date: Date | null): string | null {
  return date ? formatDateInput(date) : null;
}

function dateChanged(left: Date | null, right: Date | null): boolean {
  return formatDateInput(left) !== formatDateInput(right);
}

function arraysEqual(left: string[], right: string[]): boolean {
  if (left.length !== right.length) return false;
  return left.every((value, index) => value === right[index]);
}

function pad2(value: number): string {
  return String(value).padStart(2, '0');
}

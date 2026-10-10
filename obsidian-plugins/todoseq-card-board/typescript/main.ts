import {
  App,
  MarkdownView,
  Modal,
  Notice,
  Plugin,
  PluginSettingTab,
  Setting,
  TAbstractFile,
  TFile,
  addIcon,
  moment,
  normalizePath } from 'obsidian';
import { TodoSeqCardBoardView, VIEW_TYPE_TODOSEQ_CARD_BOARD } from './view';
import { TodoSeqCardBoardPluginSettings, TodoSeqCardBoardPluginSettingsPostV11, TaskItem } from './types';
import { cleanTodoSeqTaskDisplayText, TodoSeqAdapter, TodoSeqBoardTask } from './todoseqAdapter';
import {
  buildDeadlineBucketPreset,
  buildGroupPreset,
  buildKeywordPreset,
  buildPriorityPreset,
  buildScheduledBucketPreset,
  buildUrgencyBucketPreset,
  BoardColumn,
  BoardColumnPresetId,
  DateSortStrategy,
  isColumnWritable,
  normalizeCustomColumns,
  readonlyColumnMessage,
} from './boardDomain';
import { FileFilter } from './fileFilter'
import { getDateFromFile, IPeriodicNoteSettings } from 'obsidian-daily-notes-interface';

export default class TodoSeqCardBoardPlugin extends Plugin {
  private commandIds: string[] = [];
  private fileFilter: FileFilter;
  private todoSeqAdapter: TodoSeqAdapter | null = null;
  private todoSeqRuntimeSettings: Record<string, unknown> | null = null;
  private todoSeqDependencyError: string | null = null;
  private taskItemsByFile: Map<string, TaskItem[]> = new Map();
  private refreshAllTimer: ReturnType<typeof setTimeout> | null = null;
  private refreshAllVersion: number = 0;
  settings:           TodoSeqCardBoardPluginSettings;

  async onload() {
    console.log('TodoSeqCardBoard: loading plugin');

    await this.loadSettings();

    this.registerView(
      VIEW_TYPE_TODOSEQ_CARD_BOARD,
      (leaf) => new TodoSeqCardBoardView(this, leaf)
    );

    this.app.workspace.onLayoutReady(this.onLayoutReady.bind(this));
  }

  async onLayoutReady() {
    console.debug("TodoSeqCardBoard: [main] onLayoutReady");

    const globalSettings : any = this.settings?.data.globalSettings;

    if ((!(globalSettings === undefined)) && globalSettings.hasOwnProperty('filters')) {
      this.fileFilter = new FileFilter(globalSettings.filters);
    } else {
      this.fileFilter = new FileFilter([]);
    }

    const adapterReady = await this.reloadTodoSeqAdapter();
    if (!adapterReady) {
      await this.handleAllTasksLoaded();
      return;
    }

    this.registerEvent(this.app.vault.on("create",
      (file) => this.handleFileCreated(file)));

    this.registerEvent(this.app.vault.on("delete",
      (file) => this.handleFileDeleted(file)));

    this.registerEvent(this.app.vault.on("modify",
      (file) => this.handleFileModified(file)));

    this.registerEvent(this.app.vault.on("rename",
      (file, oldPath) => this.handleFileRenamed(file, oldPath)));

    const scanSummary = await this.refreshAllTasks();
    await this.handleAllTasksLoaded();

    console.debug("TodoSeqCardBoard: " + scanSummary.markdownFiles.length + " markdown files in vault.");
    console.log("TodoSeqCardBoard: " + scanSummary.filteredFiles.length + " files scanned by TODOseq adapter for tasks.");
  }


  async handleAllTaskItems(taskItems: TaskItem[]) {
    console.debug("TodoSeqCardBoard: [main] fromWorker -> allTasksItems");

    const leaves = this.app.workspace.getLeavesOfType(VIEW_TYPE_TODOSEQ_CARD_BOARD);

    for (const leaf of leaves) {
      if (leaf.view instanceof TodoSeqCardBoardView) {
        leaf.view.taskItemsRefreshed(taskItems);
      }
    }
  }

  async handleAllTasksLoaded() {
    console.debug("TodoSeqCardBoard: [main] fromWorker -> allTasksLoaded");

    addIcon("todoseq-card-board",
      '<rect x="2" y="2" width="96" height="96" rx="12" ry="12" fill="none" stroke="currentColor" stroke-width="5"></rect>' +
      '<rect x="28" y="28" width="12" height="46" fill="none" stroke="currentColor" stroke-width="5"></rect>' +
      '<rect x="56" y="28" width="12" height="30" fill="none" stroke="currentColor" stroke-width="5"></rect>');

    this.addRibbonIcon('todoseq-card-board', 'TodoSeqCardBoard', async () => {
      this.activateView(0);
    });

    this.addCommands();
  }

  async viewInitialized(view?: TodoSeqCardBoardView) {
    console.debug("TodoSeqCardBoard: [main] toWorker <- viewInitialized");
    if (this.todoSeqDependencyError) {
      await this.handleTodoSeqDependencyError(this.todoSeqDependencyError);
      return;
    }

    if (view) {
      view.taskItemsRefreshed(this.allCachedTaskItems());
    }
  }


  async handleTasksAdded(taskItems : TaskItem[]) {
    const leaves = this.app.workspace.getLeavesOfType(VIEW_TYPE_TODOSEQ_CARD_BOARD);

    for (const leaf of leaves) {
      if (leaf.view instanceof TodoSeqCardBoardView) {
        leaf.view.taskItemsAdded(taskItems);
      }
    }
  }

  async handleTasksDeleted(taskIds : string[]) {
    console.debug("TodoSeqCardBoard: [main] fromWorker -> tasksDeleted");

    const leaves = this.app.workspace.getLeavesOfType(VIEW_TYPE_TODOSEQ_CARD_BOARD);

    for (const leaf of leaves) {
      if (leaf.view instanceof TodoSeqCardBoardView) {
        leaf.view.taskItemsDeleted(taskIds);
      }
    }
  }

  async handleTasksDeletedAndAdded(toDeleteAndAdd : [string[], TaskItem[]]) {
    console.debug("TodoSeqCardBoard: [main] fromWorker -> tasksDeletedAndAdded: (" + toDeleteAndAdd[0].length + ", " + toDeleteAndAdd[1].length + ")");

    const leaves = this.app.workspace.getLeavesOfType(VIEW_TYPE_TODOSEQ_CARD_BOARD);

    for (const leaf of leaves) {
      if (leaf.view instanceof TodoSeqCardBoardView) {
        leaf.view.taskItemsDeletedAndAdded(toDeleteAndAdd);
      }
    }
  }

  async handleTodoSeqTaskStateUpdated(_previousId: string, task: TodoSeqBoardTask) {
    await this.refreshTasksForFilePath(task.path);
  }

  async handleTasksUpdated(updateDetails : [string, TaskItem][]) {
    console.debug("TodoSeqCardBoard: [main] fromWorker -> tasksUpdated: " + updateDetails.length);

    const leaves = this.app.workspace.getLeavesOfType(VIEW_TYPE_TODOSEQ_CARD_BOARD);

    for (const leaf of leaves) {
      if (leaf.view instanceof TodoSeqCardBoardView) {
        leaf.view.taskItemsUpdated(updateDetails);
      }
    }
  }

  onunload() {
    console.log('unloading TodoSeqCardBoard plugin');
    this.app.workspace.detachLeavesOfType(VIEW_TYPE_TODOSEQ_CARD_BOARD);
  }


  addCommands() {
    this.settings?.data?.boardConfigs?.forEach((boardConfig, index) => {
      const config : any = boardConfig;
      var boardName : string;

      if (config.hasOwnProperty('data')) {
        boardName = config.data.title;
      } else {
        boardName = config.name;
      }

      const command = this.addCommand({
        id: "open-todoseq-card-board-plugin-" + index,
        name: "Open " + boardName,
        callback: async () => {
          this.activateView(index);
        },
      });

      this.commandIds.push(command.id);
    });
  }


  removeCommands() {
    for (const commandId of this.commandIds) {
      // @ts-ignore
      this.app.commands.removeCommand(commandId);
    }
    this.commandIds = [];
  }

  async activateView(index: number) {
    this.app.workspace.detachLeavesOfType(VIEW_TYPE_TODOSEQ_CARD_BOARD);

    await this.app.workspace.getLeaf(true).setViewState({
      type: VIEW_TYPE_TODOSEQ_CARD_BOARD,
      active: true,
    });

    const leaf = this.app.workspace.getLeavesOfType(VIEW_TYPE_TODOSEQ_CARD_BOARD)[0];

    if (leaf.view instanceof TodoSeqCardBoardView) {
      leaf.view.currentBoardIndex(index);
    }

    this.app.workspace.revealLeaf(leaf);
  }

  async deactivateView() {
    this.app.workspace.detachLeavesOfType(VIEW_TYPE_TODOSEQ_CARD_BOARD);
  }

  async loadSettings() {
    const loadedSettings = await this.loadData();
    this.settings = this.withTodoSeqDefaults(loadedSettings);
  }

  async saveSettings( newSettings: TodoSeqCardBoardPluginSettingsPostV11) {
    await this.backupOldVersion(this.settings?.version, newSettings.version);

    this.settings = newSettings;
    this.rebuildFileFilter();
    this.removeCommands();
    this.addCommands();
    await this.saveData(newSettings);
  }

  async backupOldVersion(oldVersion: string | null, newVersion: string) {
    if (oldVersion && (oldVersion != newVersion)) {
      const pathToSettings = normalizePath(this.app.vault.configDir + "/plugins/todoseq-card-board/data.json");
      const pathToSavedSettings = normalizePath(this.app.vault.configDir + "/plugins/todoseq-card-board/data." + oldVersion + ".json");

      if (await this.app.vault.adapter.exists(pathToSavedSettings)) {
        await this.app.vault.adapter.remove(pathToSavedSettings);
      }
      this.app.vault.adapter.copy(pathToSettings, pathToSavedSettings);
    }
  }

  async handleFileCreated(
    file: TAbstractFile
  ) {
    if (file instanceof TFile) {
      this.scheduleRefreshAllTasks(0);
    }
  }

  async handleFileDeleted(
    file: TAbstractFile
  ) {
    if (file instanceof TFile) {
      if (this.isTodoSeqRuntimeSettingsFile(file.path)) {
        await this.reloadTodoSeqAdapter();
      }
      this.scheduleRefreshAllTasks(0);
    }
  }

  async handleFileModified(
    file: TAbstractFile
  ) {
    if (!(file instanceof TFile)) {
      return;
    }

    if (this.isTodoSeqRuntimeSettingsFile(file.path)) {
      if (await this.reloadTodoSeqAdapter()) {
        await this.refreshAllTasks();
      }
      return;
    }

    if (this.isOwnSettingsFile(file.path)) {
      await this.loadSettings();
      this.rebuildFileFilter();
      this.removeCommands();
      this.addCommands();
      await this.refreshAllTasks();
      return;
    }

    this.scheduleRefreshAllTasks(0);
  }

  async handleFileRenamed(
    file: TAbstractFile,
    oldPath: string
  ) {
    let oldNew : [boolean, boolean] = [this.fileFilter.isAllowed(oldPath), this.fileFilter.isAllowed(file.path)];

    switch(oldNew.join(",")) {
      case 'false,true': {
        await this.handleFileCreated(file)
        break;
      }
      case 'true,false': {
        this.scheduleRefreshAllTasks(0);
        break;
      }
      case 'true,true': {
        if (file instanceof TFile) {
          this.scheduleRefreshAllTasks(0);
        }
        break;
      }
    }
  }

  async handleTodoSeqDependencyError(error: string) {
    console.error("TodoSeqCardBoard: " + error);
    const leaves = this.app.workspace.getLeavesOfType(VIEW_TYPE_TODOSEQ_CARD_BOARD);

    for (const leaf of leaves) {
      if (leaf.view instanceof TodoSeqCardBoardView) {
        leaf.view.todoSeqDependencyError(error);
      }
    }
  }

  async handleTasksDeletedForFile(path: string) {
    const taskIds = this.taskIdsForFile(path);
    this.taskItemsByFile.delete(path);
    await this.handleTasksDeleted(taskIds);
  }

  async refreshTasksForFilePath(path: string) {
    const file = this.app.vault.getAbstractFileByPath(path);
    if (file instanceof TFile) {
      this.scheduleRefreshAllTasks(0);
    }
  }

  scheduleRefreshAllTasks(delayMs = 500) {
    this.refreshAllVersion += 1;
    const version = this.refreshAllVersion;

    if (this.refreshAllTimer) {
      clearTimeout(this.refreshAllTimer);
    }

    this.refreshAllTimer = setTimeout(async () => {
      if (this.refreshAllVersion !== version) {
        return;
      }
      this.refreshAllTimer = null;
      await this.refreshAllTasks(version);
    }, delayMs);
  }

  async refreshTasksForFile(file: TFile, oldPath?: string) {
    const previousPath = oldPath ?? file.path;
    const deleteIds = this.taskIdsForFile(previousPath);

    if (!this.todoSeqAdapter || !this.fileFilter.isAllowed(file.path)) {
      this.taskItemsByFile.delete(previousPath);
      if (previousPath !== file.path) {
        this.taskItemsByFile.delete(file.path);
      }
      if (deleteIds.length > 0) {
        await this.handleTasksDeleted(deleteIds);
      }
      return;
    }

    const fileContents = await this.readFileContentsForRefresh(file);
    const taskItems = this.scanFileContents(file, fileContents);
    this.taskItemsByFile.delete(previousPath);
    this.taskItemsByFile.set(file.path, taskItems);
    this.scheduleRefreshAllTasks(0);
  }

  async refreshAllTasks(expectedVersion?: number): Promise<{ markdownFiles: TFile[]; filteredFiles: TFile[] }> {
    const version = expectedVersion ?? this.refreshAllVersion;
    const markdownFiles = this.app.vault.getMarkdownFiles();
    const filteredFiles = markdownFiles.filter((file) => this.fileFilter.isAllowed(file.path));

    if (!this.todoSeqAdapter) {
      this.taskItemsByFile = new Map();
      await this.handleAllTaskItems([]);
      return { markdownFiles, filteredFiles };
    }

    const taskItems: TaskItem[] = [];
    const nextTaskItemsByFile = new Map<string, TaskItem[]>();
    for (const file of filteredFiles) {
      const fileContents = await this.readFileContentsForRefresh(file);
      const fileTaskItems = this.scanFileContents(file, fileContents);
      nextTaskItemsByFile.set(file.path, fileTaskItems);
      taskItems.push(...fileTaskItems);
    }

    if (version !== this.refreshAllVersion) {
      return { markdownFiles, filteredFiles };
    }

    this.taskItemsByFile = nextTaskItemsByFile;
    await this.handleAllTaskItems(taskItems);
    return { markdownFiles, filteredFiles };
  }

  taskIdsForFile(path: string): string[] {
    return (this.taskItemsByFile.get(path) ?? []).map((taskItem) => this.taskItemId(taskItem));
  }

  private allCachedTaskItems(): TaskItem[] {
    return Array.from(this.taskItemsByFile.values()).flat();
  }

  getTodoSeqAdapter(): TodoSeqAdapter | null {
    return this.todoSeqAdapter;
  }

  getTodoSeqStateWriterHost() {
    return {
      app: this.app,
      settings: {
        trackClosedDate: Boolean(this.todoSeqRuntimeSettings?.trackClosedDate),
        stateTransitions: this.todoSeqRuntimeSettings?.stateTransitions as any,
      },
    };
  }

  todoSeqColumnsForCurrentBoard(): BoardColumn[] {
    const boardConfig: any = this.settings?.data?.boardConfigs?.[0];
    const todoSeqSettings = (this.settings?.data?.globalSettings as any)?.todoSeq;
    const runtimeSettings = this.todoSeqRuntimeSettings ?? {};

    if (Array.isArray(boardConfig?.todoSeqColumns) && boardConfig.todoSeqColumns.length > 0) {
      return boardConfig.todoSeqColumns;
    }

    const todoSeqColumnsFromSettings = this.todoSeqColumnsFromBoardColumns(boardConfig?.columns);
    if (todoSeqColumnsFromSettings.length > 0) {
      return todoSeqColumnsFromSettings;
    }

    switch (todoSeqSettings?.columnPreset) {
      case 'keywords':
        return buildKeywordPreset(runtimeSettings);
      case 'priority':
        return buildPriorityPreset();
      case 'scheduled':
        return buildScheduledBucketPreset();
      case 'deadline':
        return buildDeadlineBucketPreset();
      case 'urgency':
        return buildUrgencyBucketPreset();
      case 'custom':
        return normalizeCustomColumns(todoSeqSettings?.customColumns ?? [], runtimeSettings);
      case 'groups':
      default:
        return buildGroupPreset(runtimeSettings);
    }
  }

  private todoSeqColumnsFromBoardColumns(columns: unknown): BoardColumn[] {
    if (!Array.isArray(columns)) {
      return [];
    }

    return columns.flatMap((column: any): BoardColumn[] => {
      if (column?.tag !== "todoSeq" || !column.data) {
        return [];
      }

      const data = column.data;
      const keywords = Array.isArray(data.keywords)
        ? data.keywords.filter((keyword: unknown): keyword is string => typeof keyword === "string" && keyword.trim().length > 0)
        : [];
      const match = this.todoSeqMatchFromColumnData(data, keywords);
      const kind = typeof data.kind === "string" ? data.kind : "state";
      const defaultKeyword = typeof data.defaultKeyword === "string" && data.defaultKeyword.length > 0
        ? data.defaultKeyword
        : keywords[0];

      return [{
        id: typeof data.id === "string" ? data.id : `todoSeq:${kind}:${data.name ?? keywords[0] ?? "column"}`,
        name: typeof data.name === "string" ? data.name : "TODOseq Column",
        title: typeof data.name === "string" ? data.name : "TODOseq Column",
        kind: kind as BoardColumn["kind"],
        match,
        writable: data.writable === true,
        writeTarget: this.todoSeqWriteTargetFromColumnData(kind, match, data.group, defaultKeyword),
        type: typeof data.columnType === "string" ? data.columnType : "custom",
        keywords,
        group: typeof data.group === "string" ? data.group as any : undefined,
        defaultKeyword,
      }];
    });
  }

  private todoSeqMatchFromColumnData(data: any, keywords: string[]): BoardColumn["match"] {
    const kind = typeof data.kind === "string" ? data.kind : "state";
    const match = data.match && typeof data.match === "object" ? data.match : {};
    const value = keywords[0];

    switch (kind) {
      case "state":
        return { states: Array.isArray(match.states) ? match.states : keywords };
      case "keywordGroup":
        return { group: typeof match.group === "string" ? match.group : data.group };
      case "priority":
        return { priority: typeof match.priority === "string" ? match.priority as any : value as any };
      case "scheduledBucket":
        return { scheduledBucket: typeof match.scheduledBucket === "string" ? match.scheduledBucket as any : value as any };
      case "deadlineBucket":
        return { deadlineBucket: typeof match.deadlineBucket === "string" ? match.deadlineBucket as any : value as any };
      case "closedBucket":
        return { closedBucket: typeof match.closedBucket === "string" ? match.closedBucket as any : value as any };
      case "tag":
        return { tag: typeof match.tag === "string" ? match.tag : value };
      case "urgencyBucket":
        return { urgencyBucket: typeof match.urgencyBucket === "string" ? match.urgencyBucket as any : value as any };
      case "dailyNote":
        return { dailyNote: { bucket: typeof match.dailyNote?.bucket === "string" ? match.dailyNote.bucket : value as any } };
      case "source":
        return { source: { bucket: typeof match.source?.bucket === "string" ? match.source.bucket : "file", value: typeof match.source?.value === "string" ? match.source.value : data.name } };
      case "subtaskProgress":
        return { subtaskProgress: typeof match.subtaskProgress === "string" ? match.subtaskProgress as any : value as any };
      default:
        return { customFilter: { states: keywords } };
    }
  }

  private todoSeqWriteTargetFromColumnData(kind: string, match: BoardColumn["match"], group: unknown, defaultKeyword: string | undefined): BoardColumn["writeTarget"] {
    if (kind === "state" && defaultKeyword) {
      return { property: "state", keyword: defaultKeyword };
    }
    if (kind === "keywordGroup" && typeof group === "string" && defaultKeyword) {
      return { property: "keywordGroup", group: group as any, keyword: defaultKeyword };
    }
    if (kind === "priority" && match.priority !== undefined) {
      return { property: "priority", priority: match.priority === "none" ? null : match.priority as any };
    }
    return undefined;
  }

  private rebuildFileFilter() {
    const globalSettings : any = this.settings?.data.globalSettings;

    if ((!(globalSettings === undefined)) && globalSettings.hasOwnProperty('filters')) {
      this.fileFilter = new FileFilter(globalSettings.filters);
    } else {
      this.fileFilter = new FileFilter([]);
    }
  }

  private async reloadTodoSeqAdapter(): Promise<boolean> {
    const adapterResult = await TodoSeqAdapter.createFromObsidian(this.app);
    if (adapterResult.ok) {
      this.todoSeqAdapter = adapterResult.adapter;
      this.todoSeqRuntimeSettings = adapterResult.runtime.settings as Record<string, unknown>;
      this.todoSeqDependencyError = null;
      console.log("TodoSeqCardBoard: TODOseq adapter initialized from " + adapterResult.runtime.source + ".");
      return true;
    }

    const error = "error" in adapterResult ? adapterResult.error : "TODOseq runtime unavailable.";
    this.todoSeqAdapter = null;
    this.todoSeqRuntimeSettings = null;
    this.todoSeqDependencyError = error;
    this.taskItemsByFile = new Map();
    new Notice(error);
    await this.handleTodoSeqDependencyError(error);
    await this.handleAllTaskItems([]);
    return false;
  }

  private isTodoSeqRuntimeSettingsFile(path: string): boolean {
    return normalizePath(path) === normalizePath(this.app.vault.configDir + "/plugins/todoseq/data.json");
  }

  private isOwnSettingsFile(path: string): boolean {
    return normalizePath(path) === normalizePath(this.app.vault.configDir + "/plugins/todoseq-card-board/data.json");
  }

  private async readFileContentsForRefresh(file: TFile): Promise<string> {
    const openEditorContent = this.readOpenMarkdownEditorContent(file.path);
    if (openEditorContent !== null) {
      return openEditorContent;
    }
    return this.app.vault.read(file);
  }

  private readOpenMarkdownEditorContent(path: string): string | null {
    let content: string | null = null;
    this.app.workspace.iterateAllLeaves((leaf) => {
      if (content !== null) {
        return;
      }
      if (leaf.view instanceof MarkdownView && leaf.view.file?.path === path) {
        const editor: any = leaf.view.editor;
        if (editor?.lineCount && editor?.getLine) {
          content = Array.from({ length: editor.lineCount() }, (_, index) => editor.getLine(index)).join('\n');
        }
      }
    });
    return content;
  }

  private taskItemId(taskItem: TaskItem): string {
    return `${fnv1aHash(taskItem.fields.filePath)}:${this.taskItemStableKey(taskItem)}`;
  }

  private taskItemStableKey(taskItem: TaskItem): string {
    const todoSeq = taskItem.fields.todoSeq;
    if (todoSeq) {
      return fnv1aHash([
        todoSeq.sourceLine,
        todoSeq.state,
        todoSeq.text,
        taskItem.fields.originalLine,
      ].join('\u001f')).toString();
    }

    return taskItem.fields.lineNumber.toString();
  }

  scanFileContents(file: TFile, fileContents: string): TaskItem[] {
    if (!this.todoSeqAdapter) {
      return [];
    }

    const lines = fileContents.split(/\r?\n/);
    return this.todoSeqAdapter
      .scanMarkdown(fileContents, file.path, file)
      .map((task) => this.todoSeqTaskToTaskItem(task, lines));
  }

  todoSeqTaskToTaskItem(task: TodoSeqBoardTask, fileLines?: string[]): TaskItem {
    const date = this.dateForLegacyCardHighlight(task);
    const dueTag = date
      ? { tag: "SetToDate", date: date.getTime() }
      : { tag: "NotSet" };
    const completion = task.completed
      ? { tag: task.closedDate ? "CompletedAt" : "Completed", data: task.closedDate?.getTime() }
      : { tag: "Incomplete" };
    const words = task.text.split(/\s+/).filter(Boolean).map((word) => ({ tag: "Word", data: word }));
    const tags = task.tags.map((tag) => ({ tag: "ObsidianTag", data: tag }));
    const title = task.text.split(/\s+/).filter(Boolean);
    const fields: TaskItem["fields"] = {
      autoComplete: { tag: "NotSpecifed" },
      completion: completion as TaskItem["fields"]["completion"],
      contents: [...words, ...tags] as TaskItem["fields"]["contents"],
      dueFile: null,
      dueTag: dueTag as TaskItem["fields"]["dueTag"],
      filePath: task.path,
      lineNumber: task.line + 1,
      notes: "",
      originalBlock: task.rawText,
      originalLine: task.rawText,
      tags: task.tags,
      title,
      todoSeq: {
        closedDate: task.closedDate?.getTime() ?? null,
        dailyNoteDate: task.dailyNoteDate?.getTime() ?? null,
        deadlineDate: task.deadlineDate?.getTime() ?? null,
        group: this.todoSeqAdapter?.keywordManager.getGroup(task.state)?.replace(/Keywords$/, '') ?? null,
        isDailyNote: task.isDailyNote,
        priority: task.priority,
        scheduledDate: task.scheduledDate?.getTime() ?? null,
        sourceFile: task.path,
        sourceLine: task.line + 1,
        state: task.state,
        subtaskCompletedCount: task.subtaskCompletedCount,
        subtaskCount: task.subtaskCount,
        tags: task.tags,
        text: task.text,
        urgency: task.urgency,
        displayText: task.displayText,
      },
    };

    return { fields, subFields: this.todoSeqSubtaskFields(task, fileLines), todoSeq: task };
  }

  private todoSeqSubtaskFields(task: TodoSeqBoardTask, fileLines?: string[]): TaskItem["subFields"] {
    if (!fileLines) {
      return [];
    }

    const parentIndentLength = this.indentLength(task.rawText);
    const parentHasCheckbox = /(?:^|\s)(?:[-+*]|\d+[.)])\s+\[[^\]]\]/u.test(task.rawText);
    const subFields: TaskItem["subFields"] = [];

    for (let index = task.line + 1; index < fileLines.length; index++) {
      const line = fileLines[index];
      if (line.trim() === "") {
        break;
      }
      if (/^\s*(?:SCHEDULED|DEADLINE|CLOSED):/u.test(line)) {
        continue;
      }

      const indentLength = this.indentLength(line);
      if (parentHasCheckbox && indentLength <= parentIndentLength) {
        break;
      }
      if (!parentHasCheckbox && indentLength < parentIndentLength) {
        break;
      }

      const parsed = this.parseMarkdownCheckboxLine(line);
      if (!parsed) {
        if (indentLength <= parentIndentLength) {
          break;
        }
        continue;
      }

      subFields.push(this.todoSeqSubtaskField(task, index, parsed));
    }

    return subFields;
  }

  private todoSeqSubtaskField(
    parent: TodoSeqBoardTask,
    lineIndex: number,
    parsed: { checked: boolean; text: string; tags: string[]; rawText: string },
  ): TaskItem["fields"] {
    const words = parsed.text.split(/\s+/).filter(Boolean).map((word) => ({ tag: "Word", data: word }));
    const tags = parsed.tags.map((tag) => ({ tag: "ObsidianTag", data: tag }));
    return {
      autoComplete: { tag: "NotSpecifed" },
      completion: parsed.checked ? { tag: "Completed" } : { tag: "Incomplete" },
      contents: [...words, ...tags] as TaskItem["fields"]["contents"],
      dueFile: null,
      dueTag: { tag: "NotSet" },
      filePath: parent.path,
      lineNumber: lineIndex + 1,
      notes: "",
      originalBlock: parsed.rawText,
      originalLine: parsed.rawText,
      tags: parsed.tags,
      title: parsed.text.split(/\s+/).filter(Boolean),
      todoSeq: null,
    };
  }

  private parseMarkdownCheckboxLine(line: string): { checked: boolean; text: string; tags: string[]; rawText: string } | null {
    const match = line.match(/^\s*(?:[-+*]|\d+[.)])\s+\[([^\]])\]\s*(.*)$/u);
    if (!match) {
      return null;
    }

    const checked = match[1].toLowerCase() === "x";
    const text = cleanTodoSeqTaskDisplayText(match[2].trim());
    const tags = Array.from(match[2].matchAll(/(?:^|\s)#([A-Za-z0-9_/-]+)/gu)).map((tagMatch) => tagMatch[1]);
    return { checked, text, tags, rawText: line };
  }

  private indentLength(line: string): number {
    const indent = line.match(/^\s*/u)?.[0] ?? "";
    return Array.from(indent).reduce((length, char) => length + (char === "\t" ? 2 : 1), 0);
  }

  private withTodoSeqDefaults(settings: TodoSeqCardBoardPluginSettings | null | undefined): TodoSeqCardBoardPluginSettingsPostV11 {
    const keywordPreset = buildKeywordPreset({});
    const groupPreset = buildGroupPreset({});
    const defaultSettings: TodoSeqCardBoardPluginSettingsPostV11 = {
      version: "0.13.0",
      data: {
        boardConfigs: [
          this.boardConfigFromColumns("TODOseq Keywords", "keywords", keywordPreset),
          this.boardConfigFromColumns("TODOseq Groups", "groups", groupPreset),
        ],
        globalSettings: {
        defaultColumnNames: {
            inactive: "Inactive",
            active: "Active",
            waiting: "Waiting",
            completed: "Completed",
            archived: "Archived",
          },
          filters: [],
          firstDayOfWeek: "FromLocale",
          ignoreFileNameDates: true,
          taskCompletionFormat: "NoCompletion",
          taskCompletionInLocalTime: true,
          taskCompletionShowUtcOffset: false,
          todoSeq: {
            columnPreset: "groups",
            customColumns: groupPreset,
            columnPresetOptions: ["groups", "keywords", "priority", "scheduled", "deadline", "urgency", "custom"],
            dateDisplay: "both",
            dateSort: "urgency-first",
            dateFilter: null,
          },
        },
      },
    };

    if (!settings) {
      return defaultSettings;
    }

    const postSettings = settings as TodoSeqCardBoardPluginSettingsPostV11;
    const globalSettings = {
      ...defaultSettings.data.globalSettings,
      ...(postSettings.data?.globalSettings ?? {}),
      todoSeq: {
        ...defaultSettings.data.globalSettings.todoSeq,
        ...((postSettings.data?.globalSettings as any)?.todoSeq ?? {}),
      },
    };

    return {
      version: postSettings.version ?? defaultSettings.version,
      data: {
        boardConfigs: postSettings.data?.boardConfigs?.length ? postSettings.data.boardConfigs : defaultSettings.data.boardConfigs,
        globalSettings,
      },
    };
  }

  private boardConfigFromColumns(name: string, preset: BoardColumnPresetId, columns: BoardColumn[]): TodoSeqCardBoardPluginSettingsPostV11["data"]["boardConfigs"][number] {
    return {
      name,
      filters: [],
      filterPolarity: "Allow",
      filterScope: "Both",
      showColumnTags: true,
      showFilteredTags: true,
          todoSeqColumnPreset: preset,
      todoSeqColumns: columns,
      columns: columns.map((column) => ({
        tag: "todoSeq" as const,
        data: {
          id: column.id,
          collapsed: false,
          name: column.name,
            columnType: column.type,
            kind: column.kind,
            match: column.match,
      writable: column.writable ?? false,
            keywords: column.keywords,
            group: column.group ?? null,
            defaultKeyword: column.defaultKeyword ?? null,
        },
      })),
    };
  }

  private dateForLegacyCardHighlight(task: TodoSeqBoardTask): Date | null {
    const todoSeqSettings = (this.settings?.data?.globalSettings as any)?.todoSeq;
    const sortStrategy = todoSeqSettings?.dateSort as DateSortStrategy | undefined;
    switch (sortStrategy) {
      case "scheduled-first":
        return task.scheduledDate ?? task.deadlineDate;
      case "deadline-first":
        return task.deadlineDate ?? task.scheduledDate;
      case "nearest-date":
      case "urgency-first":
      default:
        return [task.scheduledDate, task.deadlineDate]
          .filter((date): date is Date => date instanceof Date)
          .sort((a, b) => a.getTime() - b.getTime())[0] ?? null;
    }
  }

  // HELPERS

  formattedFileDate(
    file: TFile
  ): string | null {
    return getDateFromFile(file, "day")?.format('YYYY-MM-DD') || null;
  }
}

function fnv1aHash(value: string): number {
  let h = 0x811c9dc5;
  for (const byte of utf8Bytes(value)) {
    h ^= byte;
    h = Math.imul(h, 16777619) >>> 0;
  }
  return h >>> 0;
}

function utf8Bytes(value: string): number[] {
  return Array.from(new TextEncoder().encode(value));
}

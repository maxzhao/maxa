import {
  App,
  FileView,
  ItemView,
  MarkdownRenderer,
  MarkdownView,
  Menu,
  Notice,
  TAbstractFile,
  TFile,
  TFolder,
  Vault,
  WorkspaceLeaf,
  moment
} from 'obsidian';

import { Elm, ElmApp, Flags } from '../src/Main';

import TodoSeqCardBoardPlugin from './main';
import { TodoSeqCardBoardPluginSettingsPostV11, TaskItem } from './types';
import { BoardColumn, isColumnWritable, readonlyColumnMessage } from './boardDomain';
import { TodoSeqTaskEditorService, TodoSeqStateWriter } from './todoseqStateWriter';
import { TaskStateTransitionManager } from './todoseq/services/task-state-transition-manager';
import { KeywordGroup } from './todoseq/types/task';
import { TodoSeqTaskEditModal } from './todoseqTaskEditModal';
import { TodoSeqAdapter, TodoSeqBoardTask } from './todoseqAdapter';
import { getDateFromFile, IPeriodicNoteSettings } from 'obsidian-daily-notes-interface';
import { FileFilter } from './fileFilter'
import { Scrollable } from './scrollable'

export const VIEW_TYPE_TODOSEQ_CARD_BOARD = "todoseq-card-board-view";

export class TodoSeqCardBoardView extends ItemView {
  private vault:      Vault;
  private plugin:     TodoSeqCardBoardPlugin;
  private elm:        ElmApp;
  private elmDiv:     any;
  private fileFilter: FileFilter;

  constructor(
    plugin: TodoSeqCardBoardPlugin,
    leaf: WorkspaceLeaf
  ) {
    super(leaf);
    this.plugin = plugin;
    this.app = plugin.app;
    this.vault = plugin.app.vault;
  }

  getViewType(): string {
    return VIEW_TYPE_TODOSEQ_CARD_BOARD;
  }

  getDisplayText(): string {
    return 'TodoSeqCardBoard';
  }

  async onOpen() {
    this.icon       = "todoseq-card-board"

    const globalSettings : any = this.plugin.settings?.data.globalSettings;

    if ((!(globalSettings === undefined)) && globalSettings.hasOwnProperty('filters')) {
      this.fileFilter = new FileFilter(globalSettings.filters);
    } else {
      this.fileFilter = new FileFilter([]);
    }

    // @ts-ignore
    const dataviewSettings = this.app.plugins.getPlugin("dataview")?.settings

    const mySettings:Flags = {
      uniqueId:           this.randomId(5),
      now:                Date.now(),
      zone:               new Date().getTimezoneOffset(),
      firstDayOfWeek:     moment.localeData().firstDayOfWeek(),
      settings:           this.plugin.settings as Flags["settings"],
      rightToLeft:        (this.app.vault as any).getConfig("rightToLeft"),
      dataviewTaskCompletion:   {
        taskCompletionTracking:           dataviewSettings  === undefined ? true          : dataviewSettings['taskCompletionTracking'],
        taskCompletionUseEmojiShorthand:  dataviewSettings  === undefined ? false         : dataviewSettings['taskCompletionUseEmojiShorthand'],
        taskCompletionText:               dataviewSettings  === undefined ? "completion"  : dataviewSettings['taskCompletionText']
      }
    };

    this.containerEl.children[1].empty();
    this.elmDiv = document.createElement('div');
    this.elmDiv.id = "elm-node";
    this.containerEl.children[1].appendChild(this.elmDiv);

    this.elm = Elm.Main.init({
      node: this.elmDiv,
      flags: mySettings
    })

    this.scheduleInitialRefresh();

    // TODO: I know I shouldn't need to do this, but my js foo
    // failed me at the time!
    const that = this;

    // messages from elm code.  This is the only route
    // that elm has to the obsidian API, so this is the
    // entry point for anything side-effecty
    this.elm.ports.interopFromElm.subscribe((fromElm) => {
      switch (fromElm.tag) {
        case "addFilePreviewHovers":
          that.handleAddFilePreviewHovers(fromElm.data);
          break;
        case "closeView":
          that.handleCloseView();
          break;
        case "deleteTask":
          that.handleDeleteTask(fromElm.data);
          break;
        case "displayTaskMarkdown":
          that.handleDisplayTaskMarkdown(fromElm.data);
          break;
        case "elmInitialized":
          that.handleElmInitialized(fromElm.data);
          break;
        case "openTaskSourceFile":
          that.handleOpenTaskSourceFile(fromElm.data);
          break;
        case "requestFilterCandidates":
          that.handleRequestFilterCandidates();
          break;
        case "openTodoSeqTaskEditor" as any:
          that.handleOpenTodoSeqTaskEditor((fromElm as any).data);
          break;
        case "showCardContextMenu":
          that.handleShowCardContextMenu(fromElm.data);
          break;
        case "showTodoSeqStateMenu" as any:
          that.handleShowTodoSeqStateMenu((fromElm as any).data);
          break;
        case "todoSeqCycleTaskState" as any:
          that.handleTodoSeqCycleTaskState((fromElm as any).data);
          break;
        case "todoSeqMoveTaskToColumn" as any:
          that.handleTodoSeqMoveTaskToColumn((fromElm as any).data);
          break;
        case "todoSeqToggleTaskState" as any:
          that.handleTodoSeqToggleTaskState((fromElm as any).data);
          break;
        case "trackDraggable":
          that.handleTrackDraggable(fromElm.data);
          break;
        case "updateSettings":
          that.handleUpdateSettings(fromElm.data);
          break;
        case "updateTasks":
          that.handleUpdateTasks(fromElm.data);
          break;
      }
    });

    this.registerEvent(this.app.workspace.on("active-leaf-change",
      (leaf) => this.handleActiveLeafChange(leaf)));

    // @ts-ignore
    this.registerEvent(this.app.vault.on("config-changed",
      () => this.handleConfigChanged()));
  }

  async onClose() {
    await this.elm.ports.interopToElm.send({
      tag: "activeStateUpdated",
      data: false
    });
  }

  currentBoardIndex(index: number) {
    this.elm.ports.interopToElm.send({
      tag: "showBoard",
      data: index
    });
  }

  // MESSAGES FROM ELM

  async handleAddFilePreviewHovers(
    data: {
      filePath: string,
      id : string
    }[]
  ) {
    const that = this;

    requestAnimationFrame(function () {
      for (const card of data) {
        const element = document.getElementById(card.id);

        if (element instanceof HTMLElement) {
          element.addEventListener('mouseover', (event: MouseEvent) => {
            that.app.workspace.trigger('hover-link', {
              event,
              source: "todoseq-card-board",
              hoverParent: element,
              targetEl: element,
              linktext: card.filePath,
              sourcePath: card.filePath
            });
          });
        }
      }
    })
  }

  async handleCloseView() {
    this.plugin.deactivateView();
  }

  private scheduleInitialRefresh() {
    requestAnimationFrame(() => {
      setTimeout(async () => {
        await this.plugin.refreshAllTasks();
      }, 0);
    });
  }

  async handleDeleteTask(
    data: {
      filePath: string,
      lineNumber: number,
      originalLine: string}
  ) {
    const file = this.app.vault.getAbstractFileByPath(data.filePath)

    if (file instanceof TFile) {
      const markdown      = await this.vault.read(file)
      const markdownLines = markdown.split(/\r?\n/)

      if (markdownLines[data.lineNumber - 1].includes(data.originalLine)) {
        markdownLines[data.lineNumber - 1] = markdownLines[data.lineNumber - 1].replace(/^(.*)$/, "<del>$1</del>")
        this.vault.modify(file, markdownLines.join("\n"))
      }
    }
  }

  async handleDisplayTaskMarkdown(
    data: {
      filePath: string,
      taskMarkdown: {
        id: string,
        markdown: string
      }[]
    }[]
  ) {
    const that = this;

    requestAnimationFrame(function () {
      for (const card of data) {
        for (const item of card.taskMarkdown) {
          const element = document.getElementById(item.id);

          if (element instanceof HTMLElement) {
            element.innerHTML = "";
            MarkdownRenderer.render(that.app, item.markdown, element, card.filePath, that);

            const internalLinks = Array.from(element.getElementsByClassName("internal-link"));

            for (const internalLink of internalLinks) {
              if (internalLink instanceof HTMLElement) {
                internalLink.addEventListener('mouseover', (event: MouseEvent) => {
                  that.app.workspace.trigger('hover-link', {
                    event,
                    source: "todoseq-card-board",
                    hoverParent: element,
                    targetEl: internalLink,
                    linktext: internalLink.getAttribute("href"),
                    sourcePath: card.filePath
                  });
                });

                internalLink.addEventListener("click", (event: MouseEvent) => {
                  event.preventDefault();

                  that.app.workspace.openLinkText(internalLink.getAttribute("href"), card.filePath, true, {
                      active: !0
                  });
                });
              }
            }

            const tags = Array.from(element.getElementsByClassName("tag"));

            for (const tag of tags) {
              if (tag instanceof HTMLElement) {
                tag.addEventListener("mouseup", (event: MouseEvent) => {
                  event.preventDefault();

                  (that.app as any).internalPlugins.plugins["global-search"].instance.openGlobalSearch("tag:"+ (event.target as HTMLElement).textContent);
                });
              }
            }
          }
        }
      }
    })
  }

  async handleElmInitialized(uniqueId : string) {
    console.debug("TodoSeqCardBoard: [view] fromView -> elmInitialised");

    this.plugin.viewInitialized(this);
    await this.plugin.refreshAllTasks();
  }


  async handleOpenTaskSourceFile(
    data: {
      filePath: string,
      lineNumber: number,
      originalLine: string
    }
  ) {
    await this.openOrSwitchWithHighlight(this.app, data.filePath, data.lineNumber);
  }

  async handleCopyTaskContext(
    data: {
      filePath: string,
      lineNumber: number,
      originalLine: string,
      originalBlock?: string
    }
  ) {
    try {
      const context = await this.resolveTaskContext(data);
      if (!context) {
        new Notice(`找不到任务源文件: ${data.filePath}`);
        return;
      }
      await this.writeClipboard(this.formatTaskContext(context));
      new Notice(`已复制任务上下文：${context.file} L${context.startLine}-${context.endLine}`);
    } catch (err) {
      console.error("Failed to copy TODOseq task context", err);
      new Notice(`复制任务上下文失败：${err.message || err}`);
    }
  }

  async resolveTaskContext(
    data: {
      filePath: string,
      lineNumber: number,
      originalLine: string,
      originalBlock?: string
    }
  ): Promise<{ file: string, startLine: number, endLine: number, markdown: string } | null> {
    const directFile = this.app.vault.getAbstractFileByPath(data.filePath);
    const file = directFile instanceof TFile
      ? directFile
      : this.app.metadataCache.getFirstLinkpathDest(data.filePath, "");

    if (!(file instanceof TFile)) return null;

    const markdown = await this.vault.read(file);
    const lines = markdown.split(/\r?\n/);
    const startIndex = Math.max(0, Math.min(lines.length - 1, data.lineNumber - 1));
    const endIndex = this.resolveTaskContextEndLine(lines, startIndex);

    return {
      file: file.path,
      startLine: startIndex + 1,
      endLine: endIndex + 1,
      markdown: lines.slice(startIndex, endIndex + 1).join("\n"),
    };
  }

  resolveTaskContextEndLine(lines: string[], startIndex: number): number {
    const startIndent = taskLineIndent(lines[startIndex]);
    if (startIndent === null) return startIndex;

    let endIndex = startIndex;
    for (let i = startIndex + 1; i < lines.length; i++) {
      const line = lines[i];
      if (line.trim() === "") {
        endIndex = i;
        continue;
      }
      const indent = taskLineIndent(line);
      if (indent !== null && indent <= startIndent) break;
      endIndex = i;
    }
    return endIndex;
  }

  formatTaskContext(context: { file: string, startLine: number, endLine: number, markdown: string }): string {
    return [
      "<todoseq-context>",
      `file: ${context.file}`,
      `lines: ${context.startLine}-${context.endLine}`,
      "</todoseq-context>",
      "",
      "```markdown",
      context.markdown || "",
      "```",
      "",
    ].join("\n");
  }

  async writeClipboard(text: string): Promise<void> {
    if (!navigator.clipboard || !navigator.clipboard.writeText) {
      throw new Error("Clipboard API is unavailable");
    }
    await navigator.clipboard.writeText(text);
  }

  async handleRequestFilterCandidates() {
    const loadedFiles = this.app.vault.getAllLoadedFiles();
    const filterCandidates: { tag : "pathFilter" | "fileFilter" | "tagFilter", data : string }[] = [];
    // @ts-ignore
    const tagsWithCounts = this.app.metadataCache.getTags();
    const tags = Object.keys(tagsWithCounts).map(x => x.slice(1));

    loadedFiles.forEach((folder: TAbstractFile) => {
      if (folder instanceof TFolder) {
        filterCandidates.push({ tag : "pathFilter", data : folder.path});
      }
    });

    loadedFiles.forEach((file: TAbstractFile) => {
      if (file instanceof TFile && file.extension === "md") {
        filterCandidates.push({ tag : "fileFilter", data : file.path});
      }
    });

    tags.forEach((tag: string) => {
      filterCandidates.push({ tag : "tagFilter", data : tag});
      filterCandidates.push({ tag : "tagFilter", data : tag + "/"});
    });

    this.elm.ports.interopToElm.send({
      tag: "filterCandidates",
      data: filterCandidates
    });
  }

  handleShowCardContextMenu(
    data: {
      clientPos: [number, number],
      cardId: string
    }
  ) {
    const menu = new Menu();
    menu.addItem((item) =>
      item
        .setTitle("Edit TODOseq task")
        .setIcon("pencil")
        .onClick(() => this.handleOpenTodoSeqTaskEditor({ taskId: data.cardId }))
    );
    menu.addSeparator();

    const columns = this.plugin.todoSeqColumnsForCurrentBoard();

    columns.forEach((column) => {
      const target = column.defaultKeyword ?? column.keywords[0] ?? column.name;
      menu.addItem((item) =>
        item
          .setTitle(`Move to ${column.name} (${target})`)
          .setIcon("arrow-right")
          .onClick(() => {
            this.handleTodoSeqMoveTaskToColumn({
              taskId: data.cardId,
              columnId: column.id,
              defaultKeyword: column.defaultKeyword ?? null,
            });
          })
      );
    });

    menu.addSeparator();
    menu.addItem((item) =>
      item
        .setTitle("Open source")
        .setIcon("file-text")
        .onClick(() => {
          const task = this.taskItemFromDomId(data.cardId);
          if (task) this.handleOpenTaskSourceFile(task.fields);
        })
    );
    menu.addItem((item) =>
      item
        .setTitle("复制上下文")
        .setIcon("copy")
        .onClick(() => {
          const task = this.taskItemFromDomId(data.cardId);
          if (task) this.handleCopyTaskContext(task.fields);
        })
    );

    if (data.clientPos[0] === 0 && data.clientPos[1] === 0) {
      const element = document.querySelector(`[data-todoseq-task-id="${cssEscape(data.cardId)}"]`);
      if (element instanceof HTMLElement) {
        const rect = element.getBoundingClientRect();
        menu.showAtPosition({ x: rect.left + 16, y: rect.top + 16 });
        return;
      }
    }

    menu.showAtPosition({x : data.clientPos[0], y : data.clientPos[1]})
  }

  async handleOpenTodoSeqTaskEditor(data: { taskId: string }) {
    const taskItem = this.taskItemFromDomId(data.taskId);
    const task = taskItem?.todoSeq;
    const adapter = this.plugin.getTodoSeqAdapter();
    if (!task || !adapter) {
      new Notice('TODOseq task is not available for editing.');
      return;
    }

    const service = new TodoSeqTaskEditorService(this.app, adapter, this.plugin.getTodoSeqStateWriterHost());
    new TodoSeqTaskEditModal({
      app: this.app,
      adapter,
      task,
      service,
      onSaved: async (previousId, refreshedTask) => {
        await this.plugin.handleTodoSeqTaskStateUpdated(previousId, refreshedTask);
      },
    }).open();
  }

  async handleTodoSeqCycleTaskState(data: { taskId: string }) {
    const taskItem = this.taskItemFromDomId(data.taskId);
    const task = taskItem?.todoSeq;
    const adapter = this.plugin.getTodoSeqAdapter();
    if (!task || !adapter) return;

    const transitionManager = this.createTransitionManager(adapter);
    const nextState = transitionManager.getNextState(task.state);
    if (!nextState || nextState === task.state) return;

    await this.writeTodoSeqState(task, adapter, nextState, data.taskId);
  }

  async handleTodoSeqToggleTaskState(data: { taskId: string; checked: boolean }) {
    const taskItem = this.taskItemFromDomId(data.taskId);
    const task = taskItem?.todoSeq;
    const adapter = this.plugin.getTodoSeqAdapter();
    if (!task || !adapter) {
      this.resetCheckboxForTask(data.taskId);
      return;
    }

    const transitionManager = this.createTransitionManager(adapter);
    const targetState = data.checked
      ? transitionManager.getNextCompletedOrArchivedState(task.state)
      : transitionManager.getNextState(task.state);

    if (!targetState || targetState === task.state) {
      this.resetCheckboxForTask(data.taskId);
      return;
    }
    await this.writeTodoSeqState(task, adapter, targetState, data.taskId);
  }

  handleShowTodoSeqStateMenu(data: { clientPos: [number, number]; taskId: string }) {
    const taskItem = this.taskItemFromDomId(data.taskId);
    const task = taskItem?.todoSeq;
    const adapter = this.plugin.getTodoSeqAdapter();
    if (!task || !adapter) return;

    const menu = new Menu();
    const groups: Array<{ label: string; group: KeywordGroup }> = [
      { label: 'Inactive', group: 'inactiveKeywords' },
      { label: 'Active', group: 'activeKeywords' },
      { label: 'Waiting', group: 'waitingKeywords' },
      { label: 'Completed', group: 'completedKeywords' },
      { label: 'Archived', group: 'archivedKeywords' },
    ];

    groups.forEach(({ label, group }) => {
      const keywords = adapter.keywordManager.getKeywordsForGroup(group);
      if (keywords.length === 0) return;
      menu.addItem((item) => item.setTitle(label).setDisabled(true));
      keywords.forEach((keyword) => {
        menu.addItem((item) =>
          item
            .setTitle(keyword === task.state ? `${keyword} ✓` : keyword)
            .setIcon(keyword === task.state ? 'check' : 'circle')
            .onClick(() => this.writeTodoSeqState(task, adapter, keyword)),
        );
      });
      menu.addSeparator();
    });

    menu.showAtPosition({ x: data.clientPos[0], y: data.clientPos[1] });
  }

  async handleTodoSeqMoveTaskToColumn(data: { taskId: string; columnId: string; defaultKeyword?: string | null }) {
    const taskItem = this.taskItemFromDomId(data.taskId);
    const task = taskItem?.todoSeq;
    const adapter = this.plugin.getTodoSeqAdapter();
    if (!task || !adapter) return;

    const column = this.resolveTodoSeqColumn(data.columnId, data.defaultKeyword ?? null);
    if (!column) return;
    if (!isColumnWritable(column)) {
      new Notice(readonlyColumnMessage(column));
      return;
    }

    const service = new TodoSeqStateWriter(this.app, adapter, this.plugin.getTodoSeqStateWriterHost());
    const result = await service.updateTaskState({ task, targetColumn: column });
    if (result.ok) {
      await this.plugin.handleTodoSeqTaskStateUpdated(result.previousId, result.task);
    } else {
      new Notice((result as { ok: false; error: string }).error);
    }
  }

  private createTransitionManager(adapter: TodoSeqAdapter): TaskStateTransitionManager {
    return new TaskStateTransitionManager(
      adapter.keywordManager,
      this.plugin.getTodoSeqStateWriterHost().settings?.stateTransitions,
    );
  }

  private async writeTodoSeqState(
    task: TodoSeqBoardTask,
    adapter: TodoSeqAdapter,
    targetKeyword: string,
    taskIdForUi?: string,
  ) {
    const service = new TodoSeqStateWriter(this.app, adapter, this.plugin.getTodoSeqStateWriterHost());
    const result = await service.updateState({ task, targetKeyword });
    if (result.ok) {
      await this.plugin.handleTodoSeqTaskStateUpdated(result.previousId, result.task);
    } else {
      new Notice((result as { ok: false; error: string }).error);
      if (taskIdForUi) this.resetCheckboxForTask(taskIdForUi);
    }
  }

  private resetCheckboxForTask(taskId: string) {
    const element = document.querySelector(`[data-todoseq-task-id="${cssEscape(taskId)}"] input.todoseq-card-board-card-checkbox`);
    const task = this.taskItemFromDomId(taskId)?.todoSeq;
    const adapter = this.plugin.getTodoSeqAdapter();
    if (element instanceof HTMLInputElement && task && adapter) {
      const dataTask = adapter.keywordManager.getCheckboxState(task.state, adapter.keywordManager.getSettings());
      element.checked = dataTask !== ' ';
      element.setAttribute('data-task', dataTask);
    }
  }


  async handleTrackDraggable(
    data : {
      dragType: string,
      clientPos : { x: number, y: number },
      draggableId: string
    }
  ) {
    const MINIMUM_DRAG_PIXELS = 10;

    const that = this;

    const draggedElement = document.getElementById(data.draggableId);
    const beaconType = "data-" + data.dragType + "-beacon";
    const dragContainer = data.dragType + "-container";

    var timer: ReturnType<typeof setTimeout>;

    document.addEventListener("mousemove", maybeDragMove);
    document.addEventListener("mouseup", stopAwaitingDrag);

    function maybeDragMove(moveEvent: MouseEvent) {
      const dragDistance = distance({ x: data.clientPos.x, y: data.clientPos.y}, coords(moveEvent));

      if (dragDistance >= MINIMUM_DRAG_PIXELS) {
        dragEvent("move", moveEvent);

        document.removeEventListener("mousemove", maybeDragMove);
        document.removeEventListener("mouseup", stopAwaitingDrag);

        document.addEventListener("mousemove", dragMove);
        document.addEventListener("mouseup", dragEnd);
      }
    }

    function dragMove(event: MouseEvent) {
      dragEvent("move", event);
    }

    function dragEnd(event: MouseEvent) {
      if (data.dragType === "todoseq-card-board-card") {
        that.handleCardDrop(data.draggableId, event);
      }
      dragEvent("stop", event);
      document.removeEventListener("mousemove", dragMove);
      document.removeEventListener("mouseup", dragEnd);
    }

    function stopAwaitingDrag(event: MouseEvent) {
      dragEvent("stop", event);
      document.removeEventListener("mousemove", maybeDragMove);
      document.removeEventListener("mouseup", stopAwaitingDrag);
    }

    function dragEvent(dragAction: "move" | "stop", event: MouseEvent) {
      const tabHeader   = document.getElementsByClassName("workspace-tab-header-container")[1];
      const ribbon      = document.getElementsByClassName("workspace-ribbon")[0];
      const leftSplit   = document.getElementsByClassName("workspace-split")[0];

      const container    = document.getElementsByClassName(dragContainer)[0];

      if ((dragAction == "move") && (container instanceof HTMLElement)) {
        const scrollable = new Scrollable(container, event);

        if (!scrollable.isInScrollableEdge()) {
          clearTimeout(timer);
        } else {
          (function checkForWindowScroll() {
            clearTimeout(timer);

            if (scrollable.doScroll()) {
              timer = setTimeout(checkForWindowScroll, 30);
            }
          })();
        }
      }

      if (dragAction == "move") {
        if ((ribbon instanceof HTMLElement) &&
            (leftSplit instanceof HTMLElement) &&
            (draggedElement instanceof HTMLElement)) {
            const offsetLeft = ribbon.clientWidth + leftSplit.clientWidth;
            const offsetTop  = tabHeader.clientHeight;

            const draggedElementRect = draggedElement.getBoundingClientRect();

            that.elm.ports.interopToElm.send({
              tag: "elementDragged",
              data: {
                dragType: data.dragType,
                dragAction: dragAction,
                cursor: coords(event),
                offset: { x: offsetLeft, y: offsetTop },
                draggedNodeRect: {
                  x: draggedElementRect.x,
                  y: draggedElementRect.y,
                  width: draggedElementRect.width,
                  height: draggedElementRect.height
                },
                beacons: beaconPositions(beaconType)
              }
            });
        }
      } else {
            that.elm.ports.interopToElm.send({
              tag: "elementDragged",
              data: {
                dragType: data.dragType,
                dragAction: "stop",
                cursor: coords(event),
                offset: { x: 0, y: 0 },
                draggedNodeRect: { x: 0, y: 0, width: 0, height: 0 },
                beacons: []
              }
            });
      }
    }

    function beaconPositions(beaconType: String) {
      const beaconElements = document.querySelectorAll(`[${beaconType}]`);
      return Array.from(beaconElements).map(beaconData);
    }

    function beaconData(elem: Element) {
      const boundingRect = elem.getBoundingClientRect();
      const beaconId = elem.getAttribute(beaconType);
      return {
        beaconPosition: tryParse(beaconId),
        rect: {
          x: boundingRect.x,
          y: boundingRect.y,
          width: boundingRect.width,
          height: boundingRect.height
        }
      };
    }

    function tryParse(str: string) {
      try {
        return JSON.parse(str);
      } catch (e) {
        return str;
      }
    }

    function coords(event: MouseEvent) {
      return { x: event.clientX, y: event.clientY };
    }

    function distance(pos1: { x : number, y : number }, pos2: { x : number, y : number }) {
      const dx = pos1.x - pos2.x;
      const dy = pos1.y - pos2.y;
      return Math.sqrt(Math.pow(dx, 2) + Math.pow(dy, 2));
    }
  }

  async handleUpdateSettings(data : TodoSeqCardBoardPluginSettingsPostV11 | any) {
    await this.plugin.saveSettings(data as TodoSeqCardBoardPluginSettingsPostV11);
    await this.plugin.refreshAllTasks();

    this.elm.ports.interopToElm.send({
      tag: "settingsUpdated",
      data: data
    });
  }

  taskItemsRefreshed(taskItems: TaskItem[]) {
    console.debug("TodoSeqCardBoard: [view] toView <- taskItemsRefreshed: " + taskItems.length);
    (this as any).lastTaskItems = taskItems;

    this.elm.ports.interopToElm.send({
      tag: "taskItemsRefreshed",
      data: taskItems
    });
  }

  taskItemsAdded(taskItems: TaskItem[]) {
    (this as any).lastTaskItems = [ ...((this as any).lastTaskItems ?? []), ...taskItems ];
    this.elm.ports.interopToElm.send({
      tag: "taskItemsAdded",
      data: taskItems
    });
  }

  taskItemsDeleted(taskIds: string[]) {
    console.debug("TodoSeqCardBoard: [view] toView <- taskItemsDeleted: " + taskIds.length);
    const deleted = new Set(taskIds);
    (this as any).lastTaskItems = (((this as any).lastTaskItems ?? []) as TaskItem[]).filter((item) => !deleted.has(this.taskItemDomId(item)));

    this.elm.ports.interopToElm.send({
      tag: "taskItemsDeleted",
      data: taskIds
    });
  }

  taskItemsDeletedAndAdded(toDeleteAndAdd : [string[], TaskItem[]]) {
    console.debug("TodoSeqCardBoard: [view] toView <- taskItemsDeletedAndAdded: (" + toDeleteAndAdd[0].length + ", " + toDeleteAndAdd[1].length + ")");
    const deleted = new Set(toDeleteAndAdd[0]);
    (this as any).lastTaskItems = [ ...(((this as any).lastTaskItems ?? []) as TaskItem[]).filter((item) => !deleted.has(this.taskItemDomId(item))), ...toDeleteAndAdd[1] ];

    this.elm.ports.interopToElm.send({
      tag: "taskItemsDeletedAndAdded",
      data: toDeleteAndAdd
    });
  }

  taskItemsUpdated(updateDetails : [string, TaskItem][]) {
    console.debug("TodoSeqCardBoard: [view] toView <- taskItemsUpdated: " + updateDetails.length);
    const updates = new Map(updateDetails);
    (this as any).lastTaskItems = (((this as any).lastTaskItems ?? []) as TaskItem[]).map((item) => updates.get(this.taskItemDomId(item)) ?? item);

    this.elm.ports.interopToElm.send({
      tag: "taskItemsUpdated",
      data: updateDetails
    });
  }

  todoSeqDependencyError(error: string) {
    console.error("TodoSeqCardBoard: [view] TODOseq dependency error: " + error);
    this.elmDiv?.empty?.();
    const errorEl = this.elmDiv?.createDiv?.({ cls: "todoseq-card-board-error" });
    errorEl?.createEl?.("h2", { text: "TODOseq Card Board cannot scan tasks" });
    errorEl?.createEl?.("p", { text: error });
  }

  async handleUpdateTasks(
    data: {
      filePath: string,
      tasks: { lineNumber: number, originalLine: string, newText: string }[]
  }) {
    const file = this.app.vault.getAbstractFileByPath(data.filePath)

    if (file instanceof TFile) {
      const markdown      = await this.vault.read(file)
      const markdownLines = markdown.split(/\r?\n/)

      for (const item of data.tasks) {
        if (markdownLines[item.lineNumber - 1].includes(item.originalLine)) {
          markdownLines[item.lineNumber - 1] = item.newText
        }
      }
      this.vault.modify(file, markdownLines.join("\n"))
    }
  }


  async handleCardDrop(draggableId: string, event: MouseEvent) {
    const taskId = document.getElementById(draggableId)?.getAttribute('data-todoseq-task-id') ?? draggableId;
    const target = document.elementFromPoint(event.clientX, event.clientY)?.closest('[data-todoseq-column-id]');
    if (!(target instanceof HTMLElement)) return;

    const columnId = target.getAttribute('data-todoseq-column-id');
    if (!columnId) return;

    await this.handleTodoSeqMoveTaskToColumn({
      taskId,
      columnId,
      defaultKeyword: target.getAttribute('data-todoseq-column-default-keyword'),
    });
  }

  private resolveTodoSeqColumn(columnId: string, defaultKeyword: string | null): BoardColumn | null {
    const columns = this.plugin.todoSeqColumnsForCurrentBoard();
    const found = columns.find((column) => column.id === columnId || column.name === columnId);
    if (!found) return null;
    return defaultKeyword ? { ...found, defaultKeyword } : found;
  }

  private taskItemFromDomId(taskId: string): TaskItem | null {
    const normalized = taskId.split(':').slice(-2).join(':');
    const leafTasks = (this as any).lastTaskItems as TaskItem[] | undefined;
    return leafTasks?.find((item) => {
      const ids = this.taskItemLookupIds(item);
      return ids.includes(taskId) || ids.includes(normalized);
    }) ?? null;
  }

  private taskItemDomId(taskItem: TaskItem): string {
    return `${fnv1aHash(taskItem.fields.filePath)}:${this.taskItemStableKey(taskItem)}`;
  }

  private taskItemLookupIds(taskItem: TaskItem): string[] {
    const filePath = taskItem.fields.filePath;
    const lineNumber = taskItem.fields.lineNumber;
    const sourceFile = taskItem.fields.todoSeq?.sourceFile;
    const sourceLine = taskItem.fields.todoSeq?.sourceLine;
    const stableId = this.taskItemDomId(taskItem);
    return [
      stableId,
      `${fnv1aHash(filePath)}:${lineNumber}`,
      `${fnv1aHashSigned(filePath)}:${lineNumber}`,
      `${filePath}:${lineNumber}`,
      sourceFile && sourceLine ? `${sourceFile}:${sourceLine}` : null,
    ].filter((id): id is string => typeof id === 'string');
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

  // THESE SEND MESSAGES TO THE ELM APPLICATION
  async handleActiveLeafChange(
    leaf: WorkspaceLeaf | null
  ) {
    let isActive: boolean = false;

    if (leaf.view.getViewType() == "todoseq-card-board-view") {
      isActive = true
    }

    this.elm.ports.interopToElm.send({
      tag: "activeStateUpdated",
      data: isActive
    });
  }

  async handleConfigChanged() {
    this.elm.ports.interopToElm.send({
      tag: "configChanged",
      data: {
        rightToLeft: (this.app.vault as any).getConfig("rightToLeft"),
      }
    });
  }

  // HELPERS

  formattedFileDate(
    file: TFile
  ): string | null {
    return getDateFromFile(file, "day")?.format('YYYY-MM-DD') || null;
  }

  randomId(length: number): string {
      let result = '';
      const characters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
      const charactersLength = characters.length;
      let counter = 0;
      while (counter < length) {
        result += characters.charAt(Math.floor(Math.random() * charactersLength));
        counter += 1;
      }
      return result;
  }

  async openOrSwitchWithHighlight(
    app: App,
    filePath: string,
    lineNumber: number
  ): Promise<void> {
    const { workspace } = app;

    const directFile = app.vault.getAbstractFileByPath(filePath);
    let destFile = directFile instanceof TFile
      ? directFile
      : app.metadataCache.getFirstLinkpathDest(filePath, "");

    if (!destFile) {
       new Notice(`找不到任务源文件: ${filePath}`);
       return;
    }

    const leavesWithDestAlreadyOpen: WorkspaceLeaf[] = [];

    workspace.iterateAllLeaves((leaf) => {
      if (leaf.view instanceof MarkdownView) {
        if (leaf.view?.file?.path === filePath) {
          leavesWithDestAlreadyOpen.push(leaf);
        }
      }
    });

    let leaf: WorkspaceLeaf;

    if (leavesWithDestAlreadyOpen.length > 0) {
      leaf = leavesWithDestAlreadyOpen[0];
      await workspace.setActiveLeaf(leaf);
    } else {
      leaf = workspace.splitActiveLeaf();
      await leaf.openFile(destFile);
    }

    leaf.setEphemeralState({ line: lineNumber - 1 });
  }
}

function cssEscape(value: string): string {
  return value.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

function taskLineIndent(line: string): number | null {
  const match = /^(\s*)[-*+]\s+\[[ xX-]\]/.exec(line || "");
  if (!match) return null;
  return match[1].replace(/\t/g, "    ").length;
}

function fnv1aHash(value: string): number {
  let h = 0x811c9dc5;
  for (const byte of utf8Bytes(value)) {
    h ^= byte;
    h = Math.imul(h, 16777619) >>> 0;
  }
  return h >>> 0;
}

function fnv1aHashSigned(value: string): number {
  return fnv1aHash(value) | 0;
}

function utf8Bytes(value: string): number[] {
  return Array.from(new TextEncoder().encode(value));
}

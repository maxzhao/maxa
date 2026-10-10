import { TodoSeqBoardTask } from './todoseqAdapter';
import { KeywordManager, KeywordSettings } from './todoseq/utils/keyword-manager';
import { KeywordGroup } from './todoseq/types/task';

export type TodoSeqKeywordGroup = 'inactive' | 'active' | 'waiting' | 'completed' | 'archived';
export type TodoSeqColumnKind =
  | 'state'
  | 'keywordGroup'
  | 'priority'
  | 'scheduledBucket'
  | 'deadlineBucket'
  | 'closedBucket'
  | 'tag'
  | 'urgencyBucket'
  | 'dailyNote'
  | 'source'
  | 'subtaskProgress'
  | 'customFilter';
export type TodoSeqPriorityValue = TodoSeqBoardTask['priority'] | 'none';
export type TodoSeqDateBucket = 'none' | 'overdue' | 'today' | 'upcoming' | 'future';
export type TodoSeqClosedBucket = 'open' | 'closed' | 'closedToday' | 'closedPast';
export type TodoSeqUrgencyBucket = 'none' | 'low' | 'medium' | 'high';
export type TodoSeqDailyNoteBucket = 'daily' | 'notDaily' | 'date';
export type TodoSeqSourceBucket = 'file' | 'folder';
export type TodoSeqSubtaskProgressBucket = 'none' | 'notStarted' | 'inProgress' | 'complete';

export type TodoSeqColumnMatch = {
  states?: string[];
  group?: TodoSeqKeywordGroup;
  priority?: TodoSeqPriorityValue;
  scheduledBucket?: TodoSeqDateBucket;
  deadlineBucket?: TodoSeqDateBucket;
  closedBucket?: TodoSeqClosedBucket;
  tag?: string;
  urgencyBucket?: TodoSeqUrgencyBucket;
  dailyNote?: { bucket: TodoSeqDailyNoteBucket; date?: string };
  source?: { bucket: TodoSeqSourceBucket; value: string };
  subtaskProgress?: TodoSeqSubtaskProgressBucket;
  customFilter?: TodoSeqColumnFilter;
};

export type TodoSeqColumnFilter = {
  states?: string[];
  groups?: TodoSeqKeywordGroup[];
  priorities?: TodoSeqPriorityValue[];
  scheduledBuckets?: TodoSeqDateBucket[];
  deadlineBuckets?: TodoSeqDateBucket[];
  closedBuckets?: TodoSeqClosedBucket[];
  tags?: string[];
  urgencyBuckets?: TodoSeqUrgencyBucket[];
  dailyNote?: { bucket: TodoSeqDailyNoteBucket; date?: string };
  source?: { bucket: TodoSeqSourceBucket; value: string };
  subtaskProgress?: TodoSeqSubtaskProgressBucket[];
};

export type TodoSeqColumnSort = {
  dateStrategy?: DateSortStrategy;
  ascending?: boolean;
};

export type TodoSeqColumnWriteTarget =
  | { property: 'state'; keyword: string }
  | { property: 'keywordGroup'; group: TodoSeqKeywordGroup; keyword: string }
  | { property: 'priority'; priority: TodoSeqBoardTask['priority'] }
  | { property: 'scheduledDate'; bucket: TodoSeqDateBucket; date?: string }
  | { property: 'deadlineDate'; bucket: TodoSeqDateBucket; date?: string };

export type BoardColumn = {
  id: string;
  name: string;
  title?: string;
  kind?: TodoSeqColumnKind;
  match?: TodoSeqColumnMatch;
  sort?: TodoSeqColumnSort;
  writable?: boolean;
  writeTarget?: TodoSeqColumnWriteTarget;
  type?: 'keyword' | 'group' | 'custom';
  keywords: string[];
  group?: TodoSeqKeywordGroup;
  defaultKeyword?: string;
};

export type BoardColumnPresetId = 'keywords' | 'groups' | 'priority' | 'scheduled' | 'deadline' | 'urgency' | 'custom';

export type DateDisplayStrategy = 'scheduled' | 'deadline' | 'both';
export type DateSortStrategy = 'scheduled-first' | 'deadline-first' | 'nearest-date' | 'urgency-first';
export type DateFilterStrategy = 'overdue' | 'today' | 'upcoming' | 'no-date';

export type BoardFilters = {
  states?: string[];
  groups?: TodoSeqKeywordGroup[];
  priorities?: Array<TodoSeqBoardTask['priority']>;
  date?: DateFilterStrategy;
  urgency?: { min?: number; max?: number };
  tags?: string[];
};

export type BoardSort = {
  dateStrategy?: DateSortStrategy;
  ascending?: boolean;
};

export type TodoSeqCardModel = {
  id: string;
  text: string;
  state: string;
  group: TodoSeqKeywordGroup | null;
  scheduledDate: Date | null;
  deadlineDate: Date | null;
  closedDate: Date | null;
  priority: TodoSeqBoardTask['priority'];
  subtaskProgress: { completed: number; total: number };
  urgency: number | null;
  tags: string[];
  source: { file: string; line: number };
  dailyNote: { isDailyNote: boolean; date: Date | null };
  task: TodoSeqBoardTask;
};

const GROUP_TO_KEYWORD_GROUP: Record<TodoSeqKeywordGroup, KeywordGroup> = {
  inactive: 'inactiveKeywords',
  active: 'activeKeywords',
  waiting: 'waitingKeywords',
  completed: 'completedKeywords',
  archived: 'archivedKeywords',
};

const GROUP_NAMES: Record<TodoSeqKeywordGroup, string> = {
  inactive: 'Inactive',
  active: 'Active',
  waiting: 'Waiting',
  completed: 'Completed',
  archived: 'Archived',
};

const GROUP_ORDER: TodoSeqKeywordGroup[] = ['inactive', 'active', 'waiting', 'completed', 'archived'];
const DATE_BUCKETS: Array<{ bucket: TodoSeqDateBucket; title: string }> = [
  { bucket: 'none', title: 'No date' },
  { bucket: 'overdue', title: 'Overdue' },
  { bucket: 'today', title: 'Today' },
  { bucket: 'upcoming', title: 'Upcoming' },
  { bucket: 'future', title: 'Future' },
];
const PRIORITY_PRESET: Array<{ priority: TodoSeqPriorityValue; title: string }> = [
  { priority: 'high', title: 'High' },
  { priority: 'med', title: 'Medium' },
  { priority: 'low', title: 'Low' },
  { priority: 'none', title: 'No priority' },
];
const URGENCY_BUCKETS: Array<{ bucket: TodoSeqUrgencyBucket; title: string }> = [
  { bucket: 'high', title: 'High urgency' },
  { bucket: 'medium', title: 'Medium urgency' },
  { bucket: 'low', title: 'Low urgency' },
  { bucket: 'none', title: 'No urgency' },
];

export function getTaskGroup(task: TodoSeqBoardTask, keywordManager: KeywordManager): TodoSeqKeywordGroup | null {
  const group = keywordManager.getGroup(task.state);
  switch (group) {
    case 'inactiveKeywords': return 'inactive';
    case 'activeKeywords': return 'active';
    case 'waitingKeywords': return 'waiting';
    case 'completedKeywords': return 'completed';
    case 'archivedKeywords': return 'archived';
    default: return null;
  }
}

export function buildKeywordPreset(settings: KeywordSettings): BoardColumn[] {
  const keywordManager = new KeywordManager(settings);
  return GROUP_ORDER.flatMap((group) =>
    keywordManager.getKeywordsForGroup(GROUP_TO_KEYWORD_GROUP[group]).map((keyword) => ({
      id: `state:${keyword}`,
      name: keyword,
      title: keyword,
      kind: 'state' as const,
      match: { states: [keyword] },
      writable: true,
      writeTarget: { property: 'state' as const, keyword },
      type: 'keyword' as const,
      keywords: [keyword],
      group,
      defaultKeyword: keyword,
    })),
  );
}

export function buildGroupPreset(settings: KeywordSettings): BoardColumn[] {
  const keywordManager = new KeywordManager(settings);
  return GROUP_ORDER.map((group) => {
    const keywords = keywordManager.getKeywordsForGroup(GROUP_TO_KEYWORD_GROUP[group]);
    const defaultKeyword = defaultKeywordForGroup(group, keywordManager, keywords);
    return {
      id: `keywordGroup:${group}`,
      name: GROUP_NAMES[group],
      title: GROUP_NAMES[group],
      kind: 'keywordGroup' as const,
      match: { group },
      writable: true,
      writeTarget: defaultKeyword ? { property: 'keywordGroup' as const, group, keyword: defaultKeyword } : undefined,
      type: 'group' as const,
      keywords,
      group,
      defaultKeyword,
    };
  });
}

export function buildPriorityPreset(): BoardColumn[] {
  return PRIORITY_PRESET.map(({ priority, title }) => ({
    id: `priority:${priority}`,
    name: title,
    title,
    kind: 'priority',
    match: { priority },
    writable: true,
    writeTarget: { property: 'priority', priority: priority === 'none' ? null : priority },
    type: 'custom' as const,
    keywords: [],
  }));
}

export function buildScheduledBucketPreset(): BoardColumn[] {
  return DATE_BUCKETS.map(({ bucket, title }) => dateBucketColumn('scheduledBucket', bucket, title));
}

export function buildDeadlineBucketPreset(): BoardColumn[] {
  return DATE_BUCKETS.map(({ bucket, title }) => dateBucketColumn('deadlineBucket', bucket, title));
}

export function buildClosedBucketPreset(): BoardColumn[] {
  const buckets: Array<{ bucket: TodoSeqClosedBucket; title: string }> = [
    { bucket: 'open', title: 'Open' },
    { bucket: 'closed', title: 'Closed' },
    { bucket: 'closedToday', title: 'Closed today' },
    { bucket: 'closedPast', title: 'Closed before today' },
  ];
  return buckets.map(({ bucket, title }) => ({
    id: `closedBucket:${bucket}`,
    name: title,
    title,
    kind: 'closedBucket' as const,
    match: { closedBucket: bucket },
    writable: false,
    type: 'custom' as const,
    keywords: [],
  }));
}

export function buildTagColumn(tag: string, title = tag): BoardColumn {
  return {
    id: `tag:${normalizeTag(tag)}`,
    name: title,
    title,
    kind: 'tag',
    match: { tag: normalizeTag(tag) },
    writable: false,
    type: 'custom',
    keywords: [],
  };
}

export function buildUrgencyBucketPreset(): BoardColumn[] {
  return URGENCY_BUCKETS.map(({ bucket, title }) => ({
    id: `urgencyBucket:${bucket}`,
    name: title,
    title,
    kind: 'urgencyBucket' as const,
    match: { urgencyBucket: bucket },
    writable: false,
    type: 'custom' as const,
    keywords: [],
  }));
}

export function buildDailyNotePreset(): BoardColumn[] {
  return [
    { id: 'dailyNote:daily', name: 'Daily notes', title: 'Daily notes', kind: 'dailyNote' as const, match: { dailyNote: { bucket: 'daily' as const } }, writable: false, type: 'custom' as const, keywords: [] },
    { id: 'dailyNote:notDaily', name: 'Not daily notes', title: 'Not daily notes', kind: 'dailyNote' as const, match: { dailyNote: { bucket: 'notDaily' as const } }, writable: false, type: 'custom' as const, keywords: [] },
  ];
}

export function buildSourceColumn(source: { bucket: TodoSeqSourceBucket; value: string }, title = source.value): BoardColumn {
  return {
    id: `source:${source.bucket}:${source.value}`,
    name: title,
    title,
    kind: 'source',
    match: { source },
    writable: false,
    type: 'custom',
    keywords: [],
  };
}

export function buildSubtaskProgressPreset(): BoardColumn[] {
  const buckets: Array<{ bucket: TodoSeqSubtaskProgressBucket; title: string }> = [
    { bucket: 'none', title: 'No subtasks' },
    { bucket: 'notStarted', title: 'Subtasks not started' },
    { bucket: 'inProgress', title: 'Subtasks in progress' },
    { bucket: 'complete', title: 'Subtasks complete' },
  ];
  return buckets.map(({ bucket, title }) => ({
    id: `subtaskProgress:${bucket}`,
    name: title,
    title,
    kind: 'subtaskProgress' as const,
    match: { subtaskProgress: bucket },
    writable: false,
    type: 'custom' as const,
    keywords: [],
  }));
}

export function buildCustomFilterColumn(id: string, title: string, filter: TodoSeqColumnFilter): BoardColumn {
  return {
    id: id || `customFilter:${title}`,
    name: title,
    title,
    kind: 'customFilter',
    match: { customFilter: filter },
    writable: false,
    type: 'custom',
    keywords: filter.states ?? [],
  };
}

export function normalizeCustomColumns(columns: BoardColumn[], settings: KeywordSettings): BoardColumn[] {
  const keywordManager = new KeywordManager(settings);
  return columns.map((column, index) => normalizeColumn(column, keywordManager, index));
}

export function buildCardModel(task: TodoSeqBoardTask, keywordManager: KeywordManager): TodoSeqCardModel {
  return {
    id: `${task.path}:${task.line}`,
    text: task.displayText ?? task.text,
    state: task.state,
    group: getTaskGroup(task, keywordManager),
    scheduledDate: task.scheduledDate,
    deadlineDate: task.deadlineDate,
    closedDate: task.closedDate,
    priority: task.priority,
    subtaskProgress: { completed: task.subtaskCompletedCount, total: task.subtaskCount },
    urgency: task.urgency,
    tags: task.tags,
    source: { file: task.path, line: task.line + 1 },
    dailyNote: { isDailyNote: task.isDailyNote, date: task.dailyNoteDate },
    task,
  };
}

export function assignTasksToColumns(
  tasks: TodoSeqBoardTask[],
  columns: BoardColumn[],
  keywordManager: KeywordManager,
  today: Date = new Date(),
): Record<string, TodoSeqCardModel[]> {
  const normalizedColumns = columns.map((column, index) => normalizeColumn(column, keywordManager, index));
  const result: Record<string, TodoSeqCardModel[]> = Object.fromEntries(normalizedColumns.map((column) => [column.id, []]));

  for (const task of tasks) {
    const card = buildCardModel(task, keywordManager);
    for (const column of normalizedColumns) {
      if (matchesColumn(card, column, keywordManager, today)) {
        result[column.id].push(card);
      }
    }
  }

  return result;
}

export function matchesColumn(card: TodoSeqCardModel, column: BoardColumn, keywordManager: KeywordManager, today: Date = new Date()): boolean {
  return matchesColumnFilter(card, normalizeColumn(column, keywordManager), today);
}

export function isColumnWritable(column: BoardColumn): boolean {
  return column.writable === true && column.writeTarget !== undefined;
}

export function readonlyColumnMessage(column: BoardColumn): string {
  return `TODOseq column "${column.name}" is read-only and can only filter/display tasks.`;
}

export function filterCards(cards: TodoSeqCardModel[], filters: BoardFilters, today: Date): TodoSeqCardModel[] {
  return cards.filter((card) => {
    if (filters.states?.length && !filters.states.includes(card.state)) return false;
    if (filters.groups?.length && (!card.group || !filters.groups.includes(card.group))) return false;
    if (filters.priorities?.length && !filters.priorities.includes(card.priority)) return false;
    if (filters.tags?.length && !filters.tags.every((tag) => card.tags.includes(normalizeTag(tag)))) return false;
    if (filters.urgency) {
      const urgency = card.urgency ?? 0;
      if (filters.urgency.min !== undefined && urgency < filters.urgency.min) return false;
      if (filters.urgency.max !== undefined && urgency > filters.urgency.max) return false;
    }
    if (filters.date && !matchesDateFilter(card, filters.date, today)) return false;
    return true;
  });
}

export function sortCards(cards: TodoSeqCardModel[], sort: BoardSort = {}): TodoSeqCardModel[] {
  const strategy = sort.dateStrategy ?? 'urgency-first';
  const direction = sort.ascending === false ? -1 : 1;
  return [...cards].sort((a, b) => direction * compareCards(a, b, strategy));
}

export function selectDisplayDates(card: TodoSeqCardModel, strategy: DateDisplayStrategy): { scheduledDate?: Date | null; deadlineDate?: Date | null } {
  switch (strategy) {
    case 'scheduled': return { scheduledDate: card.scheduledDate };
    case 'deadline': return { deadlineDate: card.deadlineDate };
    case 'both': return { scheduledDate: card.scheduledDate, deadlineDate: card.deadlineDate };
  }
}

function dateBucketColumn(kind: 'scheduledBucket' | 'deadlineBucket', bucket: TodoSeqDateBucket, title: string): BoardColumn {
  const dateTitle = kind === 'scheduledBucket' ? `Scheduled: ${title}` : `Deadline: ${title}`;
  return {
    id: `${kind}:${bucket}`,
    name: dateTitle,
    title: dateTitle,
    kind,
    match: kind === 'scheduledBucket' ? { scheduledBucket: bucket } : { deadlineBucket: bucket },
    writable: false,
    type: 'custom',
    keywords: [],
  };
}

function normalizeColumn(column: BoardColumn, keywordManager: KeywordManager, index = 0): BoardColumn {
  const type = column.type ?? legacyTypeForKind(column.kind);
  const keywords = unique((column.keywords ?? column.match?.states ?? []).map((keyword) => keyword.trim().toUpperCase()).filter(Boolean));
  const group = column.group ?? column.match?.group ?? (keywords[0] ? getTaskGroup({ state: keywords[0] } as TodoSeqBoardTask, keywordManager) ?? undefined : undefined);
  const defaultKeyword = column.defaultKeyword?.trim().toUpperCase() || defaultKeywordFromWriteTarget(column.writeTarget) || keywords[0];
  const kind = column.kind ?? legacyKind(type);
  const match = normalizeMatch(column.match ?? {}, kind, keywords, group, column);
  const writeTarget = column.writeTarget ?? defaultWriteTarget(kind, match, group, defaultKeyword);
  const writable = column.writable ?? Boolean(writeTarget);
  return {
    ...column,
    id: column.id || `${kind}:${index}:${column.name}`,
    title: column.title ?? column.name,
    kind,
    match,
    type,
    keywords,
    group,
    defaultKeyword,
    writable,
    writeTarget,
  };
}

function normalizeMatch(match: TodoSeqColumnMatch, kind: TodoSeqColumnKind, keywords: string[], group: TodoSeqKeywordGroup | undefined, column: BoardColumn): TodoSeqColumnMatch {
  if (kind === 'state') return { ...match, states: match.states ?? keywords };
  if (kind === 'keywordGroup') return { ...match, group: match.group ?? group };
  if (kind === 'customFilter') return { customFilter: match.customFilter ?? { states: keywords } };
  if (column.type === 'custom' && keywords.length && !Object.keys(match).length) return { customFilter: { states: keywords } };
  return match;
}

function defaultWriteTarget(kind: TodoSeqColumnKind, match: TodoSeqColumnMatch, group: TodoSeqKeywordGroup | undefined, defaultKeyword: string | undefined): TodoSeqColumnWriteTarget | undefined {
  if (kind === 'state' && defaultKeyword) return { property: 'state', keyword: defaultKeyword };
  if (kind === 'keywordGroup' && group && defaultKeyword) return { property: 'keywordGroup', group, keyword: defaultKeyword };
  if (kind === 'priority' && match.priority !== undefined) return { property: 'priority', priority: match.priority === 'none' ? null : match.priority };
  return undefined;
}

function defaultKeywordFromWriteTarget(writeTarget: TodoSeqColumnWriteTarget | undefined): string | undefined {
  if (!writeTarget) return undefined;
  if (writeTarget.property === 'state' || writeTarget.property === 'keywordGroup') return writeTarget.keyword;
  return undefined;
}

function legacyKind(type: BoardColumn['type']): TodoSeqColumnKind {
  if (type === 'keyword') return 'state';
  if (type === 'group') return 'keywordGroup';
  return 'customFilter';
}

function legacyTypeForKind(kind: TodoSeqColumnKind): 'keyword' | 'group' | 'custom' {
  if (kind === 'state') return 'keyword';
  if (kind === 'keywordGroup') return 'group';
  return 'custom';
}

function matchesColumnFilter(card: TodoSeqCardModel, column: BoardColumn, today: Date): boolean {
  const match = column.match;
  switch (column.kind) {
    case 'state': return Boolean(match.states?.includes(card.state));
    case 'keywordGroup': return Boolean(match.group && card.group === match.group);
    case 'priority': return priorityValue(card) === match.priority;
    case 'scheduledBucket': return dateBucket(card.scheduledDate, today) === match.scheduledBucket;
    case 'deadlineBucket': return dateBucket(card.deadlineDate, today) === match.deadlineBucket;
    case 'closedBucket': return closedBucket(card.closedDate, today) === match.closedBucket;
    case 'tag': return Boolean(match.tag && card.tags.includes(normalizeTag(match.tag)));
    case 'urgencyBucket': return urgencyBucket(card.urgency) === match.urgencyBucket;
    case 'dailyNote': return matchesDailyNote(card, match.dailyNote);
    case 'source': return matchesSource(card, match.source);
    case 'subtaskProgress': return subtaskProgressBucket(card) === match.subtaskProgress;
    case 'customFilter': return matchesCustomFilter(card, match.customFilter, today);
  }
}

function matchesCustomFilter(card: TodoSeqCardModel, filter: TodoSeqColumnFilter | undefined, today: Date): boolean {
  if (!filter) return false;
  if (filter.states?.length && !filter.states.includes(card.state)) return false;
  if (filter.groups?.length && (!card.group || !filter.groups.includes(card.group))) return false;
  if (filter.priorities?.length && !filter.priorities.includes(priorityValue(card))) return false;
  if (filter.scheduledBuckets?.length && !filter.scheduledBuckets.includes(dateBucket(card.scheduledDate, today))) return false;
  if (filter.deadlineBuckets?.length && !filter.deadlineBuckets.includes(dateBucket(card.deadlineDate, today))) return false;
  if (filter.closedBuckets?.length && !filter.closedBuckets.includes(closedBucket(card.closedDate, today))) return false;
  if (filter.tags?.length && !filter.tags.every((tag) => card.tags.includes(normalizeTag(tag)))) return false;
  if (filter.urgencyBuckets?.length && !filter.urgencyBuckets.includes(urgencyBucket(card.urgency))) return false;
  if (filter.dailyNote && !matchesDailyNote(card, filter.dailyNote)) return false;
  if (filter.source && !matchesSource(card, filter.source)) return false;
  if (filter.subtaskProgress?.length && !filter.subtaskProgress.includes(subtaskProgressBucket(card))) return false;
  return true;
}

function matchesDailyNote(card: TodoSeqCardModel, dailyNote: TodoSeqColumnMatch['dailyNote']): boolean {
  if (!dailyNote) return false;
  if (dailyNote.bucket === 'daily') return card.dailyNote.isDailyNote;
  if (dailyNote.bucket === 'notDaily') return !card.dailyNote.isDailyNote;
  return Boolean(card.dailyNote.date && dayString(card.dailyNote.date) === dailyNote.date);
}

function matchesSource(card: TodoSeqCardModel, source: TodoSeqColumnMatch['source']): boolean {
  if (!source) return false;
  if (source.bucket === 'file') return card.source.file === source.value;
  return card.source.file === source.value || card.source.file.startsWith(source.value.replace(/\/$/, '') + '/');
}

function priorityValue(card: TodoSeqCardModel): TodoSeqPriorityValue {
  return card.priority ?? 'none';
}

function dateBucket(date: Date | null | undefined, today: Date): TodoSeqDateBucket {
  if (!date) return 'none';
  const diffDays = Math.round((dayKey(date) - dayKey(today)) / 86400000);
  if (diffDays < 0) return 'overdue';
  if (diffDays === 0) return 'today';
  if (diffDays <= 7) return 'upcoming';
  return 'future';
}

function closedBucket(date: Date | null | undefined, today: Date): TodoSeqClosedBucket {
  if (!date) return 'open';
  if (dayKey(date) === dayKey(today)) return 'closedToday';
  if (dayKey(date) < dayKey(today)) return 'closedPast';
  return 'closed';
}

function urgencyBucket(urgency: number | null | undefined): TodoSeqUrgencyBucket {
  if (urgency === null || urgency === undefined || urgency <= 0) return 'none';
  if (urgency >= 10) return 'high';
  if (urgency >= 5) return 'medium';
  return 'low';
}

function subtaskProgressBucket(card: TodoSeqCardModel): TodoSeqSubtaskProgressBucket {
  const total = card.subtaskProgress.total;
  if (total <= 0) return 'none';
  if (card.subtaskProgress.completed <= 0) return 'notStarted';
  if (card.subtaskProgress.completed >= total) return 'complete';
  return 'inProgress';
}

function compareCards(a: TodoSeqCardModel, b: TodoSeqCardModel, strategy: DateSortStrategy): number {
  switch (strategy) {
    case 'scheduled-first': return compareDates(a.scheduledDate, b.scheduledDate) || compareDates(a.deadlineDate, b.deadlineDate) || compareUrgencyDesc(a, b);
    case 'deadline-first': return compareDates(a.deadlineDate, b.deadlineDate) || compareDates(a.scheduledDate, b.scheduledDate) || compareUrgencyDesc(a, b);
    case 'nearest-date': return compareDates(nearestDate(a), nearestDate(b)) || compareUrgencyDesc(a, b);
    case 'urgency-first': return compareUrgencyDesc(a, b) || compareDates(nearestDate(a), nearestDate(b));
  }
}

function matchesDateFilter(card: TodoSeqCardModel, filter: DateFilterStrategy, today: Date): boolean {
  const dates = [card.scheduledDate, card.deadlineDate].filter((date): date is Date => date instanceof Date);
  const todayKey = dayKey(today);
  switch (filter) {
    case 'no-date': return dates.length === 0;
    case 'overdue': return dates.some((date) => dayKey(date) < todayKey);
    case 'today': return dates.some((date) => dayKey(date) === todayKey);
    case 'upcoming': return dates.some((date) => dayKey(date) > todayKey);
  }
}

function defaultKeywordForGroup(group: TodoSeqKeywordGroup, keywordManager: KeywordManager, keywords: string[]): string | undefined {
  switch (group) {
    case 'inactive': return keywordManager.getDefaultInactive();
    case 'active': return keywordManager.getDefaultActive();
    case 'completed': return keywordManager.getDefaultCompleted();
    case 'waiting': return keywords.includes('WAIT') ? 'WAIT' : keywords[0];
    case 'archived': return keywords.includes('ARCHIVED') ? 'ARCHIVED' : keywords[0];
  }
}

function compareDates(a: Date | null | undefined, b: Date | null | undefined): number {
  if (a && b) return dayKey(a) - dayKey(b);
  if (a) return -1;
  if (b) return 1;
  return 0;
}

function compareUrgencyDesc(a: TodoSeqCardModel, b: TodoSeqCardModel): number {
  return (b.urgency ?? Number.NEGATIVE_INFINITY) - (a.urgency ?? Number.NEGATIVE_INFINITY);
}

function nearestDate(card: TodoSeqCardModel): Date | null {
  const dates = [card.scheduledDate, card.deadlineDate].filter((date): date is Date => date instanceof Date);
  return dates.sort((a, b) => dayKey(a) - dayKey(b))[0] ?? null;
}

function dayKey(date: Date): number {
  return Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate());
}

function dayString(date: Date): string {
  return date.toISOString().slice(0, 10);
}

function normalizeTag(tag: string): string {
  const trimmed = tag.trim();
  return trimmed.startsWith('#') ? trimmed.slice(1) : trimmed;
}

function unique(values: string[]): string[] {
  return Array.from(new Set(values));
}

import { KeywordManager } from '../typescript/todoseq/utils/keyword-manager';
import {
  assignTasksToColumns,
  buildCardModel,
  buildClosedBucketPreset,
  buildCustomFilterColumn,
  buildDailyNotePreset,
  buildDeadlineBucketPreset,
  buildGroupPreset,
  buildKeywordPreset,
  buildPriorityPreset,
  buildScheduledBucketPreset,
  buildSourceColumn,
  buildSubtaskProgressPreset,
  buildTagColumn,
  buildUrgencyBucketPreset,
  filterCards,
  isColumnWritable,
  matchesColumn,
  normalizeCustomColumns,
  readonlyColumnMessage,
  selectDisplayDates,
  sortCards,
  TodoSeqCardModel,
} from '../typescript/boardDomain';
import { TodoSeqBoardTask } from '../typescript/todoseqAdapter';

const date = (iso: string) => new Date(`${iso}T00:00:00.000Z`);

function task(overrides: Partial<TodoSeqBoardTask>): TodoSeqBoardTask {
  const text = overrides.text ?? 'task';
  return {
    path: 'Tasks.md',
    line: 0,
    rawText: 'TODO task',
    text,
    displayText: overrides.displayText ?? text,
    state: 'TODO',
    completed: false,
    priority: null,
    scheduledDate: null,
    deadlineDate: null,
    closedDate: null,
    scheduledDateRepeat: null,
    deadlineDateRepeat: null,
    subtaskCount: 0,
    subtaskCompletedCount: 0,
    urgency: null,
    tags: [],
    isDailyNote: false,
    dailyNoteDate: null,
    quoteNestingLevel: 0,
    ...overrides,
  };
}

describe('boardDomain', () => {
  const settings = { additionalActiveKeywords: ['REVIEW'] };
  const keywordManager = new KeywordManager(settings);
  const today = date('2026-05-05');
  const tasks = [
    task({ line: 0, text: 'todo', state: 'TODO' }),
    task({ line: 1, text: 'doing', state: 'DOING', urgency: 42 }),
    task({ line: 2, text: 'review', state: 'REVIEW' }),
    task({ line: 3, text: 'waiting', state: 'WAIT' }),
    task({ line: 4, text: 'done', state: 'DONE', completed: true, closedDate: date('2026-05-05') }),
    task({ line: 5, text: 'archived', state: 'ARCHIVED' }),
  ];

  it('assigns TODOseq tasks to state keyword and keyword group columns', () => {
    const keywordColumns = buildKeywordPreset(settings);
    const groupColumns = buildGroupPreset(settings);
    const customColumns = normalizeCustomColumns([
      { id: 'custom:focus', name: 'Focus', type: 'custom', keywords: ['TODO', 'DOING'], defaultKeyword: 'DOING' },
      { id: 'custom:done', name: 'Done-ish', type: 'custom', keywords: ['DONE', 'ARCHIVED'], defaultKeyword: 'DONE' },
    ], settings);

    expect(keywordColumns.find((column) => column.id === 'state:TODO')?.kind).toBe('state');
    expect(assignTasksToColumns(tasks, keywordColumns, keywordManager)['state:TODO'].map((card) => card.text)).toEqual(['todo']);
    expect(assignTasksToColumns(tasks, keywordColumns, keywordManager)['state:REVIEW'].map((card) => card.text)).toEqual(['review']);

    const grouped = assignTasksToColumns(tasks, groupColumns, keywordManager);
    expect(grouped['keywordGroup:inactive'].map((card) => card.state)).toEqual(['TODO']);
    expect(grouped['keywordGroup:active'].map((card) => card.state)).toEqual(['DOING', 'REVIEW']);
    expect(grouped['keywordGroup:waiting'].map((card) => card.state)).toEqual(['WAIT']);
    expect(grouped['keywordGroup:completed'].map((card) => card.state)).toEqual(['DONE']);
    expect(grouped['keywordGroup:archived'].map((card) => card.state)).toEqual(['ARCHIVED']);

    const custom = assignTasksToColumns(tasks, customColumns, keywordManager);
    expect(custom['custom:focus'].map((card) => card.state)).toEqual(['TODO', 'DOING']);
    expect(custom['custom:done'].map((card) => card.state)).toEqual(['DONE', 'ARCHIVED']);
  });

  it('keeps scheduled and deadline separate in card model and display strategy', () => {
    const card = buildCardModel(
      task({
        state: 'TODO',
        scheduledDate: date('2026-05-06'),
        deadlineDate: date('2026-05-07'),
        closedDate: date('2026-05-08'),
        priority: 'high',
        subtaskCompletedCount: 1,
        subtaskCount: 2,
        urgency: 12.5,
        tags: ['work'],
        isDailyNote: true,
        dailyNoteDate: date('2026-05-05'),
      }),
      keywordManager,
    );

    expect(card.scheduledDate?.toISOString()).toContain('2026-05-06');
    expect(card.deadlineDate?.toISOString()).toContain('2026-05-07');
    expect(card.closedDate?.toISOString()).toContain('2026-05-08');
    expect(card.priority).toBe('high');
    expect(card.subtaskProgress).toEqual({ completed: 1, total: 2 });
    expect(card.urgency).toBe(12.5);
    expect(card.tags).toEqual(['work']);
    expect(card.source).toEqual({ file: 'Tasks.md', line: 1 });
    expect(card.dailyNote.isDailyNote).toBe(true);
    expect(selectDisplayDates(card, 'scheduled')).toEqual({ scheduledDate: card.scheduledDate });
    expect(selectDisplayDates(card, 'deadline')).toEqual({ deadlineDate: card.deadlineDate });
    expect(selectDisplayDates(card, 'both')).toEqual({ scheduledDate: card.scheduledDate, deadlineDate: card.deadlineDate });
  });

  it('matches priority columns', () => {
    const priorityColumns = buildPriorityPreset();
    const high = buildCardModel(task({ priority: 'high' }), keywordManager);
    const none = buildCardModel(task({ priority: null }), keywordManager);

    expect(matchesColumn(high, priorityColumns.find((column) => column.id === 'priority:high')!, keywordManager, today)).toBe(true);
    expect(matchesColumn(high, priorityColumns.find((column) => column.id === 'priority:low')!, keywordManager, today)).toBe(false);
    expect(matchesColumn(none, priorityColumns.find((column) => column.id === 'priority:none')!, keywordManager, today)).toBe(true);
  });

  it('matches scheduled and deadline buckets independently', () => {
    const scheduledColumns = buildScheduledBucketPreset();
    const deadlineColumns = buildDeadlineBucketPreset();
    const card = buildCardModel(task({ scheduledDate: date('2026-05-04'), deadlineDate: date('2026-05-13') }), keywordManager);

    expect(matchesColumn(card, scheduledColumns.find((column) => column.id === 'scheduledBucket:overdue')!, keywordManager, today)).toBe(true);
    expect(matchesColumn(card, deadlineColumns.find((column) => column.id === 'deadlineBucket:future')!, keywordManager, today)).toBe(true);
    expect(matchesColumn(card, scheduledColumns.find((column) => column.id === 'scheduledBucket:future')!, keywordManager, today)).toBe(false);
    expect(matchesColumn(card, deadlineColumns.find((column) => column.id === 'deadlineBucket:overdue')!, keywordManager, today)).toBe(false);
  });

  it('matches closed bucket, tag, urgency, daily note, source, subtask and custom filter columns', () => {
    const card = buildCardModel(task({
      path: 'Projects/Tasks.md',
      line: 2,
      state: 'DOING',
      priority: 'med',
      scheduledDate: date('2026-05-05'),
      deadlineDate: date('2026-05-06'),
      closedDate: date('2026-05-05'),
      tags: ['work', 'deep'],
      urgency: 7,
      isDailyNote: true,
      dailyNoteDate: date('2026-05-05'),
      subtaskCount: 3,
      subtaskCompletedCount: 1,
    }), keywordManager);

    expect(matchesColumn(card, buildClosedBucketPreset().find((column) => column.id === 'closedBucket:closedToday')!, keywordManager, today)).toBe(true);
    expect(matchesColumn(card, buildTagColumn('#work'), keywordManager, today)).toBe(true);
    expect(matchesColumn(card, buildUrgencyBucketPreset().find((column) => column.id === 'urgencyBucket:medium')!, keywordManager, today)).toBe(true);
    expect(matchesColumn(card, buildDailyNotePreset().find((column) => column.id === 'dailyNote:daily')!, keywordManager, today)).toBe(true);
    expect(matchesColumn(card, buildSourceColumn({ bucket: 'folder', value: 'Projects' }), keywordManager, today)).toBe(true);
    expect(matchesColumn(card, buildSubtaskProgressPreset().find((column) => column.id === 'subtaskProgress:inProgress')!, keywordManager, today)).toBe(true);
    expect(matchesColumn(card, buildCustomFilterColumn('custom:work-active', 'Work active', {
      groups: ['active'],
      priorities: ['med'],
      scheduledBuckets: ['today'],
      deadlineBuckets: ['upcoming'],
      tags: ['work'],
      urgencyBuckets: ['medium'],
      dailyNote: { bucket: 'daily' },
      source: { bucket: 'folder', value: 'Projects' },
      subtaskProgress: ['inProgress'],
    }), keywordManager, today)).toBe(true);
  });

  it('marks writable and read-only columns explicitly', () => {
    const stateColumn = buildKeywordPreset(settings).find((column) => column.id === 'state:TODO')!;
    const groupColumn = buildGroupPreset(settings).find((column) => column.id === 'keywordGroup:active')!;
    const priorityColumn = buildPriorityPreset().find((column) => column.id === 'priority:high')!;
    const urgencyColumn = buildUrgencyBucketPreset().find((column) => column.id === 'urgencyBucket:high')!;
    const customColumn = buildCustomFilterColumn('custom:readonly', 'Read-only custom', { tags: ['work'] });

    expect(isColumnWritable(stateColumn)).toBe(true);
    expect(isColumnWritable(groupColumn)).toBe(true);
    expect(isColumnWritable(priorityColumn)).toBe(true);
    expect(isColumnWritable(urgencyColumn)).toBe(false);
    expect(isColumnWritable(customColumn)).toBe(false);
    expect(readonlyColumnMessage(urgencyColumn)).toContain('read-only');
  });

  it('filters and sorts by state/group, priority, scheduled/deadline dates and urgency', () => {
    const cards: TodoSeqCardModel[] = [
      buildCardModel(task({ line: 0, state: 'TODO', priority: 'high', scheduledDate: date('2026-05-04'), urgency: 5, tags: ['home'] }), keywordManager),
      buildCardModel(task({ line: 1, state: 'DOING', priority: 'med', deadlineDate: date('2026-05-05'), urgency: 20, tags: ['work'] }), keywordManager),
      buildCardModel(task({ line: 2, state: 'WAIT', priority: 'low', deadlineDate: date('2026-05-06'), urgency: 10, tags: ['work'] }), keywordManager),
      buildCardModel(task({ line: 3, state: 'DONE', completed: true, urgency: 1 }), keywordManager),
    ];

    expect(filterCards(cards, { states: ['DOING'] }, today).map((card) => card.state)).toEqual(['DOING']);
    expect(filterCards(cards, { groups: ['waiting'] }, today).map((card) => card.state)).toEqual(['WAIT']);
    expect(filterCards(cards, { priorities: ['high'] }, today).map((card) => card.state)).toEqual(['TODO']);
    expect(filterCards(cards, { date: 'overdue' }, today).map((card) => card.state)).toEqual(['TODO']);
    expect(filterCards(cards, { date: 'today' }, today).map((card) => card.state)).toEqual(['DOING']);
    expect(filterCards(cards, { date: 'upcoming' }, today).map((card) => card.state)).toEqual(['WAIT']);
    expect(filterCards(cards, { date: 'no-date' }, today).map((card) => card.state)).toEqual(['DONE']);
    expect(filterCards(cards, { urgency: { min: 10 }, tags: ['work'] }, today).map((card) => card.state)).toEqual(['DOING', 'WAIT']);

    expect(sortCards(cards, { dateStrategy: 'scheduled-first' }).map((card) => card.state)).toEqual(['TODO', 'DOING', 'WAIT', 'DONE']);
    expect(sortCards(cards, { dateStrategy: 'deadline-first' }).map((card) => card.state)).toEqual(['DOING', 'WAIT', 'TODO', 'DONE']);
    expect(sortCards(cards, { dateStrategy: 'urgency-first' }).map((card) => card.state)).toEqual(['DOING', 'WAIT', 'TODO', 'DONE']);
  });
});

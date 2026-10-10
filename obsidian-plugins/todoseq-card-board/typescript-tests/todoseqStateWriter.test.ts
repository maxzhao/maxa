class MockTFile {
  constructor(public path: string) {}
}

jest.mock('obsidian', () => ({
  TFile: MockTFile,
  App: class {},
  MarkdownView: class {},
  Notice: jest.fn(),
  moment: require('moment'),
}));

import { TodoSeqAdapter } from '../typescript/todoseqAdapter';
import { TodoSeqStateWriter, TODOSEQ_CONFLICT_MESSAGE, TodoSeqTaskEditorService } from '../typescript/todoseqStateWriter';
import { BoardColumn } from '../typescript/boardDomain';

function createHarness(initial: string, settings: any = { trackClosedDate: true }) {
  let content = initial;
  const file = new MockTFile('Project.md');
  const app: any = {
    vault: {
      getAbstractFileByPath: jest.fn((path: string) => (path === file.path ? file : null)),
      cachedRead: jest.fn(async () => content),
      read: jest.fn(async () => content),
      process: jest.fn(async (_file: unknown, fn: (data: string) => string) => {
        content = fn(content);
      }),
    },
    workspace: {
      getActiveViewOfType: jest.fn(() => null),
    },
  };
  const adapter = new TodoSeqAdapter(app, settings);
  const service = new TodoSeqTaskEditorService(app, adapter, { app, settings });
  return {
    app,
    adapter,
    service,
    get content() {
      return content;
    },
    set content(value: string) {
      content = value;
    },
  };
}

function firstTask(adapter: TodoSeqAdapter, markdown: string) {
  const task = adapter.scanMarkdown(markdown, 'Project.md')[0];
  if (!task) throw new Error('missing task');
  return task;
}

function column(type: BoardColumn['type'], data: Partial<BoardColumn>): BoardColumn {
  return {
    id: data.id ?? `${type}:x`,
    name: data.name ?? 'Target',
    type,
    keywords: data.keywords ?? [],
    group: data.group,
    defaultKeyword: data.defaultKeyword,
  };
}

describe('TodoSeqStateWriter', () => {
  it('updates TODO to DONE with checkbox and CLOSED via TODOseq writer', async () => {
    const h = createHarness('- [ ] TODO Write tests');
    const task = firstTask(h.adapter, h.content);

    const result = await h.service.updateTaskState({
      task,
      targetColumn: column('keyword', { id: 'keyword:DONE', keywords: ['DONE'], defaultKeyword: 'DONE' }),
    });

    expect(result.ok).toBe(true);
    expect(h.content).toMatch(/^- \[x\] DONE Write tests\n\s*CLOSED: \[\d{4}-\d{2}-\d{2} [A-Z][a-z]{2}( \d{2}:\d{2})?\]$/);
  });

  it.each(['TODO', 'DOING', 'WAIT'])('moves DONE to %s and removes CLOSED', async (target) => {
    const h = createHarness(['- [x] DONE Done task', 'CLOSED: [2026-05-05 Tue]'].join('\n'));
    const task = firstTask(h.adapter, h.content);

    await h.service.updateTaskState({
      task,
      targetColumn: column('keyword', { id: `keyword:${target}`, keywords: [target], defaultKeyword: target }),
    });

    expect(h.content).toBe(`- [ ] ${target} Done task`);
  });

  it.each(['WAIT', 'DOING'])('moves TODO to %s preserving priority, embed, list marker, quote, and callout text', async (target) => {
    const markdown = '> [!todo]\n> + [ ] TODO [#A] Keep formatting ^embed';
    const h = createHarness(markdown);
    const task = h.adapter.scanMarkdown(h.content, 'Project.md')[0];

    await h.service.updateTaskState({
      task,
      targetColumn: column('keyword', { id: `keyword:${target}`, keywords: [target], defaultKeyword: target }),
    });

    expect(h.content).toContain(`> + [ ] ${target} [#A] Keep formatting ^embed`);
  });

  it('preserves checkbox state when moving to archived', async () => {
    const h = createHarness('- [ ] TODO Archive me');
    const task = firstTask(h.adapter, h.content);

    await h.service.updateTaskState({
      task,
      targetColumn: column('group', { id: 'group:archived', group: 'archived', keywords: ['ARCHIVED'] }),
    });

    expect(h.content).toBe('- [ ] ARCHIVED Archive me');
  });

  it('blocks conflicting writes when the target line changed', async () => {
    const h = createHarness('- [ ] TODO Original');
    const task = firstTask(h.adapter, h.content);
    h.content = '- [ ] TODO Edited elsewhere';

    const result = await h.service.updateTaskState({
      task,
      targetColumn: column('keyword', { id: 'keyword:DONE', keywords: ['DONE'], defaultKeyword: 'DONE' }),
    });

    expect(result).toEqual({ ok: false, error: TODOSEQ_CONFLICT_MESSAGE, conflict: true });
    expect(h.content).toBe('- [ ] TODO Edited elsewhere');
  });

  it('uses the same update service shape for drag/drop and mobile menu callers', async () => {
    const h = createHarness('- [ ] TODO Shared service');
    const task = firstTask(h.adapter, h.content);
    const targetColumn = column('group', { id: 'group:waiting', group: 'waiting', keywords: ['WAIT', 'WAITING'] });

    const dragCall = jest.spyOn(h.service, 'updateTaskState');
    await h.service.updateTaskState({ task, targetColumn });

    expect(dragCall).toHaveBeenCalledWith({ task, targetColumn });
    expect(h.content).toBe('- [ ] WAIT Shared service');
  });

  it('keeps TodoSeqStateWriter as a compatible editor service alias', async () => {
    const h = createHarness('- [ ] TODO Alias service');
    const alias = new TodoSeqStateWriter(h.app, h.adapter, { app: h.app, settings: { trackClosedDate: true } });
    const task = firstTask(h.adapter, h.content);

    await alias.updatePriority({ task, priority: 'high' });

    expect(h.content).toBe('- [ ] TODO [#A] Alias service');
  });
});

describe('TodoSeqTaskEditorService', () => {
  it('writes priority tokens and preserves quote, callout, list marker, embed and footnote formatting', async () => {
    const markdown = '> [!todo]\n> + [ ] TODO Keep formatting [^2] ^embed';
    const h = createHarness(markdown);
    const task = h.adapter.scanMarkdown(h.content, 'Project.md')[0];

    let result = await h.service.updatePriority({ task, priority: 'high' });
    expect(result.ok).toBe(true);
    expect(h.content).toContain('> + [ ] TODO [#A] Keep formatting [^2] ^embed');
    if (!result.ok) throw new Error('expected ok');

    result = await h.service.updatePriority({ task: result.task, priority: 'med' });
    expect(result.ok).toBe(true);
    expect(h.content).toContain('> + [ ] TODO [#B] Keep formatting [^2] ^embed');
    if (!result.ok) throw new Error('expected ok');

    result = await h.service.updatePriority({ task: result.task, priority: null });
    expect(result.ok).toBe(true);
    expect(h.content).toContain('> + [ ] TODO Keep formatting [^2] ^embed');
    expect(h.content).not.toContain('[#');
  });

  it('adds, updates, and removes SCHEDULED without changing DEADLINE or CLOSED', async () => {
    const h = createHarness(['- [ ] TODO Date task', '  DEADLINE: <2026-05-10 Sun>', '  CLOSED: [2026-05-01 Fri]'].join('\n'));
    const task = firstTask(h.adapter, h.content);

    let result = await h.service.updateScheduledDate({ task, date: new Date(2026, 4, 6) });
    expect(result.ok).toBe(true);
    expect(h.content).toBe(['- [ ] TODO Date task', '  SCHEDULED: <2026-05-06 Wed>', '  DEADLINE: <2026-05-10 Sun>', '  CLOSED: [2026-05-01 Fri]'].join('\n'));
    if (!result.ok) throw new Error('expected ok');

    result = await h.service.updateScheduledDate({ task: result.task, date: new Date(2026, 4, 7, 9, 30), repeat: { type: '.+', unit: 'd', value: 1, raw: '.+1d' } });
    expect(result.ok).toBe(true);
    expect(h.content).toContain('SCHEDULED: <2026-05-07 Thu 09:30 .+1d>');
    expect(h.content).toContain('DEADLINE: <2026-05-10 Sun>');
    expect(h.content).toContain('CLOSED: [2026-05-01 Fri]');
    if (!result.ok) throw new Error('expected ok');

    result = await h.service.updateScheduledDate({ task: result.task, date: null });
    expect(result.ok).toBe(true);
    expect(h.content).toBe(['- [ ] TODO Date task', '  DEADLINE: <2026-05-10 Sun>', '  CLOSED: [2026-05-01 Fri]'].join('\n'));
  });

  it('adds, updates, and removes DEADLINE independently from SCHEDULED and CLOSED', async () => {
    const h = createHarness(['- [ ] TODO Deadline task', '  SCHEDULED: <2026-05-06 Wed>', '  CLOSED: [2026-05-01 Fri]'].join('\n'));
    const task = firstTask(h.adapter, h.content);

    let result = await h.service.updateDeadlineDate({ task, date: new Date(2026, 4, 10) });
    expect(result.ok).toBe(true);
    expect(h.content).toBe(['- [ ] TODO Deadline task', '  SCHEDULED: <2026-05-06 Wed>', '  DEADLINE: <2026-05-10 Sun>', '  CLOSED: [2026-05-01 Fri]'].join('\n'));
    if (!result.ok) throw new Error('expected ok');

    result = await h.service.updateDeadlineDate({ task: result.task, date: new Date(2026, 4, 11) });
    expect(result.ok).toBe(true);
    expect(h.content).toContain('SCHEDULED: <2026-05-06 Wed>');
    expect(h.content).toContain('DEADLINE: <2026-05-11 Mon>');
    expect(h.content).toContain('CLOSED: [2026-05-01 Fri]');
    if (!result.ok) throw new Error('expected ok');

    result = await h.service.updateDeadlineDate({ task: result.task, date: null });
    expect(result.ok).toBe(true);
    expect(h.content).toBe(['- [ ] TODO Deadline task', '  SCHEDULED: <2026-05-06 Wed>', '  CLOSED: [2026-05-01 Fri]'].join('\n'));
  });

  it('adds, removes, and deduplicates tags without treating priority as a tag', async () => {
    const h = createHarness('- [ ] TODO [#A] Tag task #alpha #alpha ^embed');
    const task = firstTask(h.adapter, h.content);

    let result = await h.service.updateTags({ task, addTags: ['beta', '#alpha'] });
    expect(result.ok).toBe(true);
    expect(h.content).toBe('- [ ] TODO [#A] Tag task #alpha #beta ^embed');
    expect(h.content).toContain('[#A]');
    if (!result.ok) throw new Error('expected ok');

    result = await h.service.updateTags({ task: result.task, removeTags: ['alpha'] });
    expect(result.ok).toBe(true);
    expect(h.content).toBe('- [ ] TODO [#A] Tag task #beta ^embed');
    if (!result.ok) throw new Error('expected ok');

    result = await h.service.updateTags({ task: result.task, tags: [] });
    expect(result.ok).toBe(true);
    expect(h.content).toBe('- [ ] TODO [#A] Tag task ^embed');
  });

  it('applies a multi-field patch and returns the refreshed parsed task', async () => {
    const h = createHarness('- [ ] TODO Patch me #old');
    const task = firstTask(h.adapter, h.content);

    const result = await h.service.applyPatch(task, {
      state: 'DOING',
      priority: 'low',
      scheduledDate: new Date(2026, 4, 6),
      deadlineDate: new Date(2026, 4, 10),
      tags: ['new'],
    });

    expect(result.ok).toBe(true);
    if (!result.ok) throw new Error('expected ok');
    expect(h.content).toBe(['- [ ] DOING [#C] Patch me #new', '  SCHEDULED: <2026-05-06 Wed>', '  DEADLINE: <2026-05-10 Sun>'].join('\n'));
    expect(result.task.state).toBe('DOING');
    expect(result.task.priority).toBe('low');
    expect(result.task.tags).toEqual(['new']);
    expect(result.task.scheduledDate?.getFullYear()).toBe(2026);
    expect(result.task.scheduledDate?.getMonth()).toBe(4);
    expect(result.task.scheduledDate?.getDate()).toBe(6);
    expect(result.task.deadlineDate?.getFullYear()).toBe(2026);
    expect(result.task.deadlineDate?.getMonth()).toBe(4);
    expect(result.task.deadlineDate?.getDate()).toBe(10);
  });


  it('updates task text through applyPatch while preserving priority and trailing references', async () => {
    const h = createHarness('- [ ] TODO [#A] Old text #old ^embed');
    const task = firstTask(h.adapter, h.content);

    const result = await h.service.applyPatch(task, {
      text: 'New text #new',
      tags: ['new'],
    });

    expect(result.ok).toBe(true);
    if (!result.ok) throw new Error('expected ok');
    expect(h.content).toBe('- [ ] TODO [#A] New text #new ^embed');
    expect(result.task.text).toBe('New text #new');
    expect(result.task.tags).toEqual(['new']);
  });

  it('blocks conflicting property writes and does not overwrite external edits', async () => {
    const h = createHarness('- [ ] TODO Original #tag');
    const task = firstTask(h.adapter, h.content);
    h.content = '- [ ] TODO Edited elsewhere #tag';

    const result = await h.service.updatePriority({ task, priority: 'high' });

    expect(result).toEqual({ ok: false, error: TODOSEQ_CONFLICT_MESSAGE, conflict: true });
    expect(h.content).toBe('- [ ] TODO Edited elsewhere #tag');
  });
});

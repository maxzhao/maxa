jest.mock('obsidian', () => ({
  App: class {},
  Modal: class {
    contentEl: any = { empty: jest.fn(), addClass: jest.fn() };
    constructor(public app: any) {}
    open() {}
    close() {}
  },
  Notice: jest.fn(),
  Setting: class {},
}));

import { TodoSeqAdapter } from '../typescript/todoseqAdapter';
import { buildTodoSeqTaskEditPatch, formStateFromTask } from '../typescript/todoseqTaskEditModal';

function firstTask(markdown: string) {
  const adapter = new TodoSeqAdapter(null, { trackClosedDate: true } as any);
  const task = adapter.scanMarkdown(markdown, 'Project.md')[0];
  if (!task) throw new Error('missing task');
  return task;
}

describe('TodoSeqTaskEditModal patch builder', () => {
  it('builds a TODOseq applyPatch payload with independent SCHEDULED and DEADLINE fields', () => {
    const task = firstTask(['- [ ] TODO [#A] Old text #old', '  SCHEDULED: <2026-05-06 Wed>'].join('\n'));

    const patch = buildTodoSeqTaskEditPatch(task, {
      ...formStateFromTask(task),
      text: 'New text #new',
      state: 'DOING',
      priority: 'low',
      scheduledDate: '2026-05-07',
      deadlineDate: '2026-05-10',
      tagsText: '#new #work',
    });

    expect(patch.ok).toBe(true);
    if (!patch.ok) throw new Error('expected ok');
    expect(patch.patch).toMatchObject({
      text: 'New text #new',
      state: 'DOING',
      priority: 'low',
      tags: ['new', 'work'],
    });
    expect(patch.patch.scheduledDate?.getFullYear()).toBe(2026);
    expect(patch.patch.scheduledDate?.getMonth()).toBe(4);
    expect(patch.patch.scheduledDate?.getDate()).toBe(7);
    expect(patch.patch.deadlineDate?.getFullYear()).toBe(2026);
    expect(patch.patch.deadlineDate?.getMonth()).toBe(4);
    expect(patch.patch.deadlineDate?.getDate()).toBe(10);
  });

  it('returns clear validation errors and keeps the caller state when invalid', () => {
    const task = firstTask('- [ ] TODO Keep me');

    expect(buildTodoSeqTaskEditPatch(task, { ...formStateFromTask(task), text: '' })).toEqual({
      ok: false,
      error: 'Text cannot be empty.',
    });
    expect(buildTodoSeqTaskEditPatch(task, { ...formStateFromTask(task), scheduledDate: '2026/05/07' })).toEqual({
      ok: false,
      error: 'SCHEDULED must use YYYY-MM-DD.',
    });
  });
});

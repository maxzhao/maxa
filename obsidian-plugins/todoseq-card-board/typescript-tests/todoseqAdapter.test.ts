import { TodoSeqAdapter } from '../typescript/todoseqAdapter';

describe('TodoSeqAdapter', () => {
  const adapter = new TodoSeqAdapter(null, {});

  it('parses TODOseq task examples from the TODOseq parser source of truth', () => {
    const markdown = [
      'TODO plain task',
      '',
      '- [ ] TODO checkbox task',
      '',
      '- [x] DONE completed task',
      '',
      'TODO [#A] dated task #work',
      'SCHEDULED: <2026-05-06 Wed .+1d>',
      'DEADLINE: <2026-05-07 Thu +1w>',
      'CLOSED: [2026-05-08 Fri]',
      '  - [ ] first subtask',
      '  - [x] second subtask',
    ].join('\n');

    const tasks = adapter.scanMarkdown(markdown, 'Project.md');

    expect(tasks).toHaveLength(4);
    expect(tasks[0]).toMatchObject({
      path: 'Project.md',
      line: 0,
      rawText: 'TODO plain task',
      text: 'plain task',
      state: 'TODO',
      completed: false,
      priority: null,
      subtaskCount: 0,
      subtaskCompletedCount: 0,
    });

    expect(tasks[1]).toMatchObject({
      line: 2,
      rawText: '- [ ] TODO checkbox task',
      text: 'checkbox task',
      state: 'TODO',
      completed: false,
    });

    expect(tasks[2]).toMatchObject({
      line: 4,
      rawText: '- [x] DONE completed task',
      text: 'completed task',
      state: 'DONE',
      completed: true,
    });

    expect(tasks[3]).toMatchObject({
      line: 6,
      text: 'dated task #work',
      state: 'TODO',
      completed: false,
      priority: 'high',
      tags: ['work'],
      subtaskCount: 2,
      subtaskCompletedCount: 1,
    });
    expect(tasks[3].scheduledDate).toBeInstanceOf(Date);
    expect(tasks[3].deadlineDate).toBeInstanceOf(Date);
    expect(tasks[3].closedDate).toBeInstanceOf(Date);
    expect(tasks[3].scheduledDateRepeat).toMatchObject({ type: '.+', unit: 'd', value: 1, raw: '.+1d' });
    expect(tasks[3].deadlineDateRepeat).toMatchObject({ type: '+', unit: 'w', value: 1, raw: '+1w' });
    expect(typeof tasks[3].urgency).toBe('number');
  });

    it('cleans TODOseq display titles without duplicate metadata noise', () => {
    const markdown = [
      'TODO Plain task #board/plain',
      '- [x] TODO Checkbox task [#A] #work @completed(2026-05-06T17:08:36+08:00) ^todo-board',
      '  SCHEDULED: <2026-05-06 Wed +1d>',
      '  DEADLINE: <2026-05-08 Fri>',
      '  - [x] finished subtask',
      '  - [ ] open subtask',
      '- [x] DONE Completed task [#B] #done',
      '  CLOSED: [2026-05-05 Tue]',
      'WAIT Waiting task #blocked',
      'DOING Active daily task #daily',
      'TODO No priority unscheduled task #board/no-priority',
      'TODO Deadline only task #deadline-only',
      '  DEADLINE: <2026-05-07 Thu>',
      'TODO Scheduled only task #scheduled-only',
      '  SCHEDULED: <2026-05-07 Thu>',
    ].join('\n');

    const tasks = adapter.scanMarkdown(markdown, 'Project.md');

    expect(tasks.map((task) => task.displayText)).toEqual([
      'Plain task',
      'Checkbox task',
      'Completed task',
      'Waiting task',
      'Active daily task',
      'No priority unscheduled task',
      'Deadline only task',
      'Scheduled only task',
    ]);
    expect(tasks.map((task) => task.displayText).join(' ')).not.toMatch(/TODO|DONE|WAIT|DOING|\[#A\]|\[#B\]|#work|@completed|SCHEDULED|DEADLINE|CLOSED|\^todo-board/);
  });

  it('does not treat CardBoard @due/@completed syntax as task truth', () => {
    expect(adapter.scanMarkdown('- [ ] legacy CardBoard task @due(2026-05-06)', 'Legacy.md')).toHaveLength(0);
    expect(adapter.scanMarkdown('Just text @completed(2026-05-06)', 'Legacy.md')).toHaveLength(0);
  });
});

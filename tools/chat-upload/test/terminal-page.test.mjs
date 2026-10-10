import assert from 'node:assert/strict'
import test from 'node:test'
import { closeOrRenderTerminal, renderTerminalPage, terminalMessage } from '../web/terminal_page.js'

function fakeDocument() {
  return {
    calls: [],
    open() { this.calls.push(['open']) },
    write(value) { this.calls.push(['write', value]) },
    close() { this.calls.push(['close']) },
  }
}

test('terminal messages are exact Chinese product strings', () => {
  assert.equal(terminalMessage('submit'), '已提交，可以关闭此页')
  assert.equal(terminalMessage('cancel'), '已取消，可以关闭此页')
  assert.throws(() => terminalMessage('other'), /Unsupported terminal action/)
})

test('successful browser close leaves the document untouched', () => {
  const documentObject = fakeDocument()
  let closeCalls = 0
  const windowObject = { closed: true, close() { closeCalls += 1 } }
  closeOrRenderTerminal('submit', { windowObject, documentObject, schedule: (callback) => callback() })
  assert.equal(closeCalls, 1)
  assert.deepEqual(documentObject.calls, [])
})

test('blocked browser close replaces the whole document with terminal message only', () => {
  const documentObject = fakeDocument()
  const windowObject = { closed: false, close() {} }
  closeOrRenderTerminal('cancel', { windowObject, documentObject, schedule: (callback) => callback() })
  assert.deepEqual(documentObject.calls.map(([name]) => name), ['open', 'write', 'close'])
  const html = documentObject.calls[1][1]
  assert.match(html, /已取消，可以关闭此页/)
  assert.doesNotMatch(html, /<button|<form|<input|confirm\(|window\.close/)
})

test('window.close exception immediately falls back to terminal page', () => {
  const documentObject = fakeDocument()
  closeOrRenderTerminal('submit', {
    windowObject: { close() { throw new Error('blocked') } },
    documentObject,
    schedule() { throw new Error('must not schedule') },
  })
  assert.match(documentObject.calls[1][1], /已提交，可以关闭此页/)
})

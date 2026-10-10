import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import path from 'node:path'
import test from 'node:test'
import { parseXhrJson, responseErrorFromXhr } from '../web/xhr_response.js'

const root = path.resolve(import.meta.dirname, '..')

test('web integration uses the pinned Uppy 4 upload event signature', async () => {
  const source = await readFile(path.join(root, 'web', 'main.js'), 'utf8')
  assert.match(source, /uppy\.on\('upload', \(_uploadId, files\) =>/)
  assert.match(source, /for \(const file of files\) activeFiles\.add\(file\.id\)/)
  assert.doesNotMatch(source, /upload\.fileIDs/)
})

test('XHR response callbacks consume XMLHttpRequest fields, not the object itself', () => {
  const xhr = {
    responseType: '',
    responseText: '{"file":{"id":"file-1"}}',
    status: 201,
    statusText: 'Created',
    toString() { return '[object XMLHttpRequest]' },
  }
  assert.deepEqual(parseXhrJson(xhr), { file: { id: 'file-1' } })
  assert.deepEqual(parseXhrJson({ responseType: 'json', response: { file: { id: 'file-2' } } }), { file: { id: 'file-2' } })
  assert.throws(() => JSON.parse(xhr), /Unexpected token|not valid JSON/)

  const error = responseErrorFromXhr({
    responseType: '',
    responseText: '{"error":{"code":"file_too_large","message":"Too large"}}',
    status: 413,
    statusText: 'Payload Too Large',
  })
  assert.equal(error.message, 'Too large')
  assert.equal(error.code, 'file_too_large')
  assert.equal(responseErrorFromXhr({ responseType: '', responseText: 'not-json', status: 500, statusText: 'Server Error' }).message, 'Server Error')
})

test('page and Dashboard follow the browser color scheme', async () => {
  const [source, styles] = await Promise.all([
    readFile(path.join(root, 'web', 'main.js'), 'utf8'),
    readFile(path.join(root, 'web', 'styles.css'), 'utf8'),
  ])
  assert.match(source, /theme: 'auto'/)
  assert.match(styles, /color-scheme: light dark/)
  assert.match(styles, /@media \(prefers-color-scheme: dark\)/)
  assert.match(styles, /#status\.error/)
  assert.doesNotMatch(source, /status\.style\.color/)
  assert.match(source, /getResponseData: parseXhrJson/)
  assert.doesNotMatch(source, /getResponseData\(text\).*JSON\.parse\(text\)/)
  assert.match(source, /if \(!response\.ok\) throw await apiError\(response\)[\s\S]*terminal = true[\s\S]*closeOrRenderTerminal\(name\)/)
  assert.doesNotMatch(source, /confirm\(|alert\(|window\.open\(/)
})

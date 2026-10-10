import assert from 'node:assert/strict'
import { mkdtemp, readFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { ReadableStream } from 'node:stream/web'
import test from 'node:test'
import { UploadSession } from '../src/session.mjs'
import { importPublicUrl, isForbiddenAddress, validatePublicUrl } from '../src/url_import.mjs'

const publicLookup = async () => [{ address: '93.184.216.34', family: 4 }]

test('rejects private, loopback, link-local, reserved and credentialed URL destinations', async () => {
  for (const address of ['127.0.0.1', '10.0.0.1', '169.254.1.1', '192.168.1.1', '100.64.0.1', '224.0.0.1', '::1', 'fc00::1', 'fe80::1']) assert.equal(isForbiddenAddress(address), true)
  await assert.rejects(validatePublicUrl('http://private.test/', { lookup: async () => [{ address: '10.0.0.1', family: 4 }] }), (error) => error.code === 'url_private_address')
  await assert.rejects(validatePublicUrl('https://user:pass@example.com/'), (error) => error.code === 'url_forbidden')
})

test('imports a public URL through normal streamed manifest storage', async () => {
  const projectRoot = await mkdtemp(path.join(os.tmpdir(), 'chat-upload-url-'))
  const session = await UploadSession.create({ projectRoot, limits: { fileBytes: 20, sessionBytes: 30 } })
  const response = new Response('hello', { status: 200, headers: { 'content-length': '5', 'content-type': 'text/plain', 'content-disposition': 'attachment; filename="hello.txt"' } })
  const record = await importPublicUrl({ input: 'https://example.com/file', session, lookup: publicLookup, fetchImpl: async () => response })
  assert.equal(record.stored_name, 'hello.txt')
  assert.equal(await readFile(path.join(projectRoot, record.relative_path), 'utf8'), 'hello')
})

test('validates every redirect target and rejects redirect to private address', async () => {
  await assert.rejects(importPublicUrl({
    input: 'https://example.com/file',
    session: {},
    lookup: async (hostname) => [{ address: hostname === 'internal.test' ? '192.168.1.2' : '93.184.216.34', family: 4 }],
    fetchImpl: async () => new Response(null, { status: 302, headers: { location: 'http://internal.test/secret' } }),
  }), (error) => error.code === 'url_private_address')
})

test('unknown-length URL streams stop at injected session/file capacity', async () => {
  const projectRoot = await mkdtemp(path.join(os.tmpdir(), 'chat-upload-url-limit-'))
  const session = await UploadSession.create({ projectRoot, limits: { fileBytes: 4, sessionBytes: 4 } })
  const response = { ok: true, status: 200, url: 'https://example.com/x', headers: new Headers(), body: ReadableStream.from([Buffer.from('12345')]) }
  await assert.rejects(importPublicUrl({ input: 'https://example.com/x', session, lookup: publicLookup, fetchImpl: async () => response }), (error) => error.status === 413)
  assert.equal(session.files.length, 0)
})

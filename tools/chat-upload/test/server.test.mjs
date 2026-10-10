import assert from 'node:assert/strict'
import { mkdtemp, readFile, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { createUploadServer, listen } from '../src/server.mjs'
import { UploadSession } from '../src/session.mjs'

const hostname = process.env.MAXA_CERT_DOMAIN

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0'

async function setup() {
  assert.ok(hostname, 'MAXA_CERT_DOMAIN is required for certificate-backed upload tests')
  const projectRoot = await mkdtemp(path.join(os.tmpdir(), 'chat-upload-http-'))
  const webRoot = path.join(projectRoot, 'web')
  await import('node:fs/promises').then(({ mkdir }) => mkdir(webRoot))
  await writeFile(path.join(webRoot, 'index.html'), 'local page')
  const session = await UploadSession.create({ projectRoot, limits: { fileBytes: 100, sessionBytes: 200 } })
  const certificateRoot = path.resolve(import.meta.dirname, '..', '..', '..', 'certificates', hostname)
  const tls = { cert: await readFile(path.join(certificateRoot, 'fullchain.pem')), key: await readFile(path.join(certificateRoot, 'privkey.pem')) }
  let terminal
  const server = createUploadServer({ session, token: 'secret-token', webRoot, tls, terminalDelayMs: 1, onTerminal: (event) => { terminal = event } })
  const bound = await listen(server, { host: '127.0.0.1' })
  return { session, server, base: `https://127.0.0.1:${bound.port}/session/secret-token`, terminal: () => terminal }
}

test('loopback HTTP serves only 127.0.0.1 and cannot bind publicly', async (t) => {
  const projectRoot = await mkdtemp(path.join(os.tmpdir(), 'chat-upload-loopback-'))
  const webRoot = path.join(projectRoot, 'web')
  await import('node:fs/promises').then(({ mkdir }) => mkdir(webRoot))
  await writeFile(path.join(webRoot, 'index.html'), 'local page')
  const session = await UploadSession.create({ projectRoot })
  const server = createUploadServer({ session, token: 'secret-token', webRoot, loopback: true })
  t.after(() => server.close())
  await assert.rejects(listen(server, { host: '0.0.0.0' }), /must bind to 127.0.0.1/)
  const bound = await listen(server)
  assert.equal(bound.address, '127.0.0.1')
  assert.equal((await fetch(`http://127.0.0.1:${bound.port}/session/secret-token/`)).status, 200)
  assert.equal((await fetch(`http://127.0.0.1:${bound.port}/session/other/`)).status, 404)
})
async function multipart(base, name, data) {
  const form = new FormData()
  form.append('file', new Blob([data], { type: 'text/plain' }), name)
  return fetch(`${base}/api/files`, { method: 'POST', headers: { 'X-Upload-Size': String(Buffer.byteLength(data)) }, body: form })
}

test('serves only token-scoped local assets and restores manifest state', async (t) => {
  const fixture = await setup(); t.after(() => fixture.server.close())
  assert.equal((await fetch(`${fixture.base}/`)).status, 200)
  assert.equal((await fetch(fixture.base.replace('secret-token', 'wrong') + '/api/state')).status, 404)
  const response = await multipart(fixture.base, 'hello.txt', 'hello')
  assert.equal(response.status, 201)
  const state = await (await fetch(`${fixture.base}/api/state`)).json()
  assert.equal(state.files[0].stored_name, 'hello.txt')
  assert.equal(state.in_progress, 0)
})

test('remove, submit, terminal rejection, and terminal callback converge', async (t) => {
  const fixture = await setup(); t.after(() => fixture.server.close())
  const one = (await (await multipart(fixture.base, 'one.txt', '1')).json()).file
  await multipart(fixture.base, 'two.txt', '22')
  assert.equal((await fetch(`${fixture.base}/api/files/${encodeURIComponent(one.id)}`, { method: 'DELETE' })).status, 200)
  const submitted = await fetch(`${fixture.base}/api/submit`, { method: 'POST' })
  assert.equal(submitted.status, 200)
  const body = await submitted.json()
  assert.deepEqual(body.paths.map((value) => path.basename(value)), ['two.txt'])
  assert.equal((await fetch(`${fixture.base}/api/cancel`, { method: 'POST' })).status, 409)
  await new Promise((resolve) => setTimeout(resolve, 10))
  assert.deepEqual(fixture.terminal(), { event: 'submitted', paths: body.paths })
})

test('returns stable errors for missing file and injected limits', async (t) => {
  const fixture = await setup(); t.after(() => fixture.server.close())
  const missing = await fetch(`${fixture.base}/api/files`, { method: 'POST', body: new FormData() })
  assert.equal(missing.status, 411)
  assert.equal((await missing.json()).error.code, 'upload_size_required')
  const tooLarge = await multipart(fixture.base, 'large.bin', 'x'.repeat(101))
  assert.equal(tooLarge.status, 413)
  assert.equal((await tooLarge.json()).error.code, 'file_too_large')
})

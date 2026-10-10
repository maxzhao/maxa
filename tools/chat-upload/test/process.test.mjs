import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { mkdtemp, readdir } from 'node:fs/promises'
import https from 'node:https'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

const hostname = process.env.MAXA_CERT_DOMAIN

function nextJsonLine(child, predicate, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    let buffer = ''
    const timeout = setTimeout(() => reject(new Error('timed out waiting for process event')), timeoutMs)
    const onData = (chunk) => {
      buffer += chunk
      while (buffer.includes('\n')) {
        const newline = buffer.indexOf('\n')
        const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1)
        if (!line) continue
        const event = JSON.parse(line)
        if (predicate(event)) {
          clearTimeout(timeout)
          child.stdout.off('data', onData)
          resolve(event)
          return
        }
      }
    }
    child.stdout.on('data', onData)
  })
}

test('default CLI upload binds loopback HTTP without remote certificates', async (t) => {
  const projectRoot = await mkdtemp(path.join(os.tmpdir(), 'chat-upload-local-'))
  const repositoryRoot = path.resolve(import.meta.dirname, '..', '..', '..')
  const child = spawn(process.execPath, [path.join(repositoryRoot, 'tools/chat-upload/src/cli.mjs'), '--project-root', projectRoot], {
    cwd: projectRoot, stdio: ['ignore', 'pipe', 'pipe'],
  })
  t.after(() => { if (child.exitCode == null) child.kill('SIGKILL') })
  const ready = await nextJsonLine(child, (event) => event.event === 'ready')
  assert.equal(ready.bind, '127.0.0.1')
  assert.equal(ready.host, '127.0.0.1')
  assert.equal(new URL(ready.url).protocol, 'http:')
  assert.equal((await fetch(ready.url)).status, 200)
  const terminal = nextJsonLine(child, (event) => event.event === 'cancelled')
  child.kill('SIGTERM')
  assert.equal((await terminal).event, 'cancelled')
})
test('uses runtime certificates from another project and SIGTERM removes its partial upload', async (t) => {
  assert.ok(hostname, 'MAXA_CERT_DOMAIN is required for certificate-backed upload tests')
  const projectRoot = await mkdtemp(path.join(os.tmpdir(), 'chat-upload-process-'))
  const repositoryRoot = path.resolve(import.meta.dirname, '..', '..', '..')
  assert.deepEqual(await readdir(projectRoot), [])
  const child = spawn(process.execPath, [path.join(repositoryRoot, 'tools/chat-upload/src/cli.mjs'), '--project-root', projectRoot, '--hostname', hostname], {
    cwd: projectRoot,
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  t.after(() => { if (child.exitCode == null) child.kill('SIGKILL') })
  const ready = await nextJsonLine(child, (event) => event.event === 'ready')
  assert.equal(ready.bind, '0.0.0.0')
  assert.equal(new URL(ready.url).protocol, 'https:')
  const target = new URL(ready.url)
  const boundary = 'test-boundary'
  const request = https.request({
    host: '127.0.0.1',
    port: target.port,
    path: `${target.pathname}api/files`,
    method: 'POST',
    servername: target.hostname,
    rejectUnauthorized: false,
    headers: {
      'content-type': `multipart/form-data; boundary=${boundary}`,
      'x-upload-size': '1000000',
      'transfer-encoding': 'chunked',
    },
  })
  request.on('error', () => {})
  request.write(`--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="slow.bin"\r\nContent-Type: application/octet-stream\r\n\r\n`)
  request.write(Buffer.alloc(1024, 1))
  const sessionDirectory = path.join(projectRoot, '.maxa', 'upload', ready.session_id)
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const entries = await readdir(sessionDirectory)
    if (entries.some((name) => name.startsWith('.partial-'))) break
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  const terminal = nextJsonLine(child, (event) => event.event === 'cancelled')
  child.kill('SIGTERM')
  assert.equal((await terminal).event, 'cancelled')
  const exit = await new Promise((resolve) => child.once('exit', (code, signal) => resolve({ code, signal })))
  assert.deepEqual(exit, { code: 0, signal: null })
  assert.equal((await readdir(sessionDirectory)).some((name) => name.startsWith('.partial-')), false)
})

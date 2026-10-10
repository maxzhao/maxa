import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { mkdtemp, mkdir, rename, rm, symlink, writeFile } from 'node:fs/promises'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import test from 'node:test'
import { createFileLinksServer } from '../src/file_links_server.mjs'

const cli = fileURLToPath(new URL('../src/file_links_cli.mjs', import.meta.url))
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

function request(port, url, { method = 'GET', body, headers = {}, hostname = '127.0.0.1', localAddress } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ hostname, localAddress, port, path: url, method, headers, agent: false }, (response) => {
      const chunks = []
      response.on('data', (chunk) => chunks.push(chunk))
      response.on('end', () => resolve({ status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks).toString() }))
      response.on('error', reject)
    })
    req.on('error', (error) => {
      error.message = `${method} ${url}: ${error.message}`
      reject(error)
    })
    req.end(body)
  })
}

async function listen(server, host = '127.0.0.1') {
  server.listen(0, host)
  await once(server, 'listening')
  return server.address().port
}

async function close(server) {
  if (!server.listening) return
  const closed = once(server, 'close')
  server.close()
  server.closeAllConnections()
  await closed
}

async function sleeper(t) {
  const child = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { stdio: 'ignore' })
  await once(child, 'spawn')
  t.after(() => { if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL') })
  return child
}

async function stop(child) {
  const exited = once(child, 'exit')
  child.kill('SIGKILL')
  await exited
}

function register(port, project, pid, roots, paths) {
  return request(port, '/register', {
    method: 'POST', headers: { 'content-type': 'application/json; charset=utf-8' },
    body: JSON.stringify({ pid, project_root: project, allowed_roots: roots, paths }),
  })
}

async function fixture(t) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'maxa-file-links-'))
  t.after(() => rm(directory, { recursive: true, force: true }))
  const project = path.join(directory, 'project')
  const root = path.join(project, 'shared')
  await mkdir(root, { recursive: true })
  await mkdir(path.join(project, 'other'))
  await writeFile(path.join(root, 'hello 世界 #? (draft).txt'), 'hello shared')
  await writeFile(path.join(root, 'unknown.bin'), 'binary')
  await writeFile(path.join(project, 'outside.txt'), 'outside')
  const server = createFileLinksServer()
  t.after(() => close(server))
  const port = await listen(server)
  return { directory, project, root, server, port }
}

test('API validation, stable URLs, MIME/HEAD, containment and replacement isolation', async (t) => {
  const { directory, project, root, server, port } = await fixture(t)
  const first = await sleeper(t)
  const second = await sleeper(t)
  const name = 'shared/hello 世界 #? (draft).txt'
  const health = await request(port, '/health')
  assert.equal(health.status, 200)
  assert.deepEqual(JSON.parse(health.body), { service: 'maxa-file-links', version: 1 })
  assert.equal((await request(port, '/register', { method: 'POST', body: '{}' })).status, 415)
  assert.equal((await request(port, '/register', { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{' })).status, 400)
  assert.equal((await register(port, 'relative', first.pid, ['shared'], [name])).status, 400)
  assert.equal((await register(port, project, 0, ['shared'], [name])).status, 400)
  assert.equal((await request(port, '/register', {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: ' '.repeat(1024 * 1024 + 1),
  })).status, 413)
  const invalidRoots = await register(port, project, first.pid, ['missing', name], [name])
  assert.equal(invalidRoots.status, 200)
  assert.deepEqual(JSON.parse(invalidRoots.body), { urls: {} })

  await symlink('../outside.txt', path.join(root, 'escape.txt'))
  await symlink('hello 世界 #? (draft).txt', path.join(root, 'alias.txt'))
  const registration = await register(port, project, first.pid, ['shared'], [name, 'shared/unknown.bin', 'missing', 'outside.txt', 'shared', 'shared/escape.txt', 'shared/alias.txt'])
  assert.equal(registration.status, 200)
  const urls = JSON.parse(registration.body).urls
  assert.deepEqual(Object.keys(urls).sort(), [name, 'shared/unknown.bin', 'shared/alias.txt'].sort())
  assert.equal(urls['shared/alias.txt'], urls[name])
  const target = new URL(urls[name])
  assert.equal(target.origin, `http://127.0.0.1:${port}`)
  assert.match(target.pathname, /^\/files\/[a-f0-9]{64}\/[a-f0-9]{64}\/hello%20/)
  assert.ok(target.pathname.includes('%28draft%29'), 'parentheses are safe inside Markdown destinations')
  assert.equal(target.pathname.includes(encodeURIComponent(project)), false)
  assert.equal(target.pathname.includes(encodeURIComponent(root)), false)
  const file = await request(port, target.pathname)
  assert.equal(file.status, 200)
  assert.equal(file.body, 'hello shared')
  assert.match(file.headers['content-type'], /^text\/plain/)
  assert.match(file.headers['content-disposition'], /^inline/)
  const head = await request(port, target.pathname, { method: 'HEAD' })
  assert.equal(head.status, 200)
  assert.equal(head.body, '')
  assert.equal(head.headers['content-length'], String(Buffer.byteLength('hello shared')))
  const unknown = await request(port, new URL(urls['shared/unknown.bin']).pathname)
  assert.equal(unknown.headers['content-type'], 'application/octet-stream')
  assert.match(unknown.headers['content-disposition'], /^attachment/)
  for (const extension of ['png', 'jpeg', 'gif', 'webp', 'svg', 'pdf', 'mp4', 'mp3']) {
    await writeFile(path.join(root, `media.${extension}`), 'media')
    const registered = JSON.parse((await register(port, project, first.pid, ['shared'], [`shared/media.${extension}`])).body).urls
    const result = await request(port, new URL(registered[`shared/media.${extension}`]).pathname)
    assert.equal(result.status, 200)
    assert.match(result.headers['content-disposition'], /^inline/)
    assert.notEqual(result.headers['content-type'], 'application/octet-stream')
  }
  const prefix = target.pathname.slice(0, target.pathname.lastIndexOf('/') + 1)
  for (const traversal of ['../outside.txt', '%2e%2e/outside.txt', '.%2e/outside.txt', '%2e/outside.txt', '%2e%2e%2foutside.txt', '..%5coutside.txt', '%00', 'missing', 'escape.txt', '']) {
    assert.equal((await request(port, `${prefix}${traversal}`)).status, 404, traversal)
  }
  assert.equal((await request(port, target.pathname, { method: 'POST' })).status, 404)
  const otherProject = path.join(directory, 'other-project')
  await mkdir(otherProject)
  const separate = JSON.parse((await register(port, otherProject, first.pid, [root], [path.join(root, 'unknown.bin')])).body).urls
  const separateUrl = new URL(separate[path.join(root, 'unknown.bin')])
  assert.notEqual(separateUrl.pathname.split('/')[2], target.pathname.split('/')[2])
  await register(port, project, second.pid, ['shared'], [])
  await register(port, project, first.pid, ['other'], [])
  assert.equal((await request(port, target.pathname)).status, 200, 'another PID still grants the root')
  assert.equal((await request(port, separateUrl.pathname)).status, 200, 'same PID in another project is untouched')
  await stop(second)
  assert.equal((await request(port, target.pathname)).status, 404, 'dead PID is denied before periodic purge')
  assert.equal((await register(port, project, second.pid, ['shared'], [name])).status, 400)
  const aliasProject = path.join(directory, 'project-alias')
  await symlink(project, aliasProject)
  const stable = JSON.parse((await register(port, aliasProject, first.pid, [root], [name])).body).urls
  assert.equal(stable[name], urls[name], 'real project/root keys ignore input spelling and PID')

  await rename(path.join(root, 'hello 世界 #? (draft).txt'), path.join(root, 'saved.txt'))
  await symlink('../outside.txt', path.join(root, 'hello 世界 #? (draft).txt'))
  assert.equal((await request(port, target.pathname)).status, 404, 'file symlink escape is rechecked on GET')
  await rm(path.join(root, 'hello 世界 #? (draft).txt'))
  await rename(path.join(root, 'saved.txt'), path.join(root, 'hello 世界 #? (draft).txt'))
  await rename(root, `${root}-saved`)
  await symlink(path.join(project, 'other'), root)
  await writeFile(path.join(project, 'other', 'hello 世界 #? (draft).txt'), 'outside root')
  assert.equal((await request(port, target.pathname)).status, 404, 'root symlink replacement cannot escape')
  await rm(root)
  await rename(`${root}-saved`, root)

  await close(server)
  const restarted = createFileLinksServer()
  t.after(() => close(restarted))
  restarted.listen(port, '127.0.0.1')
  await once(restarted, 'listening')
  assert.equal((await request(port, target.pathname)).status, 404, 'no grants persist across restart')
  const afterRestart = JSON.parse((await register(port, project, first.pid, ['shared'], [name])).body).urls
  assert.equal(afterRestart[name], urls[name])
  assert.equal((await request(port, target.pathname)).status, 200)
})

test('control endpoints reject non-loopback callers and do not trust forwarding headers', async (t) => {
  const address = Object.values(os.networkInterfaces()).flat().find((entry) => entry.family === 'IPv4' && !entry.internal)?.address
  if (!address) return t.skip('no non-loopback IPv4 interface')
  const server = createFileLinksServer()
  t.after(() => close(server))
  const port = await listen(server, '0.0.0.0')
  for (const [url, method] of [['/health', 'GET'], ['/register', 'POST']]) {
    const result = await request(port, url, {
      method, hostname: address, localAddress: address,
      headers: { 'x-forwarded-for': '127.0.0.1', 'content-type': 'application/json' }, body: method === 'POST' ? '{}' : undefined,
    })
    assert.equal(result.status, 403)
  }
})

test('CLI fixed-port failure and PID-only lifecycle survive the spawning process', { timeout: 40_000 }, async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'maxa-file-links-cli-'))
  t.after(() => rm(directory, { recursive: true, force: true }))
  await writeFile(path.join(directory, 'file.txt'), 'lifecycle')
  const occupied = http.createServer()
  t.after(() => close(occupied))
  const port = await listen(occupied)
  const conflict = spawn(process.execPath, [cli, '--hostname', '127.0.0.1', '--port', String(port)], { stdio: ['ignore', 'pipe', 'pipe'] })
  let errors = ''
  conflict.stderr.on('data', (chunk) => { errors += chunk })
  assert.equal((await once(conflict, 'exit'))[0], 1)
  assert.match(errors, /EADDRINUSE/)
  await close(occupied)
  const invalid = spawn(process.execPath, [cli, '--port', '0'], { stdio: 'ignore' })
  assert.equal((await once(invalid, 'exit'))[0], 1)
  const invalidHostname = spawn(process.execPath, [cli, '--hostname', '../bad'], { stdio: ['ignore', 'pipe', 'pipe'] })
  let hostnameErrors = ''
  invalidHostname.stderr.on('data', (chunk) => { hostnameErrors += chunk })
  assert.equal((await once(invalidHostname, 'exit'))[0], 1)
  assert.match(hostnameErrors, /invalid_hostname/)

  // The launcher exits immediately; service lifetime must not be tied to its parent or stdin.
  const launcher = spawn(process.execPath, ['--input-type=module', '-e', `
    import { spawn } from 'node:child_process';
    const child = spawn(process.execPath, [${JSON.stringify(cli)}, '--hostname', '127.0.0.1', '--port', '${port}'], { detached: true, stdio: 'ignore' });
    console.log(child.pid);
    child.unref();
  `], { stdio: ['ignore', 'pipe', 'pipe'] })
  let output = ''
  launcher.stdout.on('data', (chunk) => { output += chunk })
  assert.equal((await once(launcher, 'exit'))[0], 0)
  const servicePid = Number(output.trim())
  assert.ok(Number.isInteger(servicePid) && servicePid > 0)
  t.after(() => { try { process.kill(servicePid, 'SIGKILL') } catch {} })
  let ready = false
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      if ((await request(port, '/health')).status === 200) { ready = true; break }
    } catch {}
    await delay(20)
  }
  assert.equal(ready, true)
  const owner = await sleeper(t)
  const urls = JSON.parse((await register(port, directory, owner.pid, ['.'], ['file.txt'])).body).urls
  const url = new URL(urls['file.txt'])
  assert.equal((await request(port, url.pathname)).status, 200)
  await stop(owner)
  assert.equal((await request(port, url.pathname)).status, 404)
  const deadline = performance.now() + 32_000
  let listening = true
  while (performance.now() < deadline) {
    try { await request(port, '/health') } catch { listening = false; break }
    await delay(200)
  }
  assert.equal(listening, false, 'service exits at the 30-second purge after its registered PID dies')
})

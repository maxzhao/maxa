import assert from 'node:assert/strict'
import { createReadStream } from 'node:fs'
import { mkdtemp, readFile, stat, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { Readable } from 'node:stream'
import test from 'node:test'
import { normalizeFilename, UploadError, UploadSession } from '../src/session.mjs'

async function fixture(limits = { fileBytes: 20, sessionBytes: 40 }) {
  const projectRoot = await mkdtemp(path.join(os.tmpdir(), 'chat-upload-'))
  return { projectRoot, session: await UploadSession.create({ projectRoot, limits, now: () => new Date('2026-08-27T12:00:00Z') }) }
}

async function upload(session, name, value, mediaType = 'text/plain') {
  const data = Buffer.from(value)
  return session.acceptStream({ stream: Readable.from(data), filename: name, mediaType, declaredBytes: data.length })
}

test('normalizes path-like names and preserves usable extension', () => {
  assert.equal(normalizeFilename('../../photo.jpg'), 'photo.jpg')
  assert.equal(normalizeFilename('\\bad\u0000/name.txt'), 'name.txt')
  assert.equal(normalizeFilename('...'), 'upload')
})

test('uploads stream, persists manifest, suffixes collisions, removes, and submits in order', async () => {
  const { projectRoot, session } = await fixture()
  const first = await upload(session, 'photo.jpg', 'one')
  const second = await upload(session, 'photo.jpg', 'two')
  assert.equal(first.stored_name, 'photo.jpg')
  assert.equal(second.stored_name, 'photo-2.jpg')
  const manifest = JSON.parse(await readFile(session.manifestPath, 'utf8'))
  assert.deepEqual(manifest.files.map((file) => file.stored_name), ['photo.jpg', 'photo-2.jpg'])
  await session.remove(first.id)
  await assert.rejects(stat(path.join(projectRoot, first.relative_path)), { code: 'ENOENT' })
  assert.deepEqual(await session.submit(), [second.relative_path])
  await assert.rejects(session.cancel(), (error) => error.code === 'session_terminal')
})

test('enforces injected file and concurrent session reservations without losing completed files', async () => {
  const { session } = await fixture({ fileBytes: 5, sessionBytes: 8 })
  await upload(session, 'kept.txt', '123')
  assert.throws(() => session.reserve(6), (error) => error.code === 'file_too_large' && error.status === 413)
  const reservation = session.reserve(5)
  assert.throws(() => session.reserve(1), (error) => error.code === 'session_too_large')
  session.release(reservation)
  assert.equal(session.files.length, 1)
})

test('deletes partial file when observed bytes exceed declaration', async () => {
  const { session } = await fixture()
  await assert.rejects(
    session.acceptStream({ stream: Readable.from(Buffer.from('12345')), filename: 'bad', declaredBytes: 3 }),
    (error) => error.code === 'file_too_large',
  )
  const entries = await import('node:fs/promises').then(({ readdir }) => readdir(session.directory))
  assert.equal(entries.some((name) => name.startsWith('.partial-')), false)
  assert.equal(session.inProgress.size, 0)
})

 test('remove restores file and manifest record when manifest persistence fails', async () => {
  const { projectRoot, session } = await fixture()
  const file = await upload(session, 'keep.txt', 'safe')
  const manifestBefore = await readFile(session.manifestPath, 'utf8')
  session.persist = async () => { throw new Error('injected manifest failure') }

  await assert.rejects(session.remove(file.id), /injected manifest failure/)

  assert.deepEqual(session.files, [file])
  assert.equal(await readFile(path.join(projectRoot, file.relative_path), 'utf8'), 'safe')
  assert.equal(await readFile(session.manifestPath, 'utf8'), manifestBefore)
})

test('remove restores file and manifest when final staged unlink fails', async () => {
  let failStagedUnlink = true
  const { projectRoot, session } = await fixture()
  const originalUnlink = session.fs.unlink
  session.fs.unlink = async (filename) => {
    if (failStagedUnlink && path.basename(filename).startsWith('.removing-')) {
      failStagedUnlink = false
      throw Object.assign(new Error('injected unlink failure'), { code: 'EIO' })
    }
    return originalUnlink(filename)
  }
  const file = await upload(session, 'keep.txt', 'safe')
  await assert.rejects(session.remove(file.id), /injected unlink failure/)
  assert.deepEqual(session.files, [file])
  assert.equal(await readFile(path.join(projectRoot, file.relative_path), 'utf8'), 'safe')
  assert.equal(JSON.parse(await readFile(session.manifestPath, 'utf8')).files[0].id, file.id)
})

test('serialized mutations cannot publish an older manifest after a newer mutation', async () => {
  const { session } = await fixture()
  const snapshots = []
  let releaseFirst
  const firstBlocked = new Promise((resolve) => { releaseFirst = resolve })
  let calls = 0
  session.persist = async function () {
    const snapshot = this.snapshot()
    calls += 1
    if (calls === 1) await firstBlocked
    snapshots.push(snapshot.files.map((file) => file.stored_name))
  }
  const first = upload(session, 'one.txt', '1')
  while (calls === 0) await new Promise((resolve) => setImmediate(resolve))
  const second = upload(session, 'two.txt', '2')
  await new Promise((resolve) => setImmediate(resolve))
  assert.equal(calls, 1)
  releaseFirst()
  await Promise.all([first, second])
  assert.deepEqual(snapshots, [['one.txt'], ['one.txt', 'two.txt']])
})

test('submit and cancel persistence failures restore active state', async () => {
  const { session } = await fixture()
  await upload(session, 'keep.txt', 'safe')
  const realPersist = session.persist.bind(session)
  session.persist = async () => { throw new Error('injected terminal persist failure') }
  await assert.rejects(session.submit(), /injected terminal persist failure/)
  assert.equal(session.state, 'active')
  await assert.rejects(session.cancel(), /injected terminal persist failure/)
  assert.equal(session.state, 'active')
  session.persist = realPersist
  assert.deepEqual(await session.submit(), [session.files[0].relative_path])
})

test('cancel preserves completed files and clears partial reservations', async () => {
  const { projectRoot, session } = await fixture()
  const file = await upload(session, 'keep.txt', 'safe')
  await session.cancel()
  assert.equal((await stat(path.join(projectRoot, file.relative_path))).isFile(), true)
  assert.equal(session.state, 'cancelled')
})

import { randomBytes } from 'node:crypto'
import { createReadStream, createWriteStream } from 'node:fs'
import { link, mkdir, rename, rm, stat, unlink, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { pipeline } from 'node:stream/promises'

export const DEFAULT_LIMITS = Object.freeze({
  fileBytes: 2 * 1024 * 1024 * 1024,
  sessionBytes: 10 * 1024 * 1024 * 1024,
})

const CONTROL = /[\u0000-\u001f\u007f]/g
const SEPARATORS = /[\\/]+/g
const EDGE_JUNK = /^[\s.]+|[\s.]+$/g

export function normalizeFilename(input) {
  const segments = String(input ?? '').replace(CONTROL, '').split(SEPARATORS)
  let name = (segments.at(-1) ?? '').replace(EDGE_JUNK, '').trim()
  if (!name || name === '.' || name === '..') return 'upload'
  return name.slice(0, 240) || 'upload'
}

function splitName(name) {
  const extension = path.extname(name)
  const stem = name.slice(0, name.length - extension.length) || 'upload'
  return { stem, extension }
}

async function atomicJson(filename, value) {
  const temporary = `${filename}.tmp-${randomBytes(6).toString('hex')}`
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { flag: 'wx' })
  await rename(temporary, filename)
}

export class UploadError extends Error {
  constructor(code, message, status = 400) {
    super(message)
    this.code = code
    this.status = status
  }
}

export class UploadSession {
  static async create({ projectRoot, uploadRoot, limits = DEFAULT_LIMITS, now = () => new Date(), fsOps = {} }) {
    const root = path.resolve(projectRoot)
    const base = path.resolve(uploadRoot ?? path.join(root, '.maxa', 'upload'))
    const relativeBase = path.relative(root, base)
    if (relativeBase.startsWith('..') || path.isAbsolute(relativeBase)) {
      throw new UploadError('upload_root_outside_project', 'Upload root must be inside the project root')
    }
    const timestamp = now().toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z')
    const sessionId = `${timestamp}-${randomBytes(8).toString('hex')}`
    await mkdir(base, { recursive: true })
    const directory = path.join(base, sessionId)
    await mkdir(directory, { recursive: false })
    const session = new UploadSession({ root, directory, sessionId, limits, now, fsOps })
    await session.persist()
    return session
  }

  constructor({ root, directory, sessionId, limits, now, fsOps = {} }) {
    this.projectRoot = root
    this.directory = directory
    this.sessionId = sessionId
    this.limits = { ...DEFAULT_LIMITS, ...limits }
    this.now = now
    this.state = 'active'
    this.files = []
    this.inProgress = new Map()
    this.reservedBytes = 0
    this.nextFileId = 1
    this.manifestPath = path.join(directory, '.manifest.json')
    this.fs = { link, rename, rm, stat, unlink, ...fsOps }
    this.mutationTail = Promise.resolve()
  }

  mutate(operation) {
    const pending = this.mutationTail.then(operation, operation)
    this.mutationTail = pending.catch(() => {})
    return pending
  }

  snapshot() {
    return {
      session_id: this.sessionId,
      state: this.state,
      limits: { file_bytes: this.limits.fileBytes, session_bytes: this.limits.sessionBytes },
      files: this.files.map((record) => ({ ...record })),
      in_progress: this.inProgress.size,
    }
  }

  async persist() {
    await atomicJson(this.manifestPath, this.snapshot())
  }

  assertActive() {
    if (this.state !== 'active') throw new UploadError('session_terminal', 'The upload session has ended', 409)
  }

  completedBytes() {
    return this.files.reduce((sum, file) => sum + file.size, 0)
  }

  reserve(declaredBytes) {
    this.assertActive()
    if (!Number.isSafeInteger(declaredBytes) || declaredBytes < 0) {
      throw new UploadError('content_length_required', 'A valid file size is required', 411)
    }
    if (declaredBytes > this.limits.fileBytes) {
      throw new UploadError('file_too_large', 'File exceeds the per-file limit', 413)
    }
    if (this.completedBytes() + this.reservedBytes + declaredBytes > this.limits.sessionBytes) {
      throw new UploadError('session_too_large', 'Session capacity would be exceeded', 413)
    }
    const reservation = randomBytes(12).toString('hex')
    this.inProgress.set(reservation, { declaredBytes, temporaryPath: null })
    this.reservedBytes += declaredBytes
    return reservation
  }

  release(reservation) {
    const item = this.inProgress.get(reservation)
    if (!item) return
    this.reservedBytes -= item.declaredBytes
    this.inProgress.delete(reservation)
  }

  async finalizeUnique(temporaryPath, clientName) {
    const normalized = normalizeFilename(clientName)
    const { stem, extension } = splitName(normalized)
    let candidate = normalized
    for (let suffix = 2; ; suffix += 1) {
      try {
        await this.fs.link(temporaryPath, path.join(this.directory, candidate))
        await this.fs.unlink(temporaryPath)
        return candidate
      } catch (error) {
        if (error.code !== 'EEXIST') throw error
        candidate = `${stem}-${suffix}${extension}`
      }
    }
  }

  async acceptStream({ stream, filename, mediaType = 'application/octet-stream', declaredBytes, allowUnknownSize = false }) {
    const capacity = this.limits.sessionBytes - this.completedBytes() - this.reservedBytes
    const reservedBytes = allowUnknownSize ? Math.min(this.limits.fileBytes, capacity) : declaredBytes
    if (allowUnknownSize && reservedBytes <= 0) throw new UploadError('session_too_large', 'Session capacity would be exceeded', 413)
    const reservation = this.reserve(reservedBytes)
    const temporaryPath = path.join(this.directory, `.partial-${reservation}`)
    const progress = this.inProgress.get(reservation)
    progress.temporaryPath = temporaryPath
    progress.stream = stream
    let observed = 0
    const counter = async function* (source) {
      for await (const chunk of source) {
        observed += chunk.length
        if ((!allowUnknownSize && observed > declaredBytes) || observed > reservedBytes || observed > this.limits.fileBytes) {
          const code = !allowUnknownSize && observed > declaredBytes ? 'file_too_large' : (observed > this.limits.fileBytes ? 'file_too_large' : 'session_too_large')
          throw new UploadError(code, 'Observed file bytes exceed the upload capacity limit', 413)
        }
        yield chunk
      }
    }.bind(this)
    try {
      await pipeline(stream, counter, createWriteStream(temporaryPath, { flags: 'wx' }))
      if (!allowUnknownSize && observed !== declaredBytes) throw new UploadError('size_mismatch', 'Observed file size does not match the declared size', 400)
      return await this.mutate(async () => {
        this.assertActive()
        const storedName = await this.finalizeUnique(temporaryPath, filename)
        const relativePath = path.relative(this.projectRoot, path.join(this.directory, storedName)).split(path.sep).join('/')
        const record = {
          id: `file-${this.nextFileId++}-${randomBytes(5).toString('hex')}`,
          original_name: String(filename ?? ''),
          stored_name: storedName,
          relative_path: relativePath,
          size: observed,
          media_type: mediaType || 'application/octet-stream',
          completed_at: this.now().toISOString(),
        }
        this.files.push(record)
        this.release(reservation)
        try {
          await this.persist()
        } catch (error) {
          this.files.pop()
          await this.fs.rm(path.join(this.directory, storedName), { force: true })
          throw error
        }
        return { ...record }
      })
    } catch (error) {
      this.release(reservation)
      await this.fs.rm(temporaryPath, { force: true }).catch(() => {})
      throw error
    }
  }

  async remove(fileId) {
    return this.mutate(async () => {
      this.assertActive()
      const index = this.files.findIndex((file) => file.id === fileId)
      if (index < 0) throw new UploadError('file_not_found', 'Completed file was not found', 404)
      const record = this.files[index]
      const storedPath = path.join(this.directory, record.stored_name)
      const stagedPath = path.join(this.directory, `.removing-${randomBytes(12).toString('hex')}`)
      await this.fs.rename(storedPath, stagedPath)
      this.files.splice(index, 1)
      try {
        await this.persist()
      } catch (error) {
        this.files.splice(index, 0, record)
        try {
          await this.fs.rename(stagedPath, storedPath)
        } catch (restoreError) {
          throw new AggregateError([error, restoreError], 'Manifest persistence failed and the removed file could not be restored')
        }
        throw error
      }
      try {
        await this.fs.unlink(stagedPath)
      } catch (error) {
        this.files.splice(index, 0, record)
        try {
          await this.fs.rename(stagedPath, storedPath)
          await this.persist()
        } catch (restoreError) {
          throw new AggregateError([error, restoreError], 'Final file deletion failed and file/manifest state could not be restored')
        }
        throw error
      }
      return record
    })
  }

  async submit() {
    return this.mutate(async () => {
      this.assertActive()
      if (this.files.length === 0) throw new UploadError('submit_empty', 'At least one completed file is required', 400)
      if (this.inProgress.size > 0) throw new UploadError('uploads_in_progress', 'Uploads are still in progress', 409)
      this.state = 'submitted'
      try {
        await this.persist()
      } catch (error) {
        this.state = 'active'
        throw error
      }
      return this.files.map((file) => file.relative_path)
    })
  }

  async cancel() {
    return this.mutate(async () => {
      this.assertActive()
      this.state = 'cancelled'
      try {
        await this.persist()
      } catch (error) {
        this.state = 'active'
        throw error
      }
      await this.cleanupPartials()
    })
  }

  async forceCancel() {
    if (this.state === 'active') this.state = 'cancelled'
    await this.cleanupPartials()
    await this.mutationTail
    await this.persist()
  }

  async cleanupPartials() {
    const pending = [...this.inProgress.values()]
    this.inProgress.clear()
    this.reservedBytes = 0
    for (const item of pending) item.stream?.destroy(new UploadError('upload_cancelled', 'Upload was cancelled', 409))
    await Promise.all(pending.map(({ temporaryPath }) => temporaryPath ? this.fs.rm(temporaryPath, { force: true }).catch(() => {}) : undefined))
  }

  async validateFiles() {
    for (const file of this.files) {
      const info = await this.fs.stat(path.join(this.directory, file.stored_name))
      if (!info.isFile() || info.size !== file.size) return false
    }
    return true
  }
}

import { createHash } from 'node:crypto'
import { constants } from 'node:fs'
import { open, realpath, stat } from 'node:fs/promises'
import http from 'node:http'
import https from 'node:https'
import path from 'node:path'

const BODY_LIMIT = 1024 * 1024
const CONTENT_TYPES = new Map(Object.entries({
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.gif': 'image/gif', '.webp': 'image/webp', '.svg': 'image/svg+xml',
  '.pdf': 'application/pdf', '.txt': 'text/plain', '.text': 'text/plain',
  '.md': 'text/plain', '.log': 'text/plain', '.csv': 'text/csv',
  '.json': 'application/json', '.xml': 'text/plain', '.yaml': 'text/plain',
  '.yml': 'text/plain', '.html': 'text/plain', '.htm': 'text/plain',
  '.css': 'text/css', '.js': 'text/plain', '.mjs': 'text/plain',
  '.lua': 'text/plain', '.py': 'text/plain', '.sh': 'text/plain',
  '.toml': 'text/plain', '.ini': 'text/plain', '.conf': 'text/plain',
  '.mp3': 'audio/mpeg', '.wav': 'audio/wav', '.ogg': 'audio/ogg',
  '.oga': 'audio/ogg', '.opus': 'audio/ogg', '.flac': 'audio/flac',
  '.aac': 'audio/aac', '.m4a': 'audio/mp4', '.mp4': 'video/mp4',
  '.m4v': 'video/mp4', '.webm': 'video/webm', '.ogv': 'video/ogg',
  '.mov': 'video/quicktime',
}))

function keyFor(realPath) {
  return createHash('sha256').update(path.resolve(realPath)).digest('hex')
}

function pidAlive(pid) {
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return error.code === 'EPERM'
  }
}

function within(root, file) {
  const relative = path.relative(root, file)
  return relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative)
}

function loopback(address) {
  return address === '::1' || /^127\./.test(address ?? '') || /^::ffff:127\./i.test(address ?? '')
}

function json(response, status, body) {
  const data = JSON.stringify(body)
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(data),
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
  })
  response.end(data)
}

function readRegistration(request) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let size = 0
    let exceeded = false
    request.on('data', (chunk) => {
      size += chunk.length
      if (exceeded) return
      if (size > BODY_LIMIT) {
        exceeded = true
        chunks.length = 0
        reject(Object.assign(new Error('Registration body exceeds limit'), { status: 413 }))
      } else chunks.push(chunk)
    })
    request.on('error', reject)
    request.on('end', () => {
      if (exceeded) return
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')))
      } catch {
        reject(Object.assign(new Error('Invalid JSON'), { status: 400 }))
      }
    })
  })
}

function validRegistration(body) {
  return body && !Array.isArray(body)
    && Number.isSafeInteger(body.pid) && body.pid > 0
    && typeof body.project_root === 'string' && path.isAbsolute(body.project_root)
    && Array.isArray(body.allowed_roots) && body.allowed_roots.every((root) => typeof root === 'string')
    && Array.isArray(body.paths) && body.paths.every((file) => typeof file === 'string')
}

function fileRoute(rawPath) {
  // Do not use URL.pathname: URL parsing removes even percent-encoded dot segments.
  const parts = rawPath.split('/')
  if (parts.length < 5 || parts[1] !== 'files'
    || !/^[a-f0-9]{64}$/.test(parts[2]) || !/^[a-f0-9]{64}$/.test(parts[3])) return null
  try {
    const segments = parts.slice(4).map((part) => decodeURIComponent(part))
    if (segments.some((part) => !part || part === '.' || part === '..' || /[/\\\0]/.test(part))) return null
    return { projectKey: parts[2], rootKey: parts[3], segments }
  } catch {
    return null
  }
}

export function createFileLinksServer({ hostname = '127.0.0.1', tls: credentials } = {}) {
  // Only PID/project -> real roots are retained; no process handles or per-file grants.
  const projects = new Map()
  let purgeTimer
  let stopping = false

  function authorizedRoot(projectKey, rootKey, file) {
    const registrations = projects.get(projectKey)
    if (!registrations) return null
    for (const [pid, roots] of registrations) {
      const root = roots.get(rootKey)
      if (root && pidAlive(pid) && (file === undefined || within(root, file))) return root
    }
    return null
  }

  async function register(request, response) {
    if (!loopback(request.socket.remoteAddress)) return json(response, 403, { error: 'loopback_required' })
    if (!/^application\/json(?:\s*;.*)?$/i.test(request.headers['content-type'] ?? '')) {
      request.resume()
      return json(response, 415, { error: 'application_json_required' })
    }
    let body
    try {
      body = await readRegistration(request)
    } catch (error) {
      return json(response, error.status ?? 400, { error: error.status === 413 ? 'body_too_large' : 'invalid_json' })
    }
    if (!validRegistration(body)) return json(response, 400, { error: 'invalid_registration' })
    if (!pidAlive(body.pid)) return json(response, 400, { error: 'pid_not_alive' })
    let project
    try {
      project = await realpath(body.project_root)
      if (!(await stat(project)).isDirectory()) throw new Error('not a directory')
    } catch {
      return json(response, 400, { error: 'invalid_project_root' })
    }
    const roots = new Map()
    for (const original of body.allowed_roots) {
      try {
        const root = await realpath(path.resolve(project, original))
        if ((await stat(root)).isDirectory()) roots.set(keyFor(root), root)
      } catch {
        // Missing or invalid roots grant no access.
      }
    }
    const projectKey = keyFor(project)
    const orderedRoots = [...roots].sort(([leftKey, left], [rightKey, right]) => right.length - left.length || leftKey.localeCompare(rightKey))
    const urls = Object.create(null)
    const origin = `${credentials ? 'https' : 'http'}://${hostname}:${server.address().port}`
    for (const original of body.paths) {
      try {
        const file = await realpath(path.resolve(project, original))
        if (!(await stat(file)).isFile()) continue
        const selected = orderedRoots.find(([, root]) => within(root, file))
        if (!selected) continue
        const [rootKey, root] = selected
        const relative = path.relative(root, file).split(path.sep)
        if (relative.some((part) => !part || /[\\\0]/.test(part))) continue
        const encoded = relative.map((segment) => encodeURIComponent(segment).replace(/[!'()*]/g,
          (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`)).join('/')
        urls[original] = `${origin}/files/${projectKey}/${rootKey}/${encoded}`
      } catch {
        // A missing, nonregular or disallowed file is absent, not a failed registration.
      }
    }
    if (stopping) return json(response, 503, { error: 'stopping' })
    if (!pidAlive(body.pid)) return json(response, 400, { error: 'pid_not_alive' })
    if (!projects.has(projectKey)) projects.set(projectKey, new Map())
    projects.get(projectKey).set(body.pid, roots)
    json(response, 200, { urls })
  }

  async function serveFile(request, response, route) {
    let handle
    try {
      const root = authorizedRoot(route.projectKey, route.rootKey)
      if (!root) return json(response, 404, { error: 'not_found' })
      const candidate = path.resolve(root, ...route.segments)
      const file = await realpath(candidate)
      if (!within(root, file) || !(await stat(file)).isFile()) return json(response, 404, { error: 'not_found' })
      handle = await open(file, constants.O_RDONLY | constants.O_NONBLOCK | constants.O_NOFOLLOW)
      const info = await handle.stat()
      // Linux/WSL additionally resolves the open descriptor; other hosts retain inode/realpath checks.
      const opened = process.platform === 'linux' ? await realpath(`/proc/self/fd/${handle.fd}`) : file
      const current = await realpath(candidate)
      const currentInfo = await stat(current)
      if (!info.isFile() || opened !== current || currentInfo.dev !== info.dev || currentInfo.ino !== info.ino
        || !authorizedRoot(route.projectKey, route.rootKey, opened)) {
        return json(response, 404, { error: 'not_found' })
      }
      const type = CONTENT_TYPES.get(path.extname(current).toLowerCase())
      const filename = encodeURIComponent(path.basename(current)).replace(/['()*]/g, (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`)
      response.writeHead(200, {
        'content-type': type ? `${type}${type.startsWith('text/') ? '; charset=utf-8' : ''}` : 'application/octet-stream',
        'content-length': info.size,
        'content-disposition': `${type ? 'inline' : 'attachment'}; filename*=UTF-8''${filename}`,
        'cache-control': 'no-store',
        'x-content-type-options': 'nosniff',
        'content-security-policy': "sandbox; default-src 'none'",
      })
      if (request.method === 'HEAD') return response.end()
      const stream = handle.createReadStream({ autoClose: true })
      handle = undefined
      response.once('close', () => stream.destroy())
      stream.once('error', () => response.destroy())
      stream.pipe(response)
    } catch {
      if (!response.headersSent) json(response, 404, { error: 'not_found' })
      else response.destroy()
    } finally {
      await handle?.close().catch(() => {})
    }
  }

  const handler = async (request, response) => {
    const rawPath = (request.url ?? '').split('?')[0]
    if (rawPath === '/health' && request.method === 'GET') {
      if (!loopback(request.socket.remoteAddress)) return json(response, 403, { error: 'loopback_required' })
      return json(response, 200, { service: 'maxa-file-links', version: 1 })
    }
    if (rawPath === '/register' && request.method === 'POST') return register(request, response)
    if (request.method === 'GET' || request.method === 'HEAD') {
      const route = fileRoute(rawPath)
      if (route) return serveFile(request, response, route)
    }
    request.resume()
    return json(response, 404, { error: 'not_found' })
  }
  const onRequest = (request, response) => {
    handler(request, response).catch(() => {
      if (!response.headersSent) json(response, 500, { error: 'internal_error' })
      else response.destroy()
    })
  }
  const server = credentials ? https.createServer(credentials, onRequest) : http.createServer(onRequest)
  server.requestTimeout = 15_000
  server.headersTimeout = 10_000
  server.once('listening', () => {
    purgeTimer = setInterval(() => {
      for (const [projectKey, registrations] of projects) {
        for (const pid of registrations.keys()) if (!pidAlive(pid)) registrations.delete(pid)
        if (registrations.size === 0) projects.delete(projectKey)
      }
      if (projects.size === 0) {
        stopping = true
        clearInterval(purgeTimer)
        server.close()
        server.closeAllConnections()
      }
    }, 30_000)
  })
  server.once('close', () => clearInterval(purgeTimer))
  return server
}

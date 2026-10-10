import { createReadStream } from 'node:fs'
import { readFile, stat } from 'node:fs/promises'
import https from 'node:https'
import http from 'node:http'
import path from 'node:path'
import Busboy from 'busboy'
import { UploadError } from './session.mjs'
import { importPublicUrl } from './url_import.mjs'

const CONTENT_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
}

function json(response, status, body) {
  const encoded = Buffer.from(JSON.stringify(body))
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': encoded.length,
    'cache-control': 'no-store',
  })
  response.end(encoded)
}

function errorResponse(response, error) {
  const status = error instanceof UploadError ? error.status : 500
  const code = error instanceof UploadError ? error.code : 'internal_error'
  json(response, status, { error: { code, message: error instanceof UploadError ? error.message : 'Internal server error' } })
}

async function uploadMultipart(request, session) {
  const declaredBytes = Number(request.headers['x-upload-size'])
  if (!Number.isSafeInteger(declaredBytes) || declaredBytes < 0) {
    throw new UploadError('upload_size_required', 'X-Upload-Size must contain the file byte size', 411)
  }
  let uploadPromise
  let fileCount = 0
  let parseError
  const busboy = Busboy({ headers: request.headers, limits: { files: 1, fields: 20, parts: 21 } })
  busboy.on('file', (_field, stream, info) => {
    fileCount += 1
    if (fileCount > 1) {
      stream.resume()
      parseError = new UploadError('one_file_required', 'Exactly one file is accepted per request', 400)
      return
    }
    uploadPromise = session.acceptStream({ stream, filename: info.filename, mediaType: info.mimeType, declaredBytes })
    uploadPromise.catch(() => stream.resume())
  })
  busboy.on('filesLimit', () => { parseError = new UploadError('one_file_required', 'Exactly one file is accepted per request', 400) })
  const parsed = new Promise((resolve, reject) => {
    busboy.on('finish', resolve)
    busboy.on('error', reject)
    request.on('aborted', () => reject(new UploadError('upload_interrupted', 'Upload was interrupted', 400)))
    request.on('error', reject)
  })
  request.pipe(busboy)
  await parsed
  if (parseError) throw parseError
  if (!uploadPromise) throw new UploadError('file_required', 'Multipart request did not include a file', 400)
  return uploadPromise
}

export function createUploadServer({ session, token, webRoot, tls: tlsOptions, loopback = false, onTerminal = () => {}, terminalDelayMs = 75 }) {
  if (!loopback && (!tlsOptions?.cert || !tlsOptions?.key)) throw new TypeError('HTTPS certificate and key are required')
  const prefix = `/session/${token}`
  let terminalScheduled = false
  const sockets = new Set()
  const scheduleTerminal = (event) => {
    if (terminalScheduled) return
    terminalScheduled = true
    setTimeout(() => onTerminal(event), terminalDelayMs).unref?.()
  }

  const server = (loopback ? http.createServer : (handler) => https.createServer(tlsOptions, handler))(async (request, response) => {
    try {
      const url = new URL(request.url, 'http://localhost')
      if (url.pathname !== prefix && !url.pathname.startsWith(`${prefix}/`)) return json(response, 404, { error: { code: 'not_found', message: 'Not found' } })
      const relative = url.pathname.slice(prefix.length) || '/'

      if (request.method === 'GET' && relative === '/api/state') return json(response, 200, session.snapshot())
      if (request.method === 'POST' && relative === '/api/files') {
        session.assertActive()
        const record = await uploadMultipart(request, session)
        return json(response, 201, { file: record })
      }
      if (request.method === 'POST' && relative === '/api/url-import') {
        session.assertActive()
        let body = ''
        for await (const chunk of request) {
          body += chunk
          if (Buffer.byteLength(body) > 8192) throw new UploadError('request_too_large', 'URL import request is too large', 413)
        }
        let input
        try { input = JSON.parse(body).url } catch { throw new UploadError('invalid_json', 'URL import request must be JSON', 400) }
        const record = await importPublicUrl({ input, session })
        return json(response, 201, { file: record })
      }
      if (request.method === 'DELETE' && relative.startsWith('/api/files/')) {
        const fileId = decodeURIComponent(relative.slice('/api/files/'.length))
        await session.remove(fileId)
        return json(response, 200, { removed: fileId })
      }
      if (request.method === 'POST' && relative === '/api/submit') {
        const paths = await session.submit()
        json(response, 200, { state: 'submitted', paths })
        scheduleTerminal({ event: 'submitted', paths })
        return
      }
      if (request.method === 'POST' && relative === '/api/cancel') {
        await session.cancel()
        json(response, 200, { state: 'cancelled' })
        scheduleTerminal({ event: 'cancelled' })
        return
      }
      if (request.method !== 'GET') return json(response, 404, { error: { code: 'not_found', message: 'Not found' } })

      const assetName = relative === '/' ? 'index.html' : relative.slice(1)
      if (!assetName || assetName.includes('/') || assetName.includes('\\') || assetName.includes('..')) {
        return json(response, 404, { error: { code: 'not_found', message: 'Not found' } })
      }
      const assetPath = path.join(webRoot, assetName)
      const info = await stat(assetPath).catch(() => null)
      if (!info?.isFile()) return json(response, 404, { error: { code: 'not_found', message: 'Not found' } })
      response.writeHead(200, {
        'content-type': CONTENT_TYPES[path.extname(assetPath)] ?? 'application/octet-stream',
        'content-length': info.size,
        'cache-control': 'no-store',
        'x-content-type-options': 'nosniff',
      })
      createReadStream(assetPath).pipe(response)
    } catch (error) {
      if (!response.headersSent) errorResponse(response, error)
      else response.destroy()
    }
  })
  server.loopbackOnly = loopback
  server.on('connection', (socket) => {
    sockets.add(socket)
    socket.once('close', () => sockets.delete(socket))
  })
  server.forceShutdown = async () => {
    server.closeIdleConnections?.()
    for (const socket of sockets) socket.destroy()
    if (typeof session.forceCancel === 'function') await session.forceCancel()
    else await session.cleanupPartials()
    if (server.listening) await new Promise((resolve) => server.close(resolve))
  }
  return server
}

export async function listen(server, { host = server.loopbackOnly ? '127.0.0.1' : '0.0.0.0', port = 0 } = {}) {
  if (server.loopbackOnly && host !== '127.0.0.1') throw new TypeError('HTTP upload must bind to 127.0.0.1')
  await new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen({ host, port, family: 4 }, resolve)
  })
  return server.address()
}

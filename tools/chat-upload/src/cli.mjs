#!/usr/bin/env node
import { randomBytes } from 'node:crypto'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { selectPrivateDefaultRouteIPv4 } from './network.mjs'
import { JsonlProtocol } from './protocol.mjs'
import { createUploadServer, listen } from './server.mjs'
import { UploadSession } from './session.mjs'
import { loadHttpsCredentials } from './tls.mjs'

function argumentsFrom(argv) {
  const result = {}
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--project-root') result.projectRoot = argv[++index]
    else if (argv[index] === '--upload-root') result.uploadRoot = argv[++index]
    else if (argv[index] === '--hostname') result.hostname = argv[++index]
    else throw Object.assign(new Error(`Unknown argument: ${argv[index]}`), { code: 'invalid_arguments' })
  }
  if (!result.projectRoot) throw Object.assign(new Error('--project-root is required'), { code: 'invalid_arguments' })
  return result
}

const protocol = new JsonlProtocol()
let server
let session
let terminal = false

async function shutdown(exitCode, event) {
  if (terminal) return
  terminal = true
  if (event) protocol.emit(event)
  if (server?.forceShutdown) await server.forceShutdown()
  else {
    if (server?.listening) await new Promise((resolve) => server.close(resolve))
    await session?.cleanupPartials().catch(() => {})
  }
  process.exitCode = exitCode
}

async function main() {
  const args = argumentsFrom(process.argv.slice(2))
  const hostname = args.hostname ?? '127.0.0.1'
  if (!hostname || hostname === '0.0.0.0' || hostname === 'localhost') {
    throw Object.assign(new Error('upload hostname must be 127.0.0.1 or a certificate-backed DNS name'), { code: 'invalid_arguments' })
  }
  const loopback = hostname === '127.0.0.1'
  if (!loopback) await selectPrivateDefaultRouteIPv4()
  // Shared TLS credentials belong to the Maxa runtime, not the upload destination.
  const runtimeRoot = fileURLToPath(new URL('../../../', import.meta.url))
  const credentials = loopback ? undefined : await loadHttpsCredentials(runtimeRoot, { hostname })
  session = await UploadSession.create(args)
  const token = randomBytes(32).toString('base64url')
  const webRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'dist')
  server = createUploadServer({
    session,
    token,
    webRoot,
    tls: credentials,
    loopback,
    onTerminal: async (event) => shutdown(0, event),
  })
  const bound = await listen(server)
  const url = `${loopback ? 'http' : 'https'}://${hostname}:${bound.port}/session/${token}/`
  protocol.emit({ event: 'ready', bind: loopback ? '127.0.0.1' : '0.0.0.0', host: hostname, port: bound.port, url, session_id: session.sessionId })
  protocol.log(`chat-upload listening on ${url}`)
}

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => shutdown(0, { event: 'cancelled' }).catch((error) => protocol.log(error.stack ?? error.message)))
}

process.on('uncaughtException', (error) => shutdown(1, {
  event: 'error', code: error.code ?? 'uncaught_exception', message: error.message,
}).catch(() => { process.exitCode = 1 }))

main().catch(async (error) => {
  protocol.log(error.stack ?? error.message)
  await shutdown(1, { event: 'error', code: error.code ?? 'startup_failed', message: error.message })
})

import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { createFileLinksServer } from './file_links_server.mjs'
import { selectPrivateDefaultRouteIPv4 } from './network.mjs'
import { loadHttpsCredentials } from './tls.mjs'

async function main() {
  let hostname = '127.0.0.1'
  let port = 43128
  const seen = new Set()
  const args = process.argv.slice(2)
  for (let index = 0; index < args.length; index += 2) {
    const flag = args[index]
    const value = args[index + 1]
    if (!['--hostname', '--port'].includes(flag) || value === undefined || seen.has(flag)) {
      throw new Error('Usage: node file_links_cli.mjs [--hostname HOST] [--port PORT]')
    }
    seen.add(flag)
    if (flag === '--hostname') hostname = value
    else {
      if (!/^\d+$/.test(value)) throw new Error('Port must be an integer between 1 and 65535')
      port = Number(value)
      if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Port must be an integer between 1 and 65535')
    }
  }
  let credentials
  if (hostname !== '127.0.0.1') {
    const runtimeRoot = fileURLToPath(new URL('../../../', import.meta.url))
    credentials = await loadHttpsCredentials(path.resolve(runtimeRoot), { hostname })
    await selectPrivateDefaultRouteIPv4()
  }
  const server = createFileLinksServer({ hostname, tls: credentials })
  await new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(port, hostname === '127.0.0.1' ? '127.0.0.1' : '0.0.0.0', () => {
      server.off('error', reject)
      resolve()
    })
  })
}

main().catch((error) => {
  console.error(`file-links: ${error.code ?? 'startup_failed'}: ${error.message}`)
  process.exitCode = 1
})

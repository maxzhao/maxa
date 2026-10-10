import dns from 'node:dns/promises'
import net from 'node:net'
import http from 'node:http'
import https from 'node:https'
import path from 'node:path'
import { Readable } from 'node:stream'
import { UploadError } from './session.mjs'

function forbiddenIPv4(address) {
  const parts = address.split('.').map(Number)
  const [a, b] = parts
  return a === 0 || a === 10 || a === 127 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && [0, 2, 168].includes(b)) || (a === 100 && b >= 64 && b <= 127) || (a === 198 && [18, 19, 51].includes(b)) || (a === 203 && b === 0) || a >= 224
}

export function isForbiddenAddress(address) {
  if (net.isIPv4(address)) return forbiddenIPv4(address)
  if (!net.isIPv6(address)) return true
  const normalized = address.toLowerCase()
  if (normalized === '::' || normalized === '::1' || normalized.startsWith('fe8') || normalized.startsWith('fe9') || normalized.startsWith('fea') || normalized.startsWith('feb') || normalized.startsWith('fc') || normalized.startsWith('fd') || normalized.startsWith('ff')) return true
  const mapped = normalized.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/)
  if (mapped) return forbiddenIPv4(mapped[1])
  const first = Number.parseInt(normalized.split(':')[0], 16)
  if (first < 0x2000 || first > 0x3fff) return true
  return normalized.startsWith('2001:db8:') || normalized === '2001:db8::' || normalized.startsWith('2001:2:') || normalized.startsWith('2001:10:')
}

export async function resolvePublicUrl(input, { lookup = dns.lookup } = {}) {
  let url
  try { url = new URL(input) } catch { throw new UploadError('url_invalid', 'A valid URL is required', 400) }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) throw new UploadError('url_forbidden', 'Only credential-free public HTTP(S) URLs are allowed', 400)
  const addresses = await lookup(url.hostname, { all: true, verbatim: true }).catch(() => [])
  if (addresses.length === 0) throw new UploadError('url_dns_failed', 'URL hostname could not be resolved', 400)
  if (addresses.some(({ address }) => isForbiddenAddress(address))) throw new UploadError('url_private_address', 'URL resolves to a non-public address', 400)
  return { url, addresses }
}

export async function validatePublicUrl(input, options) {
  return (await resolvePublicUrl(input, options)).url
}

function requestPinned(url, addresses) {
  return new Promise((resolve, reject) => {
    const transport = url.protocol === 'https:' ? https : http
    const request = transport.get(url, {
      lookup(_hostname, options, callback) {
        const selected = addresses.find(({ family }) => !options?.family || family === options.family) ?? addresses[0]
        callback(null, selected.address, selected.family)
      },
      servername: url.hostname,
      timeout: 30_000,
      headers: { host: url.host, 'user-agent': 'Maxa-Chat-Upload/0.1' },
    }, resolve)
    request.once('timeout', () => request.destroy(new UploadError('url_fetch_timeout', 'URL fetch timed out', 400)))
    request.once('error', reject)
  })
}

function filenameFrom(responseUrl, disposition) {
  const encoded = disposition?.match(/filename\*=UTF-8''([^;]+)/i)?.[1]
  const basic = disposition?.match(/filename="?([^";]+)"?/i)?.[1]
  if (encoded) try { return decodeURIComponent(encoded) } catch {}
  if (basic) return basic
  const basename = path.posix.basename(new URL(responseUrl).pathname)
  return basename && basename !== '/' ? basename : 'download'
}

export async function importPublicUrl({ input, session, fetchImpl, lookup = dns.lookup, maxRedirects = 5 }) {
  let resolved = await resolvePublicUrl(input, { lookup })
  for (let redirect = 0; ; redirect += 1) {
    const response = fetchImpl
      ? await fetchImpl(resolved.url, { redirect: 'manual', signal: AbortSignal.timeout(30_000) })
      : await requestPinned(resolved.url, resolved.addresses)
    const header = (name) => typeof response.headers?.get === 'function' ? response.headers.get(name) : response.headers?.[name]
    const ok = response.ok ?? (response.statusCode >= 200 && response.statusCode < 300)
    const status = response.status ?? response.statusCode
    if (status >= 300 && status < 400) {
      response.resume?.()
      if (redirect >= maxRedirects) throw new UploadError('url_redirect_limit', 'URL redirect limit exceeded', 400)
      const location = header('location')
      if (!location) throw new UploadError('url_redirect_invalid', 'URL redirect has no location', 400)
      resolved = await resolvePublicUrl(new URL(location, resolved.url).href, { lookup })
      continue
    }
    const responseBody = response.body ?? response
    if (!ok || !responseBody) {
      response.resume?.()
      throw new UploadError('url_fetch_failed', `URL returned HTTP ${status}`, 400)
    }
    const lengthHeader = header('content-length')
    const declared = lengthHeader == null ? undefined : Number(lengthHeader)
    if (declared !== undefined && (!Number.isSafeInteger(declared) || declared < 0)) throw new UploadError('url_size_invalid', 'URL returned an invalid content length', 400)
    return session.acceptStream({
      stream: typeof responseBody.getReader === 'function' ? Readable.fromWeb(responseBody) : responseBody,
      filename: filenameFrom(resolved.url.href, header('content-disposition')),
      mediaType: header('content-type')?.split(';')[0] || 'application/octet-stream',
      declaredBytes: declared,
      allowUnknownSize: declared === undefined,
    })
  }
}

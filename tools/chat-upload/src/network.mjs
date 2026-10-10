import { readFile } from 'node:fs/promises'
import os from 'node:os'

export function isPrivateIPv4(address) {
  const parts = String(address).split('.').map(Number)
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) return false
  return parts[0] === 10 || (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) || (parts[0] === 192 && parts[1] === 168)
}

export function parseLinuxDefaultInterface(routes) {
  const lines = String(routes).trim().split(/\r?\n/).slice(1)
  for (const line of lines) {
    const fields = line.trim().split(/\s+/)
    if (fields.length >= 4 && fields[1] === '00000000' && (Number.parseInt(fields[3], 16) & 0x1) === 1) return fields[0]
  }
  return null
}

export async function selectPrivateDefaultRouteIPv4({
  readRoutes = () => readFile('/proc/net/route', 'utf8'),
  interfaces = () => os.networkInterfaces(),
} = {}) {
  let interfaceName
  try {
    interfaceName = parseLinuxDefaultInterface(await readRoutes())
  } catch (error) {
    throw Object.assign(new Error(`Cannot inspect the IPv4 default route: ${error.message}`), { code: 'default_route_unavailable' })
  }
  if (!interfaceName) throw Object.assign(new Error('No IPv4 default-route interface was found'), { code: 'default_route_unavailable' })
  const candidates = interfaces()[interfaceName] ?? []
  const selected = candidates.find((entry) => entry.family === 'IPv4' && !entry.internal && isPrivateIPv4(entry.address))
  if (!selected) {
    throw Object.assign(new Error(`Default-route interface ${interfaceName} has no RFC1918 IPv4 address`), { code: 'private_lan_address_unavailable' })
  }
  return { interfaceName, address: selected.address }
}

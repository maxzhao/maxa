import { readFile } from 'node:fs/promises'
import path from 'node:path'
import tls from 'node:tls'
import { X509Certificate } from 'node:crypto'

export async function loadHttpsCredentials(projectRoot, {
  hostname,
  read = readFile,
  checkServerIdentity = tls.checkServerIdentity,
} = {}) {
  if (typeof hostname !== 'string' || hostname === '127.0.0.1'
    || !hostname.split('.').every((label) => /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/i.test(label))) {
    throw Object.assign(new Error('certificate-backed hostname is required'), { code: 'invalid_hostname' })
  }
  const certificatePath = path.join(projectRoot, 'certificates', hostname, 'fullchain.pem')
  const keyPath = path.join(projectRoot, 'certificates', hostname, 'privkey.pem')
  let cert
  let key
  try {
    ;[cert, key] = await Promise.all([read(certificatePath), read(keyPath)])
  } catch (error) {
    throw Object.assign(new Error(`HTTPS certificate or key is unavailable: ${error.message}`), { code: 'https_credentials_unavailable' })
  }
  let peer
  try {
    peer = new X509Certificate(cert).toLegacyObject()
  } catch (error) {
    throw Object.assign(new Error(`HTTPS certificate is invalid: ${error.message}`), { code: 'https_certificate_invalid' })
  }
  const identityError = checkServerIdentity(hostname, peer)
  if (identityError) {
    throw Object.assign(new Error(`HTTPS certificate does not cover ${hostname}: ${identityError.message}`), { code: 'https_hostname_mismatch' })
  }
  try {
    tls.createSecureContext({ cert, key })
  } catch (error) {
    throw Object.assign(new Error(`HTTPS certificate/key pair is invalid: ${error.message}`), { code: 'https_credentials_invalid' })
  }
  return { cert, key, hostname, certificatePath, keyPath }
}

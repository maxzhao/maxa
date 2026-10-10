import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import path from 'node:path'
import test from 'node:test'
import { loadHttpsCredentials } from '../src/tls.mjs'

const hostname = process.env.MAXA_CERT_DOMAIN

const repositoryRoot = path.resolve(import.meta.dirname, '..', '..', '..')

test('loads the mandatory project certificate and validates hostname coverage', async () => {
  assert.ok(hostname, 'MAXA_CERT_DOMAIN is required for certificate-backed upload tests')
  const credentials = await loadHttpsCredentials(repositoryRoot, { hostname })
  assert.equal(credentials.hostname, hostname)
  assert.ok(credentials.cert.length > 0)
  assert.ok(credentials.key.length > 0)
})

test('reports stable missing and hostname mismatch errors', async () => {
  assert.ok(hostname, 'MAXA_CERT_DOMAIN is required for certificate-backed upload tests')
  await assert.rejects(loadHttpsCredentials('/definitely/missing', { hostname }), (error) => error.code === 'https_credentials_unavailable')
  await assert.rejects(loadHttpsCredentials(repositoryRoot, {
    hostname, checkServerIdentity: () => new Error('injected mismatch'),
  }), (error) => error.code === 'https_hostname_mismatch')
})

test('web bundle source registers Uppy Webcam and Audio in Dashboard and removes custom capture inputs', async () => {
  const [source, html, bundledCss] = await Promise.all([
    readFile(path.join(repositoryRoot, 'tools/chat-upload/web/main.js'), 'utf8'),
    readFile(path.join(repositoryRoot, 'tools/chat-upload/web/index.html'), 'utf8'),
    readFile(path.join(repositoryRoot, 'tools/chat-upload/dist/uppy.css'), 'utf8'),
  ])
  assert.match(source, /import Webcam from '@uppy\/webcam'/)
  assert.match(source, /import Audio from '@uppy\/audio'/)
  assert.match(source, /modes: \['picture', 'video-only', 'video-audio', 'audio-only'\]/)
  assert.match(source, /showVideoSourceDropdown: true/)
  assert.match(source, /showRecordingLength: true/)
  assert.match(source, /\.use\(Audio, \{ target: Dashboard, showAudioSourceDropdown: true \}\)/)
  assert.match(source, /\.use\(ScreenCapture, \{/)
  assert.match(source, /displayMediaConstraints: \{ video: true, audio: true \}/)
  assert.match(source, /\.use\(ImageEditor, \{ target: Dashboard \}\)/)
  assert.match(source, /\.use\(Compressor, \{ quality: 0\.8 \}\)/)
  assert.match(html, /id="url-import-form"/)
  assert.doesNotMatch(html, /capture-photo|capture-video|capture-audio|capture=/)
  for (const selector of ['uppy-Webcam', 'uppy-Audio', 'uppy-ScreenCapture', 'uppy-ImageCropper']) {
    assert.match(bundledCss, new RegExp(selector))
  }
})

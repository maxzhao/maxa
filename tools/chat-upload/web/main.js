import Uppy from '@uppy/core'
import Dashboard from '@uppy/dashboard'
import XHRUpload from '@uppy/xhr-upload'
import Webcam from '@uppy/webcam'
import Audio from '@uppy/audio'
import ScreenCapture from '@uppy/screen-capture'
import ImageEditor from '@uppy/image-editor'
import Compressor from '@uppy/compressor'
import { parseXhrJson, responseErrorFromXhr } from './xhr_response.js'
import { closeOrRenderTerminal } from './terminal_page.js'

const base = new URL('.', window.location.href).pathname.replace(/\/$/, '')
const api = `${base}/api`
const completed = new Map()
const activeFiles = new Set()
const uppyToServer = new Map()
const serverToUppy = new Map()
const serverRemoval = new Set()
let terminal = false

const status = document.querySelector('#status')
const submit = document.querySelector('#submit')
const cancel = document.querySelector('#cancel')
const list = document.querySelector('#completed')
const urlImportForm = document.querySelector('#url-import-form')
const urlImportInput = document.querySelector('#url-import-input')

function setStatus(message, error = false) {
  status.textContent = message
  status.classList.toggle('error', error)
}

function updateActions() {
  submit.disabled = terminal || completed.size === 0 || activeFiles.size > 0
  cancel.disabled = terminal
}

function render() {
  list.replaceChildren(...[...completed.values()].map((file) => {
    const item = document.createElement('li')
    item.append(`${file.stored_name} (${file.size.toLocaleString()} bytes) `)
    const remove = document.createElement('button')
    remove.textContent = 'Remove'
    remove.disabled = terminal
    remove.addEventListener('click', () => removeCompleted(file.id, remove))
    item.append(remove)
    return item
  }))
  updateActions()
}

async function apiError(response) {
  const body = await response.json().catch(() => ({}))
  return new Error(body.error?.message ?? `Request failed (${response.status})`)
}

async function removeCompleted(serverId, button) {
  if (button) button.disabled = true
  try {
    const response = await fetch(`${api}/files/${encodeURIComponent(serverId)}`, { method: 'DELETE' })
    if (!response.ok) throw await apiError(response)
    completed.delete(serverId)
    const uppyId = serverToUppy.get(serverId)
    serverToUppy.delete(serverId)
    if (uppyId) {
      uppyToServer.delete(uppyId)
      serverRemoval.add(uppyId)
      uppy.removeFile(uppyId)
      serverRemoval.delete(uppyId)
    }
    render()
  } catch (error) {
    if (button) button.disabled = false
    setStatus(error.message, true)
  }
}

const uppy = new Uppy({ autoProceed: true, restrictions: { maxFileSize: 2 * 1024 * 1024 * 1024 } })
  .use(Dashboard, { inline: true, target: '#uppy', proudlyDisplayPoweredByUppy: false, showProgressDetails: true, theme: 'auto' })
  .use(Webcam, {
    target: Dashboard,
    modes: ['picture', 'video-only', 'video-audio', 'audio-only'],
    showVideoSourceDropdown: true,
    showRecordingLength: true,
  })
  .use(Audio, { target: Dashboard, showAudioSourceDropdown: true })
  .use(ScreenCapture, {
    target: Dashboard,
    displayMediaConstraints: { video: true, audio: true },
    userMediaConstraints: { audio: true },
    enableScreenshots: true,
  })
  .use(ImageEditor, { target: Dashboard })
  .use(Compressor, { quality: 0.8 })
  .use(XHRUpload, {
    endpoint: `${api}/files`,
    fieldName: 'file',
    bundle: false,
    headers(file) { return { 'X-Upload-Size': String(file.size) } },
    getResponseData: parseXhrJson,
    shouldRetry(xhr) { return xhr.status === 0 || xhr.status >= 500 },
    onAfterResponse(xhr) {
      if (xhr.status < 200 || xhr.status >= 300) throw responseErrorFromXhr(xhr)
    },
  })

uppy.on('upload', (_uploadId, files) => {
  for (const file of files) activeFiles.add(file.id)
  updateActions()
})
uppy.on('upload-success', (file, response) => {
  if (!file) return
  activeFiles.delete(file.id)
  const record = response.body?.file
  if (record) {
    completed.set(record.id, record)
    uppyToServer.set(file.id, record.id)
    serverToUppy.set(record.id, file.id)
  }
  render()
})
uppy.on('upload-error', (file, error) => {
  if (file) activeFiles.delete(file.id)
  setStatus(error.message, true)
  updateActions()
})
uppy.on('file-removed', (file) => {
  activeFiles.delete(file.id)
  const serverId = uppyToServer.get(file.id)
  if (serverId && !serverRemoval.has(file.id)) removeCompleted(serverId)
  updateActions()
})

urlImportForm.addEventListener('submit', async (event) => {
  event.preventDefault()
  const button = urlImportForm.querySelector('button')
  button.disabled = true
  try {
    const response = await fetch(`${api}/url-import`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ url: urlImportInput.value }),
    })
    if (!response.ok) throw await apiError(response)
    const { file } = await response.json()
    completed.set(file.id, file)
    urlImportInput.value = ''
    render()
  } catch (error) {
    setStatus(error.message, true)
  } finally {
    button.disabled = terminal
  }
})

async function terminalAction(name) {
  submit.disabled = cancel.disabled = true
  try {
    const response = await fetch(`${api}/${name}`, { method: 'POST' })
    if (!response.ok) throw await apiError(response)
    terminal = true
    closeOrRenderTerminal(name)
  } catch (error) {
    setStatus(error.message, true)
    updateActions()
  }
}
submit.addEventListener('click', () => terminalAction('submit'))
cancel.addEventListener('click', () => terminalAction('cancel'))

fetch(`${api}/state`).then(async (response) => {
  if (!response.ok) throw await apiError(response)
  const state = await response.json()
  for (const file of state.files) completed.set(file.id, file)
  terminal = state.state !== 'active'
  render()
}).catch((error) => setStatus(error.message, true))

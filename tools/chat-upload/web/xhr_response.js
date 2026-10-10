export function parseXhrJson(xhr) {
  if (!xhr || typeof xhr !== 'object') throw new TypeError('XHR response object is required')
  if (xhr.responseType === 'json') return xhr.response
  return JSON.parse(xhr.responseText)
}

export function responseErrorFromXhr(xhr) {
  let body
  try {
    body = parseXhrJson(xhr)
  } catch {
    body = undefined
  }
  const message = body?.error?.message || xhr?.statusText || `Request failed (${xhr?.status ?? 'unknown'})`
  const error = new Error(message)
  if (body?.error?.code) error.code = body.error.code
  return error
}

const TERMINAL_MESSAGES = Object.freeze({
  submit: '已提交，可以关闭此页',
  cancel: '已取消，可以关闭此页',
})

export function terminalMessage(action) {
  const message = TERMINAL_MESSAGES[action]
  if (!message) throw new TypeError(`Unsupported terminal action: ${action}`)
  return message
}

export function renderTerminalPage(documentObject, message) {
  documentObject.open()
  documentObject.write(`<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${message}</title><style>html{color-scheme:light dark;font-family:system-ui,sans-serif}body{min-height:100vh;margin:0;display:grid;place-items:center;background:Canvas;color:CanvasText}p{margin:1.5rem;font-size:1.25rem;text-align:center}</style></head><body><p>${message}</p></body></html>`)
  documentObject.close()
}

export function closeOrRenderTerminal(action, {
  windowObject = window,
  documentObject = document,
  schedule = (callback) => windowObject.setTimeout(callback, 0),
} = {}) {
  const message = terminalMessage(action)
  try {
    windowObject.close()
  } catch {
    renderTerminalPage(documentObject, message)
    return
  }
  schedule(() => {
    if (!windowObject.closed) renderTerminalPage(documentObject, message)
  })
}

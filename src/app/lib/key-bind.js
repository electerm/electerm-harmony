/**
 * disable some default keyboard shortcuts
 */

exports.disableShortCuts = function (win) {
  win.webContents.on('before-input-event', (event, input) => {
    if (
      input.key.toLowerCase() === 'r' &&
      input.control && input.shift
    ) {
      event.preventDefault()
    }
  })
}

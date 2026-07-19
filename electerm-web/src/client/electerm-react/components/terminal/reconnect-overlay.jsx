import { memo } from 'react'

const e = window.translate

export default memo(function ReconnectOverlay ({ countdown }) {
  if (countdown === null || countdown === undefined) {
    return null
  }
  return (
    <div className='terminal-reconnect-overlay'>
      {e('autoReconnectTerminal')}: {countdown}s
    </div>
  )
})

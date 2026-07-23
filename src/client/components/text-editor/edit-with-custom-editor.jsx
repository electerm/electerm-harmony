/**
 * Edit with custom editor - input + button component
 */

import { useState } from 'react'
import { Button, Input, Space } from 'antd'
import { safeGetItem, safeSetItem } from '../../common/safe-local-storage.js'

export const CUSTOM_EDITOR_COMMAND_LS_KEY = 'customEditorCommand'
export const CUSTOM_EDITOR_AUTO_OPEN_LS_KEY = 'customEditorAutoOpen'
const e = window.translate

export default function EditWithCustomEditor ({ loading, editWithCustom }) {
  const [editorCommand, setEditorCommand] = useState(
    () => safeGetItem(CUSTOM_EDITOR_COMMAND_LS_KEY) || ''
  )
  const [autoOpen, setAutoOpen] = useState(
    () => safeGetItem(CUSTOM_EDITOR_AUTO_OPEN_LS_KEY) === 'true'
  )

  const autoOpenLabel = e('autoOpen')

  function handleChange (ev) {
    const val = ev.target.value
    setEditorCommand(val)
    safeSetItem(CUSTOM_EDITOR_COMMAND_LS_KEY, val)
  }

  function handleToggleAutoOpen () {
    const next = !autoOpen
    setAutoOpen(next)
    safeSetItem(CUSTOM_EDITOR_AUTO_OPEN_LS_KEY, String(next))
  }

  function handleClick () {
    const cmd = editorCommand.trim()
    if (cmd) {
      editWithCustom(cmd)
    }
  }

  if (window.et.isWebApp) {
    return null
  }

  return (
    <Space.Compact className='mg1b'>
      <Button
        type='primary'
        disabled={loading || !editorCommand.trim()}
        onClick={handleClick}
      >
        {e('editWith')}
      </Button>
      <Input
        value={editorCommand}
        onChange={handleChange}
        disabled={loading}
      />
      <Button
        type={autoOpen ? 'primary' : 'default'}
        disabled={loading}
        onClick={handleToggleAutoOpen}
      >
        {autoOpenLabel}: {autoOpen ? 'On' : 'Off'}
      </Button>
    </Space.Compact>
  )
}

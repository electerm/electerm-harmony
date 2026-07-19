/**
 * Global tooltip that detects Unix timestamps in terminal selections
 * and displays their human-readable date/time near the cursor.
 * Registered via refsStatic as 'unix-timestamp-tooltip'.
 */

import { Component } from 'react'
import { refsStatic } from '../common/ref'

export default class UnixTimestampTooltip extends Component {
  state = {
    visible: false,
    x: 0,
    y: 0,
    text: ''
  }

  _mouseX = 0
  _mouseY = 0

  componentDidMount () {
    refsStatic.add('unix-timestamp-tooltip', this)
    document.addEventListener('mousemove', this.onMouseMove)
  }

  componentWillUnmount () {
    refsStatic.remove('unix-timestamp-tooltip')
    document.removeEventListener('mousemove', this.onMouseMove)
  }

  detectUnixTimestamp (txt) {
    if (!/^\d+$/.test(txt)) return null
    const num = parseInt(txt, 10)
    // seconds: 9-10 digits, year ~2001-2286
    if ((txt.length === 9 || txt.length === 10) && num >= 946684800 && num <= 32503680000) {
      return new Date(num * 1000).toLocaleString()
    }
    // milliseconds: 13 digits
    if (txt.length === 13 && num >= 946684800000 && num <= 32503680000000) {
      return new Date(num).toLocaleString()
    }
    return null
  }

  onMouseMove = (e) => {
    this._mouseX = e.clientX
    this._mouseY = e.clientY
  }

  onSelection = (txt) => {
    const ts = this.detectUnixTimestamp(txt)
    if (ts) {
      this.setState({ visible: true, x: this._mouseX, y: this._mouseY, text: ts })
    } else {
      this.setState({ visible: false })
    }
  }

  render () {
    const { visible, x, y, text } = this.state
    if (!visible) {
      return null
    }
    return (
      <div
        style={{
          position: 'fixed',
          left: x,
          top: y - 36,
          background: 'rgba(0,0,0,0.75)',
          color: '#fff',
          padding: '3px 8px',
          borderRadius: 4,
          fontSize: 12,
          whiteSpace: 'nowrap',
          pointerEvents: 'none',
          transform: 'translateX(-50%)',
          zIndex: 9999
        }}
      >
        {text}
      </div>
    )
  }
}

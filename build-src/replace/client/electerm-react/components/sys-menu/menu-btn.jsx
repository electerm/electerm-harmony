/**
 * btns
 * HarmonyOS replacement: no devtools/minimize/maximize/check-update/close
 */

import { PureComponent } from 'react'
import {
  Popover
} from 'antd'
import logoSvg from '@electerm/electerm-resource/res/imgs/electerm.svg?raw'
import { shortcutDescExtend } from '../shortcuts/shortcut-handler.js'
import MenuRender from './sys-menu.jsx'
import { refsStatic } from '../common/ref.js'

const e = window.translate

class MenuBtn extends PureComponent {
  componentDidMount () {
    refsStatic.add('menu-btn', this)
  }

  onNewSsh = () => {
    window.store.onNewSsh()
  }

  addTab = () => {
    window.store.addTab()
  }

  openAbout = () => {
    window.store.openAbout()
  }

  openSetting = () => {
    window.store.openSetting()
  }

  reload = () => {
    window.location.reload()
  }

  restart = () => {
    window.store.restart()
  }

  renderContext = () => {
    const items = []
    items.push(
      // {
      //   type: 'hr'
      // },
      {
        func: 'openAbout',
        icon: 'InfoCircleOutlined',
        text: e('about')
      },
      {
        func: 'openSetting',
        icon: 'SettingOutlined',
        text: e('settings')
      },
      {
        module: 'Zoom'
      },
      {
        func: 'reload',
        icon: 'ReloadOutlined',
        text: e('reload')
      },
      // {
      //   type: 'hr'
      // },
      {
        func: 'restart',
        icon: 'RedoOutlined',
        text: e('restart')
      }
    )
    return items
  }

  renderMenu () {
    const { store } = window
    const rprops = {
      items: this.renderContext(),
      tabs: store.getTabs(),
      config: store.config,
      history: store.history
    }
    return (
      <MenuRender {...rprops} />
    )
  }

  render () {
    const pops = {
      className: 'menu-control',
      onMouseDown: evt => evt.preventDefault(),
      onClick: this.openMenu,
      title: e('menu')
    }
    const popProps = {
      content: this.renderMenu(),
      // open: this.state.opened,
      placement: 'right',
      trigger: ['click']
    }
    return (
      <Popover {...popProps}>
        <div
          {...pops}
        >
          <span
            className='menu-logo'
            dangerouslySetInnerHTML={{ __html: logoSvg }}
          />
        </div>
      </Popover>
    )
  }
}

export default shortcutDescExtend(MenuBtn)

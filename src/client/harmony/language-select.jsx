import { useMemo } from 'react'
import { GlobalOutlined } from '@ant-design/icons'
import './language-select.styl'

// window.localStorage key that records the one-time language pick.
// When absent, we prompt the user to choose a language once.
const STORAGE_KEY = 'locale'

function getLangs () {
  // window.et.langs is the canonical list, but it is only populated
  // after the store finishes initApp(). At first mount window.langMap
  // (from getInitLocale) is already available, so derive from it as a
  // fallback — both expose { id, name }.
  if (Array.isArray(window.et?.langs) && window.et.langs.length) {
    return window.et.langs
  }
  return Object.values(window.langMap || {})
}

export default function LanguageSelect ({ children }) {
  const langs = useMemo(getLangs, [])
  // locale is set once after the first pick. Also skip the prompt when
  // no language data is available yet, so the user is never trapped
  // behind an empty picker.
  const selected = !!window.localStorage.getItem(STORAGE_KEY) || !langs.length

  const choose = async langId => {
    // 1. mark the choice so we never prompt again
    window.localStorage.setItem(STORAGE_KEY, langId)
    // 2. persist into user config so the app actually boots in this
    //    language (saveUserConfig merges, so other settings are kept)
    try {
      await window.pre.runGlobalAsync('saveUserConfig', { language: langId })
    } catch (err) {
      console.error('[language-select] saveUserConfig failed', err)
    }
    // 3. reboot — language/translate are resolved at load time
    window.location.reload()
  }

  if (selected) {
    return children
  }

  return (
    <div className='language-select-wrap'>
      <div className='language-select-card'>
        <GlobalOutlined className='language-select-icon' />
        <div className='language-select-title'>
          Select language / 选择语言
        </div>
        <div className='language-select-list'>
          {
            langs.map(l => (
              <button
                key={l.id}
                type='button'
                className='language-select-item'
                onClick={() => choose(l.id)}
              >
                {l.name}
              </button>
            ))
          }
        </div>
      </div>
    </div>
  )
}

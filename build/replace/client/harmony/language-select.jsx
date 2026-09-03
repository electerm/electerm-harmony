import { useEffect, useState } from 'react'
import { GlobalOutlined } from '@ant-design/icons'
import './language-select.styl'

const STORAGE_KEY = 'locale'

export default function LanguageSelect ({ children }) {
  const [langs, setLangs] = useState(() => window.et?.langs || [])
  const [loaded, setLoaded] = useState(() => !!window.et?.langs?.length)
  const selected = !!window.localStorage.getItem(STORAGE_KEY)

  useEffect(() => {
    if (selected || langs.length) return
    window.pre.runGlobalAsync('init')
      .then(({ langMap, langs }) => {
        window.langMap = langMap
        window.et.langs = langs
        setLangs(langs || [])
      })
      .catch(err => console.error('[language-select] load languages failed', err))
      .finally(() => setLoaded(true))
  }, [langs.length, selected])

  const choose = async langId => {
    window.localStorage.setItem(STORAGE_KEY, langId)
    try {
      await window.pre.runGlobalAsync('saveUserConfig', { language: langId })
    } catch (err) {
      console.error('[language-select] saveUserConfig failed', err)
    }
    window.location.reload()
  }

  if (selected || (loaded && !langs.length)) return children

  return (
    <div className='language-select-wrap'>
      <div className='language-select-card'>
        <GlobalOutlined className='language-select-icon' />
        <div className='language-select-title'>Select language / 选择语言</div>
        <div className='language-select-list'>
          {langs.map(lang => (
            <button
              key={lang.id}
              type='button'
              className='language-select-item'
              onClick={() => choose(lang.id)}
            >
              {lang.name}
            </button>
          ))}
        </div>
      </div>
    </div>
  )
}

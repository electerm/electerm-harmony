import { useEffect, useState } from 'react'
import { GlobalOutlined } from '@ant-design/icons'
import './language-select.styl'

const STORAGE_KEY = 'locale'

// The locale package's display order: English and Simplified Chinese first,
// then the rest by number of speakers. The server sends an alphabetically
// sorted namespace object, so reorder here.
const LANG_ORDER = [
  'en_us',
  'zh_cn',
  'zh_tw',
  'es_es',
  'fr_fr',
  'ar_ar',
  'pt_br',
  'ru_ru',
  'id_id',
  'de_de',
  'ja_jp',
  'tr_tr',
  'ko_kr',
  'pl_pl',
  'hu_hu'
]

const langRank = new Map(LANG_ORDER.map((id, i) => [id, i]))

function orderLangs (langs) {
  return langs
    .filter(lang => lang.id !== 'default')
    .sort((a, b) => {
      const ai = langRank.get(a.id) ?? LANG_ORDER.length
      const bi = langRank.get(b.id) ?? LANG_ORDER.length
      return ai - bi || (a.name || a.id).localeCompare(b.name || b.id)
    })
}

export default function LanguageSelect ({ children }) {
  const [langs, setLangs] = useState(() => orderLangs(window.et?.langs || []))
  const [loaded, setLoaded] = useState(() => !!window.et?.langs?.length)
  const selected = !!window.localStorage.getItem(STORAGE_KEY)

  useEffect(() => {
    if (selected || langs.length) return
    window.pre.runGlobalAsync('init')
      .then(({ langMap, langs }) => {
        const ordered = orderLangs(langs || [])
        window.langMap = langMap
        window.et.langs = ordered
        setLangs(ordered)
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

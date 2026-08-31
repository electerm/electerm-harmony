import { createRoot } from 'react-dom/client'
import '../../../node_modules/antd/dist/reset.css'
import '@fontsource/maple-mono/index.css'
import LanguageSelect from '../harmony/language-select.jsx'
import Main from '../web-components/web-main'

const rootElement = document.getElementById('container')
const root = createRoot(rootElement)

root.render(
  <LanguageSelect>
    <Main />
  </LanguageSelect>
)

import { createRoot } from 'react-dom/client'
import 'antd/dist/reset.css'
import '@fontsource/maple-mono/index.css'
import Main from '../harmony/main.jsx'

const rootElement = createRoot(document.getElementById('container'))
rootElement.render(
  <Main />
)

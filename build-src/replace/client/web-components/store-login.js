import Fetch from '../electerm-react/common/fetch.jsx'
import { initWsCommon } from '../electerm-react/common/fetch-from-server.js'

// HarmonyOS delta: in production the homepage is a build-time static file
// (build-src/bin/gen-index-html.js) and therefore cannot carry absolute paths —
// the build machine does not know the device's HOME or log dirs. Those values
// reach the client through /api/get-constants instead, which this hook already
// merges into window.pre.
//
// Consumers, however, read them off window.et (file-select-dialog's start dir,
// default-log-path for the terminal log dir). Mirroring the runtime-only keys
// onto window.et keeps every one of them working without patching each caller —
// and keeps window.et.* meaning the same thing it did when the page was
// rendered per request.
const RUNTIME_KEYS = [
  'home',
  'sessionLogPath',
  'widgetLogPath'
]

function mirrorRuntimePaths (res) {
  for (const key of RUNTIME_KEYS) {
    if (res[key] !== undefined) {
      window.et[key] = res[key]
    }
  }
}

export default Store => {
  Store.prototype.getConstants = async function () {
    const { store } = window
    store.fetchingUser = true
    const res = await Fetch.get('/api/get-constants', null, {
      handleErr: console.log
    })
    if (res) {
      Object.assign(window.pre, res)
      mirrorRuntimePaths(res)
      window.reqs.fs.constants = window.pre.fsConstants
      store.updateConfig(res.config)
      await initWsCommon()
      Object.assign(store, {
        logined: true,
        authChecked: true,
        fetchingUser: false,
        logining: false
      })
      return true
    } else {
      console.log('getConstants err')
      store.authChecked = true
      Object.assign(store, {
        authChecked: true,
        logined: false,
        fetchingUser: false
      })
      return false
    }
  }
  Store.prototype.login = async function (password) {
    const { store } = window
    store.logining = true
    const res = await Fetch.post('/api/login', {
      password
    })
    if (res) {
      store.updateConfig({
        tokenElecterm: res
      })
      window.localStorage.setItem('tokenElecterm', res)
      store.getConstants()
    }
    Object.assign(store, {
      logining: false
    })
  }
}

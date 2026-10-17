/**
 * Window chrome (status bar + navigation bar) colour sync — HarmonyOS build.
 *
 * Problem: the ArkUI host paints the status-bar strip (top) and the gesture-bar
 * strip (bottom) with the *window* background colour, which is outside the web
 * page. Left unset it follows the *system* light/dark mode, not the app theme —
 * so a dark electerm theme on a light-mode phone gets two blank white bars.
 *
 * The only source of truth for what those strips should look like is the UI
 * theme itself. electerm themes are applied as
 *   :root { --main-dark: …; --text: …; }
 * by electerm-react/components/main/ui-theme.jsx (it rewrites the
 * <style id="theme-css"> element), so the page can read the *live* values back
 * out of the computed style and hand them to the native side.
 *
 * Bridge (entry/src/main/ets/pages/Index.ets, NativeBridge.setWindowChrome):
 *   window.harmonyNative.setWindowChrome(backgroundArgb, foregroundArgb)
 * Both are '#AARRGGBB'. Called once on startup and again whenever the theme
 * changes, so picking a different theme in settings re-paints the bars
 * immediately — no restart, no hardcoded colour.
 *
 * On a plain browser (dev server, desktop) `window.harmonyNative` is absent and
 * this module does nothing.
 */

// The two theme values that describe "what the chrome should look like".
// --main-dark is the app's *chrome* background (header / sidebar / tab bar) —
// the surface the status-bar strip sits directly on top of, so using it keeps
// the strip seamless instead of a shade lighter than the UI below it.
// --text is the main foreground, used for the clock / battery / gesture pill.
const BACKGROUND_VAR = '--main-dark'
const FOREGROUND_VAR = '--text'

// electerm-react writes the live theme into this <style> element.
const THEME_STYLE_ID = 'theme-css'

// How long to keep waiting for #theme-css to appear (ms). It is server-rendered
// empty in views/index.pug and filled by React after mount, so it exists early —
// but the element is replaced on some reload paths, hence the bounded wait.
const STYLE_WAIT_TIMEOUT = 5000
const STYLE_WAIT_INTERVAL = 50

function getNative () {
  try {
    const native = window.harmonyNative
    return native && typeof native.setWindowChrome === 'function'
      ? native
      : null
  } catch (e) {
    return null
  }
}

// ---------------------------------------------------------------------------
// colour normalisation
// ---------------------------------------------------------------------------

function clampByte (n) {
  if (!isFinite(n)) return 0
  return Math.max(0, Math.min(255, Math.round(n)))
}

function hexByte (n) {
  return clampByte(n).toString(16).padStart(2, '0')
}

/**
 * '#rgb' / '#rgba' / '#rrggbb' / '#rrggbbaa' -> '#aarrggbb'.
 * CSS orders the channels RGB then A; the HarmonyOS window APIs want ARGB, so
 * an 8-digit CSS colour has to be rotated, not just copied.
 */
function fromHex (value) {
  const m = /^#([0-9a-f]{3,8})$/i.exec(value)
  if (!m) return ''
  let h = m[1]
  if (h.length === 3 || h.length === 4) {
    h = h.split('').map(c => c + c).join('')
  }
  if (h.length === 6) return '#ff' + h.toLowerCase()
  if (h.length === 8) return ('#' + h.slice(6) + h.slice(0, 6)).toLowerCase()
  return ''
}

/**
 * One rgb() channel -> 0..255 byte. Both the legacy comma form and the
 * CSS Color 4 space form allow percentages, so `rgb(10% 20% 30%)` must work
 * the same as `rgb(26, 51, 77)`.
 */
function channelByte (token) {
  const text = String(token).trim()
  const isPercent = text.endsWith('%')
  const n = parseFloat(text)
  if (isNaN(n)) return NaN
  return clampByte(isPercent ? n * 255 / 100 : n)
}

/** Alpha channel -> 0..255 byte. Omitted means fully opaque. */
function alphaByte (token) {
  if (token === undefined) return 255
  const text = String(token).trim()
  if (!text) return 255
  const isPercent = text.endsWith('%')
  const n = parseFloat(text)
  if (isNaN(n)) return 255
  if (isPercent) return clampByte(n * 255 / 100)
  // rgba() alpha is 0..1; anything above that is already a 0..255 byte.
  return clampByte(n <= 1 ? n * 255 : n)
}

/** 'rgb(r,g,b)' / 'rgba(r,g,b,a)' / 'rgb(r g b / a)' -> '#aarrggbb'. */
function fromRgb (value) {
  const m = /^rgba?\(([^)]*)\)$/i.exec(value)
  if (!m) return ''
  const parts = m[1].split(/[,/\s]+/).filter(Boolean)
  if (parts.length < 3) return ''
  const channels = parts.slice(0, 3).map(channelByte)
  if (channels.some(n => isNaN(n))) return ''
  return '#' + hexByte(alphaByte(parts[3])) + channels.map(hexByte).join('')
}

/**
 * Resolve anything the two parsers above do not understand (named colours,
 * hsl(), …) by letting the engine compute it: a throwaway element's `color`
 * always comes back as rgb()/rgba().
 */
function resolveViaEngine (value) {
  try {
    const probe = document.createElement('span')
    probe.style.display = 'none'
    probe.style.color = value
    // Assigning an invalid value leaves the property empty.
    if (!probe.style.color) return ''
    const host = document.body || document.documentElement
    host.appendChild(probe)
    const computed = getComputedStyle(probe).color
    host.removeChild(probe)
    return computed || ''
  } catch (e) {
    return ''
  }
}

/** Normalise any CSS colour to '#AARRGGBB', or '' when it cannot be resolved. */
export function toArgb (value) {
  if (value === undefined || value === null) return ''
  const raw = String(value).trim()
  if (!raw) return ''
  const direct = fromHex(raw) || fromRgb(raw)
  if (direct) return direct
  const resolved = resolveViaEngine(raw)
  return resolved ? (fromHex(resolved) || fromRgb(resolved)) : ''
}

// ---------------------------------------------------------------------------
// theme -> bridge
// ---------------------------------------------------------------------------

function currentChromeColors () {
  let style
  try {
    style = getComputedStyle(document.documentElement)
  } catch (e) {
    return null
  }
  const background = toArgb(style.getPropertyValue(BACKGROUND_VAR))
  const foreground = toArgb(style.getPropertyValue(FOREGROUND_VAR))
  if (!background || !foreground) return null
  return { background, foreground }
}

// Last pair handed to the native side, so the observers (which fire for
// unrelated DOM churn too) cannot spam the window with identical calls.
let lastSent = ''
let pending = false

function apply () {
  pending = false
  const native = getNative()
  if (!native) return
  const colors = currentChromeColors()
  if (!colors) return
  const key = colors.background + '|' + colors.foreground
  if (key === lastSent) return
  lastSent = key
  try {
    native.setWindowChrome(colors.background, colors.foreground)
  } catch (e) {
    // Let the next change retry rather than wedging on a stale key.
    lastSent = ''
    console.warn('[electerm-harmony] setWindowChrome failed', e)
  }
}

function scheduleApply () {
  if (pending) return
  pending = true
  setTimeout(apply, 0)
}

/**
 * Watch for theme changes. electerm-react sets `style.innerHTML` on the
 * #theme-css element, which is a childList mutation; `:root` inline styles are
 * watched too because some theme paths set variables there directly.
 */
function installObservers (styleElement) {
  const observer = new MutationObserver(scheduleApply)
  observer.observe(styleElement, {
    childList: true,
    characterData: true,
    subtree: true
  })
  try {
    const rootObserver = new MutationObserver(scheduleApply)
    rootObserver.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ['style', 'class']
    })
  } catch (e) {
    // documentElement not available yet — the #theme-css observer still works
  }
}

/**
 * Wire the sync up. Safe to call on any host: without the native bridge this
 * returns immediately and never touches the DOM.
 */
export function installWindowChromeSync () {
  if (!getNative()) return

  // Paint with whatever :root already holds (theme.styl ships dark defaults, so
  // this is immediately usable) — better than leaving the system colour up
  // while the bundle loads.
  apply()

  let waited = 0
  function waitForThemeStyle () {
    const styleElement = document.getElementById(THEME_STYLE_ID)
    if (styleElement) {
      installObservers(styleElement)
      apply()
      return
    }
    waited += STYLE_WAIT_INTERVAL
    if (waited >= STYLE_WAIT_TIMEOUT) {
      // #theme-css never showed up: the :root defaults are all we have.
      return
    }
    setTimeout(waitForThemeStyle, STYLE_WAIT_INTERVAL)
  }
  waitForThemeStyle()

  // Insurance for the mount window: the saved theme is applied shortly after
  // React mounts, and a re-read catches it even if the mutation is missed.
  setTimeout(apply, 400)
  setTimeout(apply, 1500)
}

/**
 * End-to-end check of the on-device local terminal, driven entirely over the
 * backend's own HTTP + WebSocket API (no UI automation, no screenshots, no
 * flaky input injection).
 *
 *   1. GET /                       -> grab the JWT the page already embeds
 *   2. ws /common/s                -> {action:'create-terminal'} -> pid
 *   3. ws /terminals/<pid>         -> run shell commands, read the output back
 *
 * Usage (with the device's backend port forwarded to the host):
 *
 *   hdc -t <dev> fport tcp:16677 tcp:5577
 *   node scripts/verify-local-terminal.mjs                       # 2in1 default
 *   node scripts/verify-local-terminal.mjs http://127.0.0.1:16677 bash
 *   PTY_CMDS='["uname -a","echo hi"]' node scripts/verify-local-terminal.mjs
 *
 * On a device where the PTY probe said no, this fails at step 2 with
 * `Local terminal is disabled (<reason>: <detail>)` — which is the correct
 * answer, not a bug. Check the probe report first:
 *
 *   hdc -t <dev> shell "hilog -x" | grep -a 'lt[0-9]'
 */
import WebSocket from 'ws'

const BASE = process.argv[2] || 'http://127.0.0.1:16677'
let TOKEN = process.argv[3] || ''
const EXEC = process.argv[4] || 'bash'

async function getToken () {
  const html = await (await fetch(BASE + '/')).text()
  const m = /tokenElecterm":"([^"]+)"/.exec(html)
  if (!m) {
    throw new Error('no tokenElecterm in the rendered page')
  }
  return m[1]
}

function rpc (url, messages, { onData, waitMs = 15000 } = {}) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url)
    const out = []
    const timer = setTimeout(() => {
      try { ws.close() } catch {}
      resolve({ out, timedOut: true })
    }, waitMs)
    ws.on('open', async () => {
      for (const m of messages) {
        const step = typeof m === 'function' ? m : null
        if (step) {
          await step(ws)
        } else {
          ws.send(JSON.stringify(m))
        }
      }
    })
    ws.on('message', (data) => {
      const s = data.toString()
      try {
        const j = JSON.parse(s)
        if (j && j.action === undefined && (j.data || j.error)) {
          out.push({ rpc: j })
          return
        }
      } catch {}
      if (onData) {
        onData(s)
      }
      out.push({ raw: s })
    })
    ws.on('error', (e) => {
      clearTimeout(timer)
      reject(e)
    })
    ws.on('close', () => {
      clearTimeout(timer)
      resolve({ out, closed: true })
    })
  })
}

const sleep = (ms) => new Promise(r => setTimeout(r, ms))

const main = async () => {
  if (!TOKEN) {
    TOKEN = await getToken()
  }
  console.log('1) token acquired:', TOKEN.slice(0, 24) + '…')

  // --- create the session -------------------------------------------------
  const pidBase = 'e2e' + Date.now()
  const created = []
  const commonPromise = rpc(
    `${BASE.replace('http', 'ws')}/common/s?token=${encodeURIComponent(TOKEN)}`,
    [
      {
        action: 'create-terminal',
        id: 1,
        body: {
          termType: 'local',
          term: 'xterm-256color',
          cols: 100,
          rows: 30,
          execLinux: EXEC,
          execLinuxArgs: [],
          pid: pidBase
        }
      }
    ],
    { waitMs: 20000 }
  ).then(r => {
    created.push(...r.out)
    return r
  })

  const cr = await commonPromise
  const answer = cr.out.map(x => x.rpc).find(Boolean)
  if (!answer) {
    console.log('2) create-terminal got no answer; raw:', JSON.stringify(cr.out).slice(0, 800))
    process.exit(2)
  }
  if (answer.error) {
    console.log('2) create-terminal FAILED:', JSON.stringify(answer.error, null, 2))
    process.exit(3)
  }
  const pid = answer.data.pid
  console.log('2) session created, pid =', pid)

  // --- attach and drive ---------------------------------------------------
  const steps = process.env.PTY_CMDS
    ? JSON.parse(process.env.PTY_CMDS)
    : [
        'echo MARK-START',
        'pwd',
        'echo ~',
        'ls ~',
        'echo $PATH',
        '/system/bin/toybox uname -a',
        'touch ~/ok.tt && ls ~ && rm ~/ok.tt',
        'echo MARK-END'
      ]

  let transcript = ''
  const ws = new WebSocket(
    `${BASE.replace('http', 'ws')}/terminals/${pid}?token=${encodeURIComponent(TOKEN)}`
  )
  await new Promise((res, rej) => {
    ws.on('open', res)
    ws.on('error', rej)
  })
  ws.on('message', (d) => {
    transcript += d.toString()
  })
  await sleep(1500)
  for (const cmd of steps) {
    ws.send(cmd + '\r')
    await sleep(1200)
  }
  await sleep(2500)
  ws.close()

  console.log('3) transcript ▼')
  console.log(
    transcript
      .replace(/\u001b\[[0-9;?]*[a-zA-Z]/g, '')
      .replace(/\r/g, '')
      .trim()
  )
}

main().catch(e => {
  console.error('ERROR', e)
  process.exit(1)
})

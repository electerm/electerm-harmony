/**
 * BackendLauncher — resolves every path the Node.js backend needs and
 * launches it IN-PROCESS (dlopen libnode.so → node::Start on a background
 * thread, via libnode_ctl.so startBackend).
 *
 * Why a separate file: EntryAbility.onCreate() must fire startBackend() as
 * the very first thing the app does — BEFORE loadContent, BEFORE the ArkWeb
 * engine spins up — so the ~850ms of node bootstrap overlaps UI init instead
 * of serialising behind it. Index (a struct) cannot be touched from onCreate,
 * so the fs-probing helpers that used to be private Index methods live here
 * as plain functions.
 *
 * Idempotent: BackendManager.launchAttempted guards a double launch
 * (startBackend itself also refuses to run twice per process).
 *
 * All logging goes through hilog — `hdc shell hilog -T electerm.boot`.
 */

import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { startBackend } from 'libnode_ctl.so';
import { BackendManager } from './BackendManager';

const TAG: string = 'electerm.boot';
const DOMAIN: number = 0xE1EC;
const BACKEND_PORT: number = 5577;

/**
 * The data dir must live under el2 — the app-owned area that an in-place
 * upgrade keeps (same bundleName + same signing cert ⇒ same UID ⇒ the
 * previous build's el2 tree is still there). See Index.ets history for the
 * full el1-vs-el2 rationale.
 */
const EL2_APP_FILES: string = '/data/storage/el2/base/files';
const DATA_SUBDIR: string = 'electerm-data';
const DATA_PATH_MARKER: string = '.electerm-data-path';

function fileExists(path: string): boolean {
  try {
    const stat = fs.statSync(path);
    return stat.isFile();
  } catch {
    return false;
  }
}

function dirExists(path: string): boolean {
  try {
    const stat = fs.statSync(path);
    return stat.isDirectory();
  } catch {
    return false;
  }
}

/** True when `dir` already holds an electerm nedb tree (users/…). */
function hasElectermData(dir: string): boolean {
  return dirExists(`${dir}/users`);
}

/** Contents of a marker left by an older build; '' when absent or not el2. */
function readMarker(path: string): string {
  try {
    const text: string = fs.readTextSync(path).trim();
    return text.startsWith('/data/storage/el2/') ? text : '';
  } catch {
    return '';
  }
}

/** Fail fast on a dir that exists but is not writable (locked el2, etc.). */
function writeProbe(dir: string): void {
  const probe: string = `${dir}/.write-test`;
  fs.closeSync(fs.openSync(probe, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE));
  fs.unlinkSync(probe);
}

/** el2 candidates, most preferred first. Never anything under el1/bundle. */
function dataDirCandidates(context: common.Context): string[] {
  return [
    `${EL2_APP_FILES}/${DATA_SUBDIR}`,
    EL2_APP_FILES,
    `${context.filesDir}/${DATA_SUBDIR}`,
    context.filesDir
  ];
}

/**
 * Resolve the writable data dir, el2 only. A dir that already holds `users/`
 * beats everything else (in-place upgrade keeps its bookmarks); the marker is
 * only a hint for layouts we no longer recognise.
 */
function pickDataDir(context: common.Context): string {
  const candidates: string[] = dataDirCandidates(context);

  for (let i = 0; i < candidates.length; i++) {
    if (hasElectermData(candidates[i])) {
      hilog.info(DOMAIN, TAG, 'reusing previous data dir: %{public}s', candidates[i]);
      return candidates[i];
    }
  }
  for (let i = 0; i < candidates.length; i++) {
    const marker: string = readMarker(`${candidates[i]}/${DATA_PATH_MARKER}`);
    if (marker !== '') {
      hilog.info(DOMAIN, TAG, 'using marker data dir: %{public}s', marker);
      return marker;
    }
  }
  for (let i = 0; i < candidates.length; i++) {
    try {
      if (!dirExists(candidates[i])) {
        fs.mkdirSync(candidates[i], true);
      }
      writeProbe(candidates[i]);
      hilog.info(DOMAIN, TAG, 'using fresh data dir: %{public}s', candidates[i]);
      return candidates[i];
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'data dir unusable: %{public}s (%{public}s)',
        candidates[i], JSON.stringify(e));
    }
  }
  return context.tempDir;
}

/** Record the dir we settled on so the next version resolves it directly. */
function pinDataDir(dir: string): void {
  try {
    if (!dirExists(EL2_APP_FILES)) {
      fs.mkdirSync(EL2_APP_FILES, true);
    }
    const markerPath: string = `${EL2_APP_FILES}/${DATA_PATH_MARKER}`;
    const file = fs.openSync(markerPath,
      fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, dir);
    fs.closeSync(file);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not pin data dir: %{public}s', JSON.stringify(e));
  }
}

/**
 * Resolve the backend entry script inside the installed HAP.
 * bundleCodeDir may or may not already include the module segment, so try
 * both shapes and verify.
 */
function resolveScriptPath(bundleCodeDir: string): string {
  const candidates: string[] = [
    `${bundleCodeDir}/entry/resources/resfile/electerm/index.js`,
    `${bundleCodeDir}/resources/resfile/electerm/index.js`
  ];
  for (let i = 0; i < candidates.length; i++) {
    if (fileExists(candidates[i])) {
      hilog.info(DOMAIN, TAG, 'using script: %{public}s', candidates[i]);
      return candidates[i];
    }
    hilog.warn(DOMAIN, TAG, 'script candidate missing: %{public}s', candidates[i]);
  }
  return candidates[0]; // let the launcher report the failure
}

/**
 * Resolve libnode.so in the app's native libs dir. Covers every ABI the HAP
 * is built for: arm64-v8a (phones/tablets/2in1) and x86_64 (the emulator).
 * Empty string when not found.
 */
function resolveNodePath(bundleCodeDir: string): string {
  const libsDirs: string[] = [
    `${bundleCodeDir}/entry/libs/arm64-v8a`,
    `${bundleCodeDir}/entry/libs/x86_64`,
    `${bundleCodeDir}/libs/arm64-v8a`,
    `${bundleCodeDir}/libs/x86_64`
  ];
  for (let i = 0; i < libsDirs.length; i++) {
    const libsDir: string = libsDirs[i];
    try {
      const names: string[] = fs.listFileSync(libsDir);
      hilog.info(DOMAIN, TAG, 'libs dir %{public}s → %{public}s', libsDir, names.join(', '));
      const nodePath: string = `${libsDir}/libnode.so`;
      if (fileExists(nodePath)) {
        hilog.info(DOMAIN, TAG, 'using node: %{public}s', nodePath);
        return nodePath;
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'libs dir not listable: %{public}s (%{public}s)',
        libsDir, JSON.stringify(e));
    }
  }
  return '';
}

/**
 * Build the "key=value\n" entryParams string node_launcher.c / node_ctl.c
 * parse: dataDir, script, port, node. Returns '' on failure (caller falls
 * back to the child-process path which will surface the error itself).
 */
export function buildEntryParams(context: common.Context): string {
  const dataDir: string = pickDataDir(context);
  if (dataDir === '') {
    return '';
  }
  if (!dirExists(dataDir)) {
    fs.mkdirSync(dataDir, true);
  }
  pinDataDir(dataDir);
  BackendManager.dataDir = dataDir;

  const scriptPath: string = resolveScriptPath(context.bundleCodeDir);
  const nodePath: string = resolveNodePath(context.bundleCodeDir);

  const paramLines: string[] = [
    `dataDir=${dataDir}`,
    `script=${scriptPath}`,
    `port=${BACKEND_PORT}`
  ];
  if (nodePath !== '') {
    paramLines.push(`node=${nodePath}`);
  }
  const entryParams: string = paramLines.join('\n');
  BackendManager.entryParams = entryParams;
  return entryParams;
}

/**
 * Fire the in-process backend launch — designed to run from
 * EntryAbility.onCreate(), BEFORE loadContent, so node bootstraps in
 * parallel with the ArkWeb engine instead of after it.
 *
 * startBackend() itself returns immediately (the dlopen runs on a native
 * background thread); the only synchronous work here is the fs probing
 * above. Any throw is caught and logged — onCreate must never crash the
 * app; Index's fallback path covers a failed early launch.
 *
 * Returns true when startBackend accepted the launch (in-process path live).
 */
export function launchInProcessEarly(context: common.Context): boolean {
  if (BackendManager.launchAttempted) {
    return BackendManager.inProcess;
  }
  BackendManager.launchAttempted = true;
  try {
    const entryParams: string = buildEntryParams(context);
    if (entryParams === '') {
      hilog.error(DOMAIN, TAG, 'early launch skipped: could not build entry params');
      return false;
    }
    const rc: string = startBackend(entryParams);
    hilog.info(DOMAIN, TAG, 'early in-process startBackend → %{public}s', rc);
    if (rc.startsWith('err:')) {
      return false;
    }
    BackendManager.setInProcess();
    return true;
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'early startBackend threw: %{public}s', JSON.stringify(e));
    return false;
  }
}

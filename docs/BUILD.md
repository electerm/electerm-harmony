# Build Guide — electerm-harmony

Complete instructions for building the electerm HarmonyOS app locally and on GitHub Actions.

---

## 1. Prerequisites

### 1.1 Local Development

| Tool | Version | Notes |
|------|---------|-------|
| Node.js | >= 24.0.0 | For building electerm-web; recommend [fnm](https://github.com/Schniz/fnm) |
| JDK | 21 | Required by `hap-sign-tool.jar` for signing (see [ENV_SETUP.md §2.7](./ENV_SETUP.md#27-keystore-jdk-compatibility-if-keystore-was-created-with-jdk-22) for keystore compatibility) |
| HarmonyOS Command Line Tools | 5.0.5.200+ | Provides `ohpm`, `hvigorw`, SDK, and `hap-sign-tool.jar` |
| git | latest | |
| Python 3 + make + C++ build tools | | For native node modules in electerm-web |

### 1.2 CI (GitHub Actions)

- Runner: `ubuntu-latest` (Linux x64 — HarmonyOS Command Line Tools are x64-only)
- JDK 21 (Temurin) — installed via `actions/setup-java@v4`
- Node.js 24 — installed via `actions/setup-node@v4`
- No local HarmonyOS SDK needed — the workflow downloads Command Line Tools automatically

---

## 2. Local Build (Step by Step)

### Step 1 — Clone this repo

```bash
git clone https://github.com/electerm/electerm-harmony.git
cd electerm-harmony
```

### Step 2 — Prepare signing materials

Follow [`ENV_SETUP.md`](./ENV_SETUP.md) to obtain the three signing files from the Huawei Developer Console. Place them in:

```
signing/
├── electerm.p12              # Keystore (keep secret)
├── electerm_publish.cer      # Certificate from Huawei
└── electermRelease.p7b       # Release provisioning profile
```

### Step 3 — Download ohos-node prebuilt binary

```bash
./scripts/prepare-node.sh
```

This downloads the Node.js binary for OpenHarmony ARM64 and extracts it to `entry/src/main/resources/rawfile/node/`.

### Step 4 — Clone and build electerm-web

```bash
./scripts/prepare-web.sh
```

This clones `electerm/electerm-web`, installs dependencies, builds the production bundle, and copies it into `entry/src/main/resources/rawfile/electerm-web/`.

> Requires `OHOS_SERVER_SECRET` environment variable (generate with `openssl rand -base64 32`).

### Step 5 — Build and sign the HarmonyOS app

```bash
# Set environment variables for signing
export KEYSTORE_PASSWORD="<your_keystore_password>"
export KEY_PASSWORD="<your_key_password>"
export KEY_ALIAS="electerm_key"

# Optional: set if Command Line Tools are not in PATH
# export COMMANDLINE_TOOLS=/path/to/commandline-tools
# export OHOS_SDK_HOME=$COMMANDLINE_TOOLS/sdk

# Build (release mode by default)
./scripts/build-app.sh --release

# Or debug mode:
./scripts/build-app.sh --debug
```

The script performs two phases:

1. **Build unsigned HAP** — generates `build-profile.json5` (with empty `signingConfigs`), runs `ohpm install`, then `hvigorw assembleHap` with `-p enableSignTask=false`.

2. **Sign the HAP** — invokes `hap-sign-tool.jar` directly with plaintext passwords to produce the signed `.hap` file.

The signed HAP is at:
```
entry/build/default/outputs/default/entry-default-unsigned.hap
```

> The output filename contains "unsigned" in its name, but the file is signed — the signed version replaces the unsigned one in place.

### Step 6 — Install on device

```bash
# Connect your HarmonyOS device via USB
hdc list

# Install the HAP
hdc install entry/build/default/outputs/default/entry-default-unsigned.hap
```

---

## 3. CI Build (GitHub Actions)

The workflow is defined in [`.github/workflows/build.yml`](../.github/workflows/build.yml).

### 3.1 Triggering a build

The workflow runs on:

- **Push** to `dev` branch
- **Manual dispatch** via the Actions tab ("Run workflow" button) — allows choosing `release` or `debug` mode

### 3.2 What the workflow does

```
 1. Checkout electerm-harmony repo
 2. Setup Node.js 24 (for building electerm-web)
 3. Setup JDK 21 (for hap-sign-tool.jar signing)
 4. Install system dependencies (build-essential, unzip, jq, python3, etc.)
 5. Download ohos-node v24.2.0 prebuilt binary → rawfile/node/
 6. Clone & build electerm-web → rawfile/electerm-web/
 7. Download & extract HarmonyOS Command Line Tools (Linux, ~2 GB)
 8. Configure ohpm registry
 9. Decode signing materials from GitHub Secrets → signing/
10. Configure bundle name from secret (injected into app.json5)
11. Build unsigned HAP (hvigorw assembleHap with enableSignTask=false)
12. Sign HAP with hap-sign-tool.jar (plaintext passwords from secrets)
13. Upload .hap as GitHub Actions artifact (retained 30 days)
14. Write build summary
```

### 3.3 Build outputs

| Trigger | Output location |
|---------|----------------|
| Push to `dev` | GitHub Actions artifact (downloadable from the run page, retained 30 days) |
| Manual dispatch | GitHub Actions artifact |

### 3.4 Manual dispatch

To trigger a build manually:

```bash
# Release build (default)
gh workflow run build.yml --ref dev

# Debug build
gh workflow run build.yml --ref dev -f build_mode=debug
```

Or use the GitHub Actions UI: **Actions** tab → **Build HarmonyOS HAP** → **Run workflow**.

---

## 4. Helper Scripts

The following scripts automate the build steps:

| Script | Purpose |
|--------|---------|
| [`scripts/prepare-node.sh`](../scripts/prepare-node.sh) | Downloads and extracts ohos-node prebuilt binary into `rawfile/node/` |
| [`scripts/prepare-web.sh`](../scripts/prepare-web.sh) | Clones, builds, and bundles electerm-web into `rawfile/electerm-web/` |
| [`scripts/build-app.sh`](../scripts/build-app.sh) | Builds unsigned HAP with hvigorw, then signs it with `hap-sign-tool.jar` |
| [`scripts/gen-secrets.sh`](../scripts/gen-secrets.sh) | Generates GitHub Secrets values from `signing/` files and `temp/.env` |

Run them in order for a local build:

```bash
./scripts/prepare-node.sh
./scripts/prepare-web.sh
./scripts/build-app.sh
```

---

## 5. How Signing Works

This project uses a **two-phase signing approach** instead of the standard DevEco Studio workflow:

### Phase 1: Build unsigned HAP

`build-app.sh` generates a `build-profile.json5` with an **empty** `signingConfigs` array:

```json5
{
  "app": {
    "signingConfigs": [],
    "products": [
      {
        "name": "default",
        "compatibleSdkVersion": "5.0.1(13)",
        "compileSdkVersion": "5.0.1(13)",
        "runtimeOS": "HarmonyOS"
      }
    ]
  }
}
```

Then builds with `-p enableSignTask=false` to skip the hvigor plugin's built-in signer.

### Phase 2: Sign with hap-sign-tool.jar

The script locates `hap-sign-tool.jar` in the SDK and runs:

```bash
java -jar hap-sign-tool.jar sign-app \
  -mode localSign \
  -keyAlias electerm_key \
  -keyPwd <KEY_PASSWORD> \
  -appCertFile signing/electerm_publish.cer \
  -profileFile signing/electermRelease.p7b \
  -inFile entry-default-unsigned.hap \
  -signAlg SHA256withECDSA \
  -keystoreFile signing/electerm.p12 \
  -keystorePwd <KEYSTORE_PASSWORD> \
  -outFile entry-default-signed.hap
```

### Why not use hvigor's built-in signer?

The hvigor plugin's signer requires passwords to be **encrypted** using AES-128-GCM with key material from the plugin's internal `res/material/` directory (the `000000`-prefixed format that DevEco Studio produces). This is impractical for CI because:

- The encryption keys are bundled inside the hvigor plugin, not extractable in a stable way
- DevEco Studio handles this transparently, but there's no CLI tool to encrypt passwords
- GitHub Secrets can only store text, not encrypted binary blobs

Using `hap-sign-tool.jar` directly with plaintext passwords is simpler and fully supported.

---

## 6. Troubleshooting

### "hvigorw: command not found"

Ensure the HarmonyOS Command Line Tools are installed and in your `PATH`:

```bash
export COMMANDLINE_TOOLS=/path/to/commandline-tools-linux-x64
export PATH=$PATH:$COMMANDLINE_TOOLS/bin:$COMMANDLINE_TOOLS/hvigor/bin
export OHOS_SDK_HOME=$COMMANDLINE_TOOLS/sdk
```

### ohpm install fails with network error

Configure the ohpm registry mirror (for users in China):

```bash
ohpm config set registry https://ohpm.openharmony.cn/ohpm/
```

### Signing fails: "keystore password was incorrect"

This usually means a **JDK version mismatch**, not a wrong password. The `.p12` keystore was created with a newer JDK than the one running `hap-sign-tool.jar`.

**Fix**: Convert the keystore to legacy PKCS12 format (see [ENV_SETUP.md §2.7](./ENV_SETUP.md#27-keystore-jdk-compatibility-if-keystore-was-created-with-jdk-22)):

```bash
keytool -importkeystore \
  -srckeystore signing/electerm.p12 -srcstoretype PKCS12 \
  -srcstorepass <PASSWORD> \
  -destkeystore signing/electerm-compatible.p12 -deststoretype PKCS12 \
  -deststorepass <PASSWORD> \
  -J-Dkeystore.pkcs12.legacy
mv signing/electerm-compatible.p12 signing/electerm.p12
```

Then update the `OHOS_KEYSTORE_B64` GitHub Secret with the new base64 value.

### Signing fails: "COMMAND_PARAM_ERROR code 110"

This means unsupported parameters were passed to `hap-sign-tool.jar`. The following parameters are **NOT supported** by SDK 5.0.5.200:

- `-compatibleVersion` — not recognized
- `-signCode` — not recognized
- `-pwdInputMode` — not recognized

Only `-mode localSign` is required. The `build-app.sh` script already uses the correct parameter set.

### Bundle name mismatch

The app's `bundleName` in `AppScope/app.json5` must match the bundle name registered on Huawei Developer Console. In CI, this is set automatically from the `OHOS_BUNDLE_NAME` secret.

### electerm-web build fails with native module errors

Some dependencies (like `node-pty`) require native compilation. On Linux:

```bash
sudo apt install -y make g++ python3
```

### Node.js version mismatch

electerm-web requires Node.js >= 24. Use `fnm` or `nvm` to install the correct version:

```bash
fnm install 24
fnm use 24
```

---

## 7. File Size Considerations

The final `.hap` package is approximately **230 MB** because it bundles:

- ohos-node binary (~50 MB)
- electerm-web server code + node_modules (~170 MB)

If the HAP needs to be smaller:

- Strip the node binary: `strip entry/src/main/resources/rawfile/node/bin/node`
- Prune devDependencies from electerm-web: `npm prune --production`
- Use `--splitAbi` to produce per-ABI packages

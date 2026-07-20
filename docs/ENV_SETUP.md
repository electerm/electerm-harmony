# Environment Setup Guide — electerm-harmony

Everything you need to configure **before** the first build: Huawei Developer account, certificates, signing profiles, and GitHub Secrets.

---

## 1. Huawei Developer Account

### 1.1 Register

1. Go to <https://developer.huawei.com/>
2. Click **Register** (注册) and complete the account creation
3. Perform **real-name verification** (实名认证) — required for app signing
   - Individual (个人) or Enterprise (企业) — both work
   - Enterprise accounts have higher signing quotas

### 1.2 Create an App

1. Go to **AppGallery Connect** → <https://developer.huawei.com/consumer/cn/agconnect/>
2. Click **My Projects** (我的项目) → **Create Project**
3. Add an app to the project:
   - **App name**: `electerm` (or your preferred name)
   - **App type**: `Application`
   - **Platform**: `HarmonyOS`
   - **Device**: `Phone` / `Tablet` (or others as needed)
4. Note down these values:

| Value | Where to find | Used as |
|-------|--------------|---------|
| **Bundle Name** (e.g. `org.electerm.electerm`) | App info page | GitHub Secret `OHOS_BUNDLE_NAME`, injected into `app.json5` at build time |
| **App ID** (e.g. `1014303667429321472`) | App info page | GitHub Secret `OHOS_APP_ID` |

---

## 2. Generate Signing Materials

HarmonyOS app signing requires **three files**:

| File | Extension | Purpose |
|------|-----------|---------|
| Keystore | `.p12` | Your private key store (generated locally) |
| Certificate | `.cer` | Public certificate issued by Huawei (uploaded CSR → received .cer) |
| Profile | `.p7b` | Provisioning profile (binds certificate + app + device) |

The expected file names and locations:

```
signing/
├── electerm.p12              # Keystore file (keep secret)
├── electerm_publish.cer      # Certificate from Huawei
├── electermRelease.p7b       # Release provisioning profile from Huawei
└── electerm.csr              # CSR (only needed during setup)
```

### 2.1 Generate a `.p12` Keystore

> **JDK compatibility note**: The `.p12` keystore must be readable by JDK 21 (used in CI). If you generate it with JDK 22+, the PKCS12 encryption algorithms may not be backward-compatible, and CI will fail with `keystore password was incorrect`. To avoid this, either:
> - Generate the keystore with JDK 21 or earlier, **or**
> - Convert an existing keystore to legacy format (see section 2.7 below).

**Option A — Using DevEco Studio (recommended for first-time):**

1. Open DevEco Studio → `Build → Generate Key And CSR`
2. Click **New** under Key store file
3. Fill in:
   - **Key store path**: `signing/electerm.p12`
   - **Password**: your keystore password (save it!)
   - **Alias**: `electerm_key`
   - **Alias password**: your key password (can be same as keystore password)
   - **Validity**: 25 years (or more)
   - **First/Last name, Org, City, State, Country**: fill in your details
4. Click **OK**

**Option B — Using keytool (command line):**

```bash
keytool -genkeypair \
  -alias electerm_key \
  -keyalg EC \
  -keysize 256 \
  -sigalg SHA256withECDSA \
  -validity 9125 \
  -keystore signing/electerm.p12 \
  -storetype PKCS12 \
  -storepass <YOUR_KEYSTORE_PASSWORD> \
  -keypass <YOUR_KEY_PASSWORD> \
  -dname "CN=electerm, OU=dev, O=electerm, L=Shanghai, ST=Shanghai, C=CN"
```

### 2.2 Generate a CSR (Certificate Signing Request)

**Option A — DevEco Studio:**

Continue from step 2.1 — after creating the keystore, the same dialog lets you generate a CSR. Select the keystore you just created and fill in the same details. Save as `signing/electerm.csr`.

**Option B — keytool:**

```bash
keytool -certreq \
  -alias electerm_key \
  -keystore signing/electerm.p12 \
  -storetype PKCS12 \
  -storepass <YOUR_KEYSTORE_PASSWORD> \
  -file signing/electerm.csr
```

### 2.3 Submit CSR to Huawei → Get `.cer` Certificate

1. Go to **AppGallery Connect** → your app → **HarmonyOS** tab → **Certificate Management** (证书管理)
   - Direct link: <https://developer.huawei.com/consumer/cn/agconnect/caa-app/appCertificate>
2. Click **New Certificate** (新增证书)
3. Upload `electerm.csr`
4. Select certificate type: **Development certificate** (调试证书) or **Release certificate** (发布证书)
   - **Development**: for testing on your own devices
   - **Release**: for publishing to AppGallery
5. Submit and download the `.cer` file → save as `signing/electerm_publish.cer`

### 2.4 Create a Profile → Get `.p7b`

1. Go to **AppGallery Connect** → your app → **HarmonyOS** tab → **Profile Management** (Profile 管理)
   - Direct link: <https://developer.huawei.com/consumer/cn/agconnect/caa-app/appProfile>
2. Click **New Profile** (新增 Profile)
3. Select:
   - **Type**: Debug (调试) or Release (发布)
   - **Certificate**: select the certificate created in step 2.3
   - **Devices** (for debug profile): add your device UDIDs
4. Submit and download the `.p7b` file → save as `signing/electermRelease.p7b`

### 2.5 Get Your Device UDID (for debug profile)

```bash
# Connect device via USB, then:
hdc shell bm get --udid
# Or:
hdc shell param get const.product.udid
```

### 2.6 About ACL Permissions (通常不需要)

> **Short answer**: Creating a Profile does NOT require ACL. You can skip this section.

ACL (Access Control List) is a separate concept from Profile. In HarmonyOS, app permissions have three authorization levels:

| Level | ACL needed? | Example permissions |
|-------|------------|---------------------|
| `normal` | No | `ohos.permission.INTERNET`, `ohos.permission.RUNNING_LOCK` |
| `system_basic` | Yes | `ohos.permission.READ_MEDIA`, `ohos.permission.WRITE_MEDIA` |
| `system_core` | No (system apps only) | System-level APIs |

**electerm-harmony currently only uses `normal` level permissions** — no ACL application needed.

ACL is only required if you later add restricted permissions to `module.json5` → `requestPermissions` (e.g., accessing user files outside the app sandbox). To apply:

1. Go to **AppGallery Connect** → your app → **HarmonyOS** tab → **Permissions** (应用权限)
2. Select the permission you need
3. Submit for review and wait for approval

### 2.7 Keystore JDK Compatibility (if keystore was created with JDK 22+)

If you created the `.p12` keystore with JDK 22 or newer, the CI (which uses JDK 21) will fail to read it with the error `keystore password was incorrect`. Convert it to legacy PKCS12 format:

```bash
keytool -importkeystore \
  -srckeystore signing/electerm.p12 \
  -srcstoretype PKCS12 \
  -srcstorepass <YOUR_KEYSTORE_PASSWORD> \
  -destkeystore signing/electerm-compatible.p12 \
  -deststoretype PKCS12 \
  -deststorepass <YOUR_KEYSTORE_PASSWORD> \
  -J-Dkeystore.pkcs12.legacy

# Verify the converted keystore
keytool -list \
  -keystore signing/electerm-compatible.p12 \
  -storepass <YOUR_KEYSTORE_PASSWORD> \
  -storetype PKCS12

# Replace the original
mv signing/electerm-compatible.p12 signing/electerm.p12
```

The certificate fingerprint should remain identical after conversion.

---

## 3. How Signing Works in This Project

Unlike the standard DevEco Studio workflow (which configures signing inside `build-profile.json5` with encrypted passwords), this project uses a **two-phase signing approach**:

1. **Build unsigned HAP** — `hvigorw assembleHap` with `-p enableSignTask=false` and an empty `signingConfigs` array in `build-profile.json5`. This skips the hvigor plugin's built-in signer entirely.

2. **Sign with hap-sign-tool.jar** — The `build-app.sh` script invokes `hap-sign-tool.jar` (bundled in the HarmonyOS SDK) directly with plaintext passwords:

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

**Why this approach?** The hvigor plugin's built-in signer requires passwords to be encrypted using AES-128-GCM with key material from the plugin's `res/material/` directory (the `000000`-prefixed encrypted format that DevEco Studio produces). This encryption is not practical for CI. The `hap-sign-tool.jar` accepts plaintext passwords directly, which is simpler and works with GitHub Secrets.

> **Note**: `build-profile.json5` is auto-generated by `build-app.sh` at build time. You do **not** need to manually configure signing in this file.

---

## 4. GitHub Secrets for CI

Go to your GitHub repo → **Settings → Secrets and variables → Actions** → **New repository secret**.

### 4.1 Signing Materials (base64-encoded)

Since GitHub Secrets are text-only, we base64-encode the binary files:

```bash
# macOS:
base64 -i signing/electerm.p12 | tr -d '\n'           # → OHOS_KEYSTORE_B64
base64 -i signing/electerm_publish.cer | tr -d '\n'    # → OHOS_CERT_B64
base64 -i signing/electermRelease.p7b | tr -d '\n'     # → OHOS_PROFILE_B64

# Linux:
base64 -w 0 signing/electerm.p12                       # → OHOS_KEYSTORE_B64
base64 -w 0 signing/electerm_publish.cer               # → OHOS_CERT_B64
base64 -w 0 signing/electermRelease.p7b                # → OHOS_PROFILE_B64
```

Or use the helper script (reads from `temp/.env` and `signing/`):

```bash
./scripts/gen-secrets.sh
# Output written to temp/github-secrets.txt (gitignored)
```

| Secret Name | Value | Description |
|-------------|-------|-------------|
| `OHOS_KEYSTORE_B64` | base64 of `.p12` file | Your keystore (private key) |
| `OHOS_CERT_B64` | base64 of `.cer` file | Certificate from Huawei |
| `OHOS_PROFILE_B64` | base64 of `.p7b` file | Provisioning profile |
| `OHOS_KEYSTORE_PASSWORD` | plaintext password | Keystore password |
| `OHOS_KEY_PASSWORD` | plaintext password | Key alias password |
| `OHOS_KEY_ALIAS` | `electerm_key` | Key alias name |

### 4.2 App Identity

| Secret Name | Value | Description |
|-------------|-------|-------------|
| `OHOS_BUNDLE_NAME` | `org.electerm.electerm` | Must match Huawei console; injected into `app.json5` at build time |
| `OHOS_APP_ID` | `1014303667429321472` | From AppGallery Connect |

### 4.3 Build Configuration

| Secret Name | Value | Description |
|-------------|-------|-------------|
| `OHOS_CMDLINE_TOOLS_URL` | download URL | HarmonyOS Command Line Tools download link (see section 5 below) |
| `OHOS_SERVER_SECRET` | random string | Secret key for electerm-web server (generate with `openssl rand -base64 32`) |

### 4.4 Electron 鸿蒙 Runtime

The app uses the Electron 鸿蒙 runtime (from `openharmony-sig/electron`) for Node.js + WebView.
The pre-built runtime is distributed as a tarball. The URL is set as a GitHub secret to avoid
exposing the private hosting address in the workflow file.

Set this secret in GitHub repo → **Settings → Secrets and variables → Actions**.

> **Note:** Ask the project maintainer for the URL value — it is not committed to the repo.

The tarball contains:
- `web_engine/` — Complete HAR module (ArkTS API + resfile resources)
- `electron/libs/arm64-v8a/*.so` — Native libraries

| Secret Name | Required | Description |
|-------------|----------|-------------|
| `ELECTRON_RUNTIME_URL` | **Yes** | URL to download the pre-built Electron runtime tarball |

See [BUILD.md §3](./BUILD.md#3-obtaining-the-electron-鸿蒙-runtime) for details.

### 4.5 Workflow Environment Variables (not secrets)

These are defined in `.github/workflows/build.yml` under `env:` and can be changed without touching secrets:

| Variable | Default | Description |
|----------|---------|-------------|
| (none) | | Runtime version is controlled by the URL you provide |

---

## 5. Obtaining HarmonyOS Command Line Tools URL

The CI needs the **Command Line Tools for HarmonyOS (Linux)** to run `ohpm` and `hvigorw`.

### 5.1 Download URL

1. Go to <https://developer.huawei.com/consumer/cn/download/>
2. Search for **Command Line Tools for HarmonyOS**
3. Select the **Linux** version
4. Accept the license and start the download
5. Copy the download URL from your browser's download manager
6. Store it as GitHub Secret `OHOS_CMDLINE_TOOLS_URL`

> The URL looks like:
> `https://contentcenter-vali-drcn.dbankcdn.cn/.../commandline-tools-linux-x64-5.0.5.200.zip`
>
> **This URL expires** — update it periodically if CI starts failing.

### 5.2 Alternative: Mirror URL

A community mirror is available and may be more stable:

```
https://hf-mirror.com/csukuangfj/harmonyos-commandline-tools/resolve/main/commandline-tools-linux-x64-5.0.5.200.zip
```

### 5.3 Alternative: DevEco Studio CLI

If you have DevEco Studio installed locally, the command line tools are at:

- **macOS**: `/Applications/DevEco-Studio.app/Contents/tools/`
- **Windows**: `C:\Program Files\Huawei\DevEco Studio\tools\`

You can zip the `command-line-tools` folder and host it yourself for CI stability.

---

## 6. Summary Checklist

Before your first CI build, make sure you have:

- [ ] Huawei Developer account with real-name verification
- [ ] App created on AppGallery Connect with correct bundle name
- [ ] `.p12` keystore generated (JDK 21 compatible — see section 2.7)
- [ ] CSR generated and submitted to Huawei
- [ ] `.cer` certificate downloaded → `signing/electerm_publish.cer`
- [ ] `.p7b` profile downloaded → `signing/electermRelease.p7b`
- [ ] GitHub Secrets configured:
  - [ ] `OHOS_KEYSTORE_B64`
  - [ ] `OHOS_CERT_B64`
  - [ ] `OHOS_PROFILE_B64`
  - [ ] `OHOS_KEYSTORE_PASSWORD`
  - [ ] `OHOS_KEY_PASSWORD`
  - [ ] `OHOS_KEY_ALIAS`
  - [ ] `OHOS_BUNDLE_NAME`
  - [ ] `OHOS_APP_ID`
  - [ ] `OHOS_CMDLINE_TOOLS_URL`
  - [ ] `OHOS_SERVER_SECRET`
  - [ ] `ELECTRON_RUNTIME_URL` (ask maintainer for the value)
- [ ] Workflow enabled under repo → **Actions** tab

---

## 7. Security Notes

- **Never commit** `.p12`, `.cer`, `.p7b`, or passwords to the repository
- The `.gitignore` file excludes the `signing/` directory, `web_engine/`, `entry/libs/`, and `temp/` directory
- GitHub Secrets are encrypted and never exposed in logs
- If a signing material is compromised, revoke it on AppGallery Connect and generate new ones
- Use **release certificates** only for published builds; use **debug certificates** for testing

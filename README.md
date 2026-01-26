# Mythetech Shared Workflows

Reusable GitHub Actions workflows for building, signing, and publishing .NET desktop applications.

## Workflows

### `pr-test.yml`

Runs unit tests on pull requests.

```yaml
name: PR Tests
on:
  pull_request:
    branches: [ "main" ]

jobs:
  test:
    uses: mythetech/workflows/.github/workflows/pr-test.yml@main
    with:
      test_project: "MyApp.Test/MyApp.Test.csproj"
```

#### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `dotnet_version` | No | `10.0.x` | .NET SDK version |
| `test_project` | No | - | Path to test project. If omitted, runs `dotnet test` in root |
| `test_command` | No | - | Override the entire test command |

---

### `desktop-publish.yml`

Full build, sign, and publish pipeline for .NET desktop applications. Supports:
- **Windows**: Azure Trusted Signing
- **macOS**: Developer ID + Notarization
- **Linux**: Unsigned AppImage

```yaml
name: Publish Desktop
on:
  workflow_dispatch:

jobs:
  publish:
    uses: mythetech/workflows/.github/workflows/desktop-publish.yml@main
    with:
      app_name: "Horizon"
      project_path: "Horizon/Horizon.csproj"
      test_project: "Horizon.Test/Horizon.Test.csproj"
      entitlements_path: "Horizon/Horizon.entitlements"
      icon_windows: "Horizon/wwwroot/logo.ico"
      icon_linux: "Horizon/wwwroot/logo.png"
      icon_macos: "Horizon/wwwroot/logo.icns"
      storage_account: "stmythetechglobal"
      storage_container: "preview"
    secrets: inherit
```

#### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `app_name` | **Yes** | - | Application name (e.g., "Horizon") |
| `project_path` | **Yes** | - | Path to main .csproj |
| `test_project` | No | - | Path to test project |
| `entitlements_path` | **Yes** | - | Path to macOS entitlements file |
| `icon_windows` | **Yes** | - | Windows icon (.ico) |
| `icon_linux` | **Yes** | - | Linux icon (.png) |
| `icon_macos` | **Yes** | - | macOS icon (.icns) |
| `dotnet_version` | No | `10.0.x` | .NET SDK version |
| `versioning` | No | `nbgv` | `nbgv` or `run_number` |
| `storage_account` | **Yes** | - | Azure Storage account |
| `storage_container` | **Yes** | - | Container for releases |
| `releases_container` | No | `releases` | Container for Velopack auto-update |
| `enable_signing` | No | `true` | Enable code signing |
| `enable_smoke_tests` | No | `true` | Enable smoke tests |
| `enable_blob_upload` | No | `true` | Enable Azure uploads |

#### Required Secrets

Configure these at the **organization level** for sharing across repos:

**Windows Signing (Azure Trusted Signing)**
- `AZURE_TRUSTED_SIGNING_ENDPOINT`
- `AZURE_TRUSTED_SIGNING_ACCOUNT_NAME`
- `AZURE_TRUSTED_SIGNING_CERTIFICATE_PROFILE_NAME`
- `AZURE_CREDENTIALS`

**macOS Signing & Notarization**
- `BUILD_CERTIFICATE_BASE64`
- `INSTALLER_CERTIFICATE_BASE64`
- `P12_PASSWORD`
- `APPLE_USERNAME_ID`
- `APPLE_TEAM_ID`
- `KEYCHAIN_PASSWORD`
- `MACOS_SIGN_APP_IDENTITY`
- `MACOS_SIGN_INSTALL_IDENTITY`

**App-Specific (configure per repository)**
- `APPLE_APP_ID_PASSWORD` - App-specific password for notarization
- `BLOB_SAS_TOKEN` - Azure Storage SAS token (if different per app)

---

## Composite Actions

### `actions/macos-sign`

Signs and notarizes a macOS application bundle.

```yaml
- uses: mythetech/workflows/actions/macos-sign@main
  with:
    app_name: "MyApp"
    platform_release_dir: "releases/macOS"
    entitlements_path: "MyApp/MyApp.entitlements"
    sign_app_identity: ${{ secrets.MACOS_SIGN_APP_IDENTITY }}
    sign_install_identity: ${{ secrets.MACOS_SIGN_INSTALL_IDENTITY }}
    keychain_path: ${{ runner.temp }}/app-signing.keychain-db
```

### `actions/smoke-test`

Verifies that a desktop application can launch and display a window.

```yaml
- uses: mythetech/workflows/actions/smoke-test@main
  with:
    app_name: "MyApp"
    platform: "Windows"  # or "macOS" or "Linux"
    releases_dir: "releases"
```

### `actions/blob-upload`

Uploads release artifacts to Azure Blob Storage.

```yaml
- uses: mythetech/workflows/actions/blob-upload@main
  with:
    app_name: "MyApp"
    version: "1.0.0"
    platform: "Windows"
    release_dir: "releases/Windows"
    storage_account: "mystorageaccount"
    storage_container: "releases"
    sas_token: ${{ secrets.BLOB_SAS_TOKEN }}
```

---

## Migration Guide

### From existing workflow to reusable workflow

1. **Create/update `.github/workflows/pr.yml`**:
```yaml
name: PR Tests
on:
  pull_request:
    branches: [ "main" ]

jobs:
  test:
    uses: mythetech/workflows/.github/workflows/pr-test.yml@main
    with:
      test_project: "MyApp.Test/MyApp.Test.csproj"
```

2. **Create/update `.github/workflows/dotnet-desktop.yml`**:
```yaml
name: Publish Desktop
on:
  workflow_dispatch:

jobs:
  publish:
    uses: mythetech/workflows/.github/workflows/desktop-publish.yml@main
    with:
      app_name: "MyApp"
      project_path: "MyApp/MyApp.csproj"
      test_project: "MyApp.Test/MyApp.Test.csproj"
      entitlements_path: "MyApp/MyApp.entitlements"
      icon_windows: "MyApp/wwwroot/logo.ico"
      icon_linux: "MyApp/wwwroot/logo.png"
      icon_macos: "MyApp/wwwroot/logo.icns"
      storage_account: "mystorageaccount"
      storage_container: "releases"
    secrets: inherit
```

3. **Ensure secrets are configured**:
   - Org-level: All signing and common secrets
   - Repo-level: `APPLE_APP_ID_PASSWORD` (app-specific notarization password)

4. **Standardize the app-specific secret name**:
   - Rename `APPLE_MYAPP_ID_PASSWORD` to `APPLE_APP_ID_PASSWORD` in each repo

---

## Versioning

This repository uses `@main` for all consuming workflows. Changes pushed to `main` are immediately available to all projects.

For breaking changes, create a new major version branch (e.g., `v2`) and update consuming workflows to use `@v2`.

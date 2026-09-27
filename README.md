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
| `dotnet_version` | No | `10.0.x` | .NET SDK version. Ignored when `global_json_file` is set |
| `global_json_file` | No | - | Path to a `global.json` pinning the SDK. Takes precedence over `dotnet_version` |
| `test_project` | No | - | Path to test project. If omitted, runs `dotnet test` in root |
| `test_command` | No | - | Override the entire test command |
| `test_runner` | No | `auto` | `auto`, `vstest` or `mtp`. See [Test runners](#test-runners) |
| `enable_coverage` | No | `true` | Enable code coverage collection |
| `coverage_threshold` | No | `0` | Minimum coverage % (0 disables threshold check) |
| `upload_coverage_artifact` | No | `true` | Upload coverage results as artifact |

#### Test runners

Both VSTest and Microsoft.Testing.Platform (MTP) are supported. The two are mutually
exclusive on the .NET 10 SDK and later, so the workflow detects which one a repository uses
from the `test` block of its `global.json`:

```json
{
  "sdk": { "version": "11.0.100" },
  "test": { "runner": "Microsoft.Testing.Platform" }
}
```

A repository with that block runs on MTP; one without it runs on VSTest. Opting in therefore
needs no change to the calling workflow. Set `test_runner` to `vstest` or `mtp` explicitly
only to override the detection.

Coverage under MTP additionally requires the test project to reference
`Microsoft.Testing.Extensions.CodeCoverage`. Without it the workflow still runs the tests and
emits a warning rather than failing, since `coverlet.collector` is a VSTest data collector and
does nothing under MTP.

```xml
<PackageReference Include="Microsoft.Testing.Extensions.CodeCoverage" Version="18.4.1" />
```

#### Code Coverage

Coverage is enabled by default. Results appear in:
- **GitHub Job Summary** - Markdown table with coverage breakdown
- **Artifact** - Downloadable HTML report (`coverage-report`)

To enforce a minimum coverage threshold:

```yaml
uses: mythetech/workflows/.github/workflows/pr-test.yml@main
with:
  test_project: "MyApp.Test/MyApp.Test.csproj"
  coverage_threshold: 80  # Fail if coverage < 80%
```

To disable coverage:

```yaml
uses: mythetech/workflows/.github/workflows/pr-test.yml@main
with:
  test_project: "MyApp.Test/MyApp.Test.csproj"
  enable_coverage: false
```

**Prerequisite**: VSTest projects should include the Coverlet collector package. MTP projects
use `Microsoft.Testing.Extensions.CodeCoverage` instead, as described under
[Test runners](#test-runners).

```xml
<PackageReference Include="coverlet.collector" Version="6.0.4">
  <PrivateAssets>all</PrivateAssets>
  <IncludeAssets>runtime; build; native; contentfiles; analyzers</IncludeAssets>
</PackageReference>
```

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
| `enable_smoke_tests` | No | `true` | Smoke test the packaged builds before releasing; a failed smoke test stops the release |
| `smoke_timeout` | No | `60` | Smoke run budget in seconds (`HERMES_SMOKE_TEST_TIMEOUT`) |
| `require_verdict` | No | `false` | Fail apps that predate Hermes smoke mode instead of accepting a liveness check |
| `enable_blob_upload` | No | `true` | Enable Azure uploads |

Jobs run in the order `test`, `publish` (build, sign, pack), `smoke-test`, `release` (Azure Blob
upload). `release` waits for every platform's smoke test, so a build that fails smoke testing is
never uploaded. With `enable_smoke_tests: false` the release runs straight after `publish`.

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

### `desktop-smoke-test.yml`

Runs unit tests and smoke tests on demand, without signing or publishing. Builds the same
unsigned Velopack packages as `desktop-publish.yml`, then launches them on each selected
platform. Useful for checking a large change before cutting a release. No secrets are needed.

```yaml
name: Smoke Test
on:
  workflow_dispatch:
    inputs:
      platforms:
        description: 'Platforms to smoke test'
        type: choice
        options: [all, windows, macos, linux]
        default: all

jobs:
  smoke-test:
    uses: mythetech/workflows/.github/workflows/desktop-smoke-test.yml@main
    with:
      app_name: "Horizon"
      project_path: "Horizon/Horizon.csproj"
      test_project: "Horizon.Test/Horizon.Test.csproj"
      icon_windows: "Horizon/wwwroot/logo.ico"
      icon_linux: "Horizon/wwwroot/logo.png"
      icon_macos: "Horizon/wwwroot/logo.icns"
      platforms: ${{ inputs.platforms }}
```

Unit tests run through `pr-test.yml`, so VSTest/MTP detection works the same as on pull
requests. Tests and smoke tests run in parallel.

#### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `app_name` | **Yes** | - | Application name (e.g., "Horizon") |
| `project_path` | **Yes** | - | Path to main .csproj |
| `icon_windows` | **Yes** | - | Windows icon (.ico) |
| `icon_linux` | **Yes** | - | Linux icon (.png) |
| `icon_macos` | **Yes** | - | macOS icon (.icns) |
| `platforms` | No | `all` | `all`, `windows`, `macos` or `linux` |
| `dotnet_version` | No | `10.0.x` | .NET SDK version. Ignored when `global_json_file` is set |
| `global_json_file` | No | - | Path to a `global.json` pinning the SDK |
| `enable_tests` | No | `true` | Run unit tests alongside the smoke tests |
| `test_project` | No | - | Path to test project. If omitted, runs `dotnet test` in root |
| `test_command` | No | - | Override the entire test command |
| `test_runner` | No | `auto` | `auto`, `vstest` or `mtp` |
| `enable_coverage` | No | `false` | Collect code coverage for the unit tests |
| `smoke_timeout` | No | `60` | Smoke run budget in seconds (`HERMES_SMOKE_TEST_TIMEOUT`) |
| `require_verdict` | No | `false` | Fail apps that predate Hermes smoke mode instead of accepting a liveness check |

The packages are unsigned, so the macOS signing-specific bundle restructuring from
`desktop-publish.yml` is not exercised here.

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

Launches a packaged app with `HERMES_SMOKE_TEST=1` and judges the run by the verdict the app
prints (`HERMES_SMOKE_RESULT`) or writes (`HERMES_SMOKE_TEST_RESULT` JSON). Apps built on a Hermes
version without smoke mode never print `HERMES_SMOKE_START`; for those the action falls back to a
liveness check with a warning, unless `require_verdict` is `true`.

```yaml
- uses: mythetech/workflows/actions/smoke-test@main
  with:
    app_name: "MyApp"
    platform: "Windows"  # or "macOS" or "Linux"
    releases_dir: "releases"
    timeout: "60"             # optional
    require_verdict: "false"  # optional
    output_dir: "smoke-output"
```

`output_dir` receives `app-stdout.log`, `app-stderr.log`, `result.json`, `run.json`, and a
screenshot on failure. Upload it with `if: always()`.

### `actions/smoke-verdict`

The verdict step on its own, for pipelines that launch the app themselves. `output_dir` must hold
`app-stdout.log` and `run.json`, and optionally `app-stderr.log` and `result.json`. `run.json` is
required; without it the action reports a launcher failure rather than guessing at the app's own
verdict. `actions/smoke-test` writes `run.json` via `Start-SmokeRun.ps1`, in the shape
`{ "mode": "verdict" | "legacy", "exitCode": <int or null>, "timedOut": <bool>, "legacyAlive": <bool> }`.
Pipelines that do not want to write `run.json` can dot-source `actions/smoke-verdict/SmokeVerdict.ps1`
and call `Get-SmokeVerdict` directly, which is what Hermes CI does.

```yaml
- uses: mythetech/workflows/actions/smoke-verdict@main
  with:
    output_dir: "smoke-output"
    fail_on_failed: "true"
    require_verdict: "false"  # optional
    platform: "Windows"  # optional, job summary heading
```

Outputs: `result` (`passed` or `failed`) and `reason`.

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

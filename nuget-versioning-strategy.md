# NuGet Versioning & CI/CD Strategy (LayeredCraft)

## Overview

This strategy uses a **JSON-based version manifest** as the single source of truth for package versioning.

It replaces all previous `PackageVersionPrefix` / MSBuild-based approaches.

---

# Core Design

## Source of Truth

All versioning is defined in each consuming repo at:

```
eng/package-versioning.json
```

`devops-templates` ships a JSON Schema at `eng/package-versioning.schema.json` that consumers reference for IDE validation and typo prevention.

Example:

```json
{
  "$schema": "https://raw.githubusercontent.com/LayeredCraft/devops-templates/main/eng/package-versioning.schema.json",
  "packages": {
    "LayeredCraft.StructuredLogging": {
      "strategy": "single",
      "defaultVersionPrefix": "1.4.0"
    },
    "LayeredCraft.EntityFrameworkCore.DynamoDB": {
      "strategy": "by-profile",
      "profiles": {
        "net9": {
          "versionPrefix": "9.0.0",
          "dotnetSdk": "9.0.x"
        },
        "net10": {
          "versionPrefix": "10.0.0",
          "dotnetSdk": "10.0.x"
        }
      }
    }
  }
}
```

---

# Key Concepts

## Strategies

| Strategy     | Behavior |
|--------------|----------|
| `single`     | One version line for all builds |
| `by-profile` | Multiple version lines, selected via `versionProfile` input |

---

## Important Rule

> A single publish produces a single version.

Even if you:
- multi-target frameworks
- test across multiple SDKs

You still publish exactly one package version per run.

For `by-profile` packages that publish multiple version lines (e.g. net9 + net10), the consuming caller defines **one job per profile**, running in parallel.

---

# Workflow Model

## 1. PR Build

- Uses existing `pr-build.yaml` — no changes needed
- Matrix build across SDKs
- Restore / build / test only
- No versioning involved

## 2. Publish Preview (main push)

New file: `.github/workflows/publish-preview.yml`

- Triggered by consumer caller on push to `main`
- Validates `eng/package-versioning.json` exists (fail with clear error if missing)
- Fails fast if `packageId` not found in JSON
- Resolves version prefix from JSON:
  - `single` → `defaultVersionPrefix`
  - `by-profile` → `profiles[versionProfile].versionPrefix`
- If `dotnetVersion` input not provided, falls back to `dotnetSdk` from JSON profile (only applicable to `by-profile`)
- Publishes: `<prefix>-preview.<runNumber>`
- No git tag created

## 3. Publish Release (tag push)

New file: `.github/workflows/publish-release.yml`

- Triggered by consumer caller on tag push (`vX.Y.Z`)
- Validates `eng/package-versioning.json` exists
- Extracts version from tag
- **Validates exact prefix+suffix match**: tag `v1.4.0` must match `defaultVersionPrefix: 1.4.0`; tag `v0.0.2-alpha` must match `prefix: 0.0.2` + `suffix: alpha`
- Re-builds from tagged commit (clean build, no artifact promotion)
- Publishes to NuGet
- **Promotes existing Release Drafter draft** via `gh release edit --draft=false` when draft tag matches pushed tag
- Falls back to `softprops/action-gh-release` with `generate_release_notes: true` if no matching draft exists
- Marks GitHub Release as pre-release if tag contains a version suffix (e.g. `-alpha`)
- For `by-profile` packages, one shared draft covers all profiles

## 4. Release Drafter

New reusable workflow: `.github/workflows/release-drafter.yml`
Config: `.github/release-drafter.yml` (lives in devops-templates, shared by all consumers)

### Triggers
```yaml
on:
  push:
    branches:
      - main
  pull_request:
    types: [opened, edited, synchronize, reopened, ready_for_review]
  workflow_dispatch:
```

### Job condition
```yaml
if: github.event_name == 'push' || github.event.pull_request.draft == false
```
- PR events run the autolabeler only (labels applied before merge)
- Draft updates only happen on push to `main`
- `workflow_dispatch` allows manual refresh

### Permissions
`contents: write`, `pull-requests: read` — `GITHUB_TOKEN` only, no secrets required from callers

### Concurrency
```yaml
concurrency:
  group: release-drafter-${{ github.ref }}
  cancel-in-progress: true
```

### Autolabeler (inside release-drafter config)

| PR Title Prefix | Label |
|----------------|-------|
| `feat` | `type: feat` |
| `fix` | `type: fix` |
| `docs` | `type: docs` |
| `refactor` | `type: refactor` |
| `test` | `type: test` |
| `chore` | `type: chore` |
| `ci` | `type: ci` |
| `revert` | `type: revert` |
| title contains `!` | `breaking-change` |

### Release Note Categories

| Section | Labels |
|---------|--------|
| 🚀 Features | `type: feat` |
| 🐛 Bug Fixes | `type: fix` |
| 📚 Documentation | `type: docs` |
| 🔄 Refactoring | `type: refactor` |
| ✅ Tests | `type: test` |
| 🔧 Maintenance | `type: chore`, `type: ci`, `type: revert` |
| ⚠️ Breaking Changes | `breaking-change` |

### Version Resolution

| Label | Bump |
|-------|------|
| `breaking-change` | major |
| `type: feat` | minor |
| everything else | patch (default) |

### Include / Exclude
- **Include**: all `type:` labels + `breaking-change`
- **Exclude**: `skip-changelog`, `internal`

### Release Notes Template
```md
## Changes

$CHANGES
```

### Does NOT publish to NuGet

## 5. PR Title Check

New reusable workflow: `.github/workflows/pr-title-check.yml`

- Triggered on `pull_request` events
- Uses `amannn/action-semantic-pull-request@v6`
- Skips validation when `github.actor == 'dependabot[bot]'`
- Allowed types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `ci`, `revert`
- Format: `type(optional-scope): description`
  - Description must start with lowercase
  - Scope must be lowercase, alphanumeric + hyphens

### Rollout: structured-logging + dynamodb-efcore-provider (pilot repos)

---

# Reusable Workflow Inputs

```yaml
inputs:
  solution:
    type: string
    required: true
  packageId:
    type: string
    required: true
  versionProfile:
    type: string
    default: ""
  hasTests:
    type: boolean
    default: true
  dotnetVersion:
    type: string
    default: ""       # Falls back to dotnetSdk from JSON profile if by-profile and not provided
```

---

# Version Resolution (Preview)

```yaml
- name: Validate manifest exists
  run: |
    if [ ! -f "eng/package-versioning.json" ]; then
      echo "❌ eng/package-versioning.json not found. Create it in the consuming repo."
      exit 1
    fi

- name: Resolve version
  id: version
  run: |
    python3 - <<'PY' >> "$GITHUB_OUTPUT"
    import json
    from pathlib import Path

    config = json.loads(Path("eng/package-versioning.json").read_text())

    pkg = config["packages"].get("${{ inputs.packageId }}")
    if not pkg:
        raise SystemExit(f"❌ Package '${{ inputs.packageId }}' not found in eng/package-versioning.json")

    strategy = pkg["strategy"]

    if strategy == "single":
        prefix = pkg["defaultVersionPrefix"]
        sdk = None

    elif strategy == "by-profile":
        profile_key = "${{ inputs.versionProfile }}"
        if not profile_key:
            raise SystemExit("❌ versionProfile is required for by-profile packages")
        profile = pkg["profiles"].get(profile_key)
        if not profile:
            raise SystemExit(f"❌ Profile '{profile_key}' not found for package '${{ inputs.packageId }}'")
        prefix = profile["versionPrefix"]
        sdk = profile.get("dotnetSdk")

    else:
        raise SystemExit(f"❌ Unknown strategy: {strategy}")

    version = f"{prefix}-preview.${{ github.run_number }}"
    print(f"package_version={version}")
    if sdk:
        print(f"dotnet_sdk={sdk}")
    PY
```

---

# Version Validation (Release)

```yaml
- name: Validate version
  run: |
    python3 - <<'PY'
    import json
    from pathlib import Path

    tag = "${{ github.ref_name }}"          # e.g. v1.4.0
    if not tag.startswith("v"):
        raise SystemExit(f"❌ Tag '{tag}' must start with 'v'")
    version = tag[1:]                        # strip leading v

    config = json.loads(Path("eng/package-versioning.json").read_text())
    pkg = config["packages"].get("${{ inputs.packageId }}")
    if not pkg:
        raise SystemExit(f"❌ Package '${{ inputs.packageId }}' not found in eng/package-versioning.json")

    strategy = pkg["strategy"]

    if strategy == "single":
        expected = pkg["defaultVersionPrefix"]
    elif strategy == "by-profile":
        profile_key = "${{ inputs.versionProfile }}"
        expected = pkg["profiles"][profile_key]["versionPrefix"]
    else:
        raise SystemExit(f"❌ Unknown strategy: {strategy}")

    if version != expected:
        raise SystemExit(
            f"❌ Tag version '{version}' does not match expected prefix '{expected}' "
            f"from eng/package-versioning.json"
        )

    print(f"package_version={version}")
    PY
```

---

# Existing Workflow Changes

| File | Action |
|------|--------|
| `package-build.yaml` | **Keep as-is** — used by consumers that have not yet migrated |
| `pr-build.yaml` | No changes |
| `publish-preview.yml` | **New file** |
| `publish-release.yml` | **New file** |

---

# Example: Standard Package

```json
"LayeredCraft.StructuredLogging": {
  "strategy": "single",
  "defaultVersionPrefix": "1.4.0"
}
```

Preview:
```
1.4.0-preview.12
```

Release:
```
v1.4.0
```

---

# Example: Multi-Line Package (by-profile)

```json
"LayeredCraft.EntityFrameworkCore.DynamoDB": {
  "strategy": "by-profile",
  "profiles": {
    "net9": { "versionPrefix": "9.0.0", "dotnetSdk": "9.0.x" },
    "net10": { "versionPrefix": "10.0.0", "dotnetSdk": "10.0.x" }
  }
}
```

Consumer caller — two parallel jobs:

```yaml
jobs:
  publish-net9:
    uses: LayeredCraft/devops-templates/.github/workflows/publish-preview.yml@main
    with:
      solution: MySolution.slnx
      packageId: LayeredCraft.EntityFrameworkCore.DynamoDB
      versionProfile: net9

  publish-net10:
    uses: LayeredCraft/devops-templates/.github/workflows/publish-preview.yml@main
    with:
      solution: MySolution.slnx
      packageId: LayeredCraft.EntityFrameworkCore.DynamoDB
      versionProfile: net10
```

Results:
```
9.0.0-preview.12
10.0.0-preview.12
```

---

# Caller Workflows

## PR Build (unchanged)

```yaml
jobs:
  build:
    uses: LayeredCraft/devops-templates/.github/workflows/pr-build.yml@main
    with:
      solution: MySolution.slnx
      dotnetVersion: |
        9.0.x
        10.0.x
```

---

## Publish Preview (new)

```yaml
# Triggers on push to main
jobs:
  publish:
    uses: LayeredCraft/devops-templates/.github/workflows/publish-preview.yml@main
    with:
      solution: MySolution.slnx
      packageId: LayeredCraft.StructuredLogging
    secrets:
      NUGET_API_KEY: ${{ secrets.NUGET_API_KEY }}
```

---

## Publish Release (new)

```yaml
# Triggers on tag push vX.Y.Z
jobs:
  publish:
    uses: LayeredCraft/devops-templates/.github/workflows/publish-release.yml@main
    with:
      solution: MySolution.slnx
      packageId: LayeredCraft.StructuredLogging
    secrets:
      NUGET_API_KEY: ${{ secrets.NUGET_API_KEY }}
```

---

# JSON Schema (devops-templates ships this)

Location in devops-templates: `eng/package-versioning.schema.json`

Consumers reference it via `$schema` in their `eng/package-versioning.json` for IDE validation.

---

# Implementation Plan

## Phase 1: devops-templates repo

1. Create `eng/package-versioning.schema.json`
2. Create `.github/workflows/publish-preview.yml`
3. Create `.github/workflows/publish-release.yml`

## Phase 2: Pilot consumer (LayeredCraft.StructuredLogging repo)

1. Create `eng/package-versioning.json` with `single` strategy entry
2. Add publish-preview caller workflow (trigger: push to main)
3. Add publish-release caller workflow (trigger: tag push)
4. Remove or disable `package-build.yaml` usage in that repo

## Phase 3: Remaining packages

- Migrate each package repo
- `by-profile` packages define parallel jobs in caller

---

# Key Decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| Preview tags | No | Preview builds are ephemeral |
| Release validation | Exact prefix match | Prevents accidental version mismatch |
| GitHub Release creation | Auto in publish-release | Mirrors current behavior |
| Release trigger | Separate caller per event | Clean separation of concerns |
| JSON location | Per consuming repo | Each repo owns its version |
| SDK from JSON | Optional fallback | Caller can override; JSON is default for by-profile |
| Missing package | Fail fast | Clear error surfaced immediately |
| File missing | Fail with helpful error | Guides consumer to create the file |
| skip-duplicate | Kept | Idempotent, safe to retry |
| package-build.yaml | Keep (not deleted) | Backwards-compat during migration |
| Release Drafter | Out of scope | Separate concern, add later |
| JSON Schema | Ship in devops-templates | IDE validation, prevents typos |

---

# Benefits

- Fully explicit version control
- No MSBuild coupling
- No EF-specific logic
- Supports multiple version lines cleanly
- Works with matrix builds
- Scales across all LayeredCraft packages
- JSON Schema provides IDE-level validation for consumers

---

# Final Recommendation

Adopt the JSON manifest as the **only version source**.

- Do NOT use `PackageVersionPrefix`
- Do NOT infer from TFM or SDK
- Always resolve version from JSON

This keeps versioning:
- explicit
- centralized
- predictable
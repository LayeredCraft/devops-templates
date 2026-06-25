# DevOps Templates

## Overview

This repository contains shared workflows and templates for DevOps automation using GitHub Actions. These templates are designed to streamline the CI/CD process for various projects.

## Usage

To use these shared workflows in your repository, you need to reference them in your GitHub Actions workflow files. Here is an example of how to include a shared workflow:

```yaml
name: Build and Deploy

on:
  push:
    branches:
      - main

jobs:
  build-deploy:
    uses: your-org/devops-templates/.github/workflows/build-deploy.yaml@main
    with:
      nodeVersion: '18.x'
      dotnetVersion: '9.0.x'
      outputPath: 'publish'
      hasTests: true
      runCdk: true
```

## Draft Pull Requests

Draft pull requests run only lightweight feedback workflows. `pr-title-check.yml` can still run on draft PRs, but workflows that build, deploy, publish packages, tag commits, or update release metadata skip draft PRs.

The guarded reusable workflows are:

- `.github/workflows/pr-build.yaml`
- `.github/workflows/build-deploy.yaml`
- `.github/workflows/package-build.yaml`
- `.github/workflows/publish-preview.yml`
- `.github/workflows/publish-release.yml`
- `.github/workflows/release-drafter.yml` autolabel job

When a PR is marked ready for review, callers should trigger on `ready_for_review` so skipped checks run:

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
```

## NuGet Trusted Publishing (OIDC)

NuGet packages are published using [NuGet Trusted Publishing](https://learn.microsoft.com/en-us/nuget/nuget-org/publish-a-package#trusted-publishers) via GitHub's OIDC token exchange rather than a static API key.

### Why the push step lives in the caller

GitHub's OIDC token includes a `job_workflow_ref` claim that identifies the workflow file where the job physically runs. NuGet.org's trusted publisher policy validates this claim against the configured workflow path.

When a job runs inside a reusable workflow (`.github/workflows/publish-preview.yml`), the `job_workflow_ref` points to **devops-templates** — not the calling repository. NuGet.org rejects this because the trusted publisher policy is registered against the caller's workflow path (e.g. `LayeredCraft/my-repo/.github/workflows/publish-preview.yaml`).

To satisfy the policy, the `NuGet/login` OIDC exchange must happen in a job that runs directly in the **caller's** workflow, not inside the shared template.

### How it works

The `publish-preview.yml` and `publish-release.yml` shared workflows handle everything up to and including packing, then upload the `.nupkg` files as a GitHub Actions artifact. The caller is responsible for a separate `push` job that uses the `nuget-push` composite action:

```
build job (shared workflow)     → resolve version, build, test, pack, upload-artifact
push job  (caller, composite)   → NuGet OIDC login, download-artifact, dotnet nuget push
```

### `nuget-push` composite action

Located at `.github/actions/nuget-push/action.yml`. Handles the full push flow in three steps:

1. Exchange GitHub OIDC token for a temporary NuGet API key via `NuGet/login@v1`
2. Download the `nuget-packages` artifact produced by the build job
3. Push all `.nupkg` files to NuGet.org

Because it is a **composite action** (not a reusable workflow), it runs inline inside the caller's job — so `job_workflow_ref` remains the caller's workflow path.

### Caller setup

Each repo's publish workflow needs a `push` job with `id-token: write` permission:

```yaml
permissions:
  contents: write   # for release-drafter / release creation

jobs:
  build:
    uses: LayeredCraft/devops-templates/.github/workflows/publish-preview.yml@main
    with:
      solution: MyProject.sln
      dotnetVersion: 9.0.x
      hasTests: true
    secrets: inherit

  push:
    needs: build
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: LayeredCraft/devops-templates/.github/actions/nuget-push@main
        with:
          nuget_user: ${{ secrets.NUGET_USER }}
```

### NuGet.org trusted publisher configuration

For each package, add a trusted publisher entry on NuGet.org pointing to the **caller repo's** workflow file:

| Field | Value |
|---|---|
| Repository owner | `LayeredCraft` (or your org) |
| Repository name | the calling repo (e.g. `my-repo`) |
| Workflow | `.github/workflows/publish-preview.yaml` |
| Environment | *(leave blank)* |

The `NUGET_USER` secret must be the username of the account that **created** the trusted publisher policy (not necessarily the package owner).

## Permissions
When using these shared workflows, make sure to enable Read and Write permissions for your GitHub Actions. This is necessary for the workflows to access and modify the repository contents as needed.

To enable Read and Write permissions:

1. Go to your repository on GitHub.
2. Click on the Settings tab.
3. In the left sidebar, click on Actions.
4. Under Workflow permissions, select Read and write permissions.
5. Click Save to apply the changes.
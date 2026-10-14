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
    uses: LayeredCraft/devops-templates/.github/workflows/build-deploy.yaml@<version>
    with:
      nodeVersion: '22.x'
      dotnetVersion: '10.0.x'
      outputPath: 'publish'
      hasTests: true
      runCdk: true
      roleArn: arn:aws:iam::123456789012:role/my-app-dev-deploy
      productionRoleArn: arn:aws:iam::123456789012:role/my-app-prod-deploy
```

## PR Build (`pr-build.yaml`, v11)

`pr-build.yaml` validates pull requests without any cloud credentials. Every job runs with
`contents: read` only and never requests an OIDC token, so callers grant just:

```yaml
permissions:
  contents: read

jobs:
  build:
    uses: LayeredCraft/devops-templates/.github/workflows/pr-build.yaml@<v11 commit SHA> # v11.x
    with:
      solution: MyApp.slnx
      dotnetVersion: 11.x          # or globalJsonFile: global.json
      dotnetFormat: true
      hasTests: true
      packageManager: pnpm         # pnpmVersion omitted: read from each package.json packageManager
      nodeVersion: 22.x
      nodeProjects: >-
        [{"name":"web","path":"app","scripts":["lint","typecheck","test","build"]}]
```

Jobs, and therefore check names (`<caller job> / <job>`):

| Job | Runs when | What it does |
|---|---|---|
| `dotnet` | `solution`, `webPath`, `hasTests`, or `functions` is set | setup-dotnet → restore → optional `dotnet format --verify-no-changes` → build → optional tests/coverage → optional Blazor/Lambda packaging |
| `node (<name>)` | `nodeProjects` is not `[]` | One job per project: install with the lockfile (`pnpm install --frozen-lockfile` or `npm ci`), then each listed `package.json` script in order |
| `spa` | `spaSites` is not `[]` | The existing SPA install/build behavior (pnpm defaults to `10` here unless `pnpmVersion` is set) |

SDK selection: `dotnetVersion` accepts any actions/setup-dotnet version spec, such as `11.x` or a
multi-line list. `globalJsonFile` points setup-dotnet at a `global.json`; when both are empty,
setup-dotnet looks for a repository-root `global.json`. setup-dotnet installs a prerelease
`sdk.version` exactly (it applies `rollForward` only to release versions), so repositories pinned
to a prerelease SDK should prefer a channel such as `11.x` and let their own `global.json`
roll-forward policy accept it.

`nodeProjects[].env` values are exported only for that project's scripts and are written to the
workflow definition; never put secrets there.

### Migrating from v10

- **CDK moved out.** `runCdk` now defaults to `false`; `runCdk: true` fails with a migration
  message. The hard-coded deployment role and the application-specific `TMD_*`, `TMP_*`, and
  `OPENAI_*` secrets are gone from this workflow. Run CDK through the dedicated CDK workflow.
  `stackName` is accepted but ignored so existing callers do not fail on an unexpected input.
- **Permissions.** Callers no longer need `id-token: write` or `contents: write` for PR builds.
- **Defaults.** `dotnetVersion` no longer defaults to `9.0.x`, `nodeVersion` defaults to `lts/*`
  (was `18.x`), and `pnpmVersion` defaults to the `packageManager` field (was `10`). Pass explicit
  values to keep previous behavior.
- **Node.js validation.** Use `nodeProjects` to run lint/type-check/test/build scripts; `spaSites`
  remains for build-output packaging.
- **`build-deploy.yaml`.** From v11.1, CDK deployments take `roleArn` / `productionRoleArn` /
  `awsRegion` instead of the hard-coded role, and projects keep their own build output folders. See
  [Build and Deploy](#build-and-deploy-build-deployyaml).

## CDK Preview (`cdk-preview.yaml`)

A credential-isolated CDK diff for pull requests, in two jobs:

- `deployed templates` (credentials): assumes a read-only role through GitHub OIDC and downloads the
  deployed CloudFormation templates of the named stacks (`GetTemplate`, original stage). It never
  checks out, downloads, or runs anything from the caller.
- `diff` (no credentials): checks out the pull request and runs
  `cdk diff <stack> --template <deployed>.json`, writing each result to the job summary.

```yaml
permissions:
  contents: read

jobs:
  cdk-preview:
    uses: LayeredCraft/devops-templates/.github/workflows/cdk-preview.yaml@<commit SHA>
    permissions:
      id-token: write
      contents: read
    with:
      roleArn: arn:aws:iam::123456789012:role/my-cdk-preview
      cdkVersion: 2.1128.1
      dotnetVersion: 11.x
      stacks: >-
        [{"stack":"my-app-dev","context":{"env":"dev"}},
         {"stack":"my-app-web","contextFromDeployed":{"imageTag":":web-(?<value>[0-9a-f]+)$"}}]
```

Each `stacks` entry names a deployed stack, optional `context` (`cdk -c key=value`), and optional
`contextFromDeployed` (a regex with a `(?<value>...)` group matched against the deployed template's
strings, e.g. to keep the currently deployed image tag so only infrastructure changes show).

Reference it by **commit SHA**: the role should trust exactly this workflow revision through the
`job_workflow_ref` claim (plus `aud`, `sub`, and `repository_id`) and allow only
`cloudformation:GetTemplate` on the listed stacks. IAM is the authoritative stack allowlist.

## Build and Deploy (`build-deploy.yaml`)

Builds, tests, and packages the application, then (with `runCdk: true`) deploys the CDK stack:
`<stackName>-dev` on non-tag runs and `<stackName>-prod` on tag runs.

### AWS deployment roles

The workflow assumes a role through GitHub OIDC. The caller chooses the role; the template does not
hard-code an account.

| Input | Required | Used for |
|---|---|---|
| `roleArn` | when `runCdk: true` and the run is not a tag | development deployments (`<stackName>-dev`) and the post-deploy integration tests |
| `productionRoleArn` | when `runCdk: true` and the run is a tag | production deployments (`<stackName>-prod`) |
| `awsRegion` | no (default `us-east-1`) | the deployment region |

- **Role selection.** A run whose `github.ref` is `refs/tags/*` deploys production and assumes
  `productionRoleArn`. Every other run deploys development and assumes `roleArn`.
- **No fallback.** A tag run without `productionRoleArn` fails; it never uses `roleArn` for
  production.
- **Validation happens first.** The ARNs and region are checked before anything is built and before
  any credentials are requested. Missing or malformed values fail with an error that names the input
  to fix. Role ARNs follow IAM's rules: the `aws`, `aws-cn`, or `aws-us-gov` partition, an optional
  role path of up to 512 characters, and a role name of up to 64 characters. `cdk-preview.yaml`
  applies the same check to its `roleArn`.
- **Trust stays in IAM.** The template does not change any IAM role, trust policy, or permission.
  Recommended trust for deployment roles: exact `aud` (`sts.amazonaws.com`), the immutable
  `repository_id`, and a `sub` limited to `ref:refs/heads/main` (development) or tag refs / a
  protected `environment` (production). Never trust `pull_request`. Do not pin `job_workflow_ref`,
  so template updates never require IAM changes.
- **Integration tests use the development role.** `integrationTestSolution` runs after a development
  deployment with the `roleArn` credentials (never on tag runs). Running them with a narrower role is
  tracked in #47.

### Output folder

Publish and package steps (Blazor, Lambda ZIPs, SPAs) write to `outputPath` (default `publish`). The
folder is exposed to steps as `TEMPLATE_OUTPUT_PATH`, never `outputPath`, because MSBuild reads
environment variables as properties and an `outputPath` variable would redirect every project's build
output into one folder (#45). Projects build to their normal `bin/<Configuration>/<TFM>`.
`.github/scripts/check-msbuild-env.py` (run by the self-test) fails if any workflow reintroduces such a
variable.

### Migrating from v10 (part of the v11 migration)

Configurable deployment roles are part of the v11 migration and ship in **v11.1**. v11.0 left
`build-deploy.yaml` unchanged from v10, so when moving `build-deploy` from v10 to v11, use v11.1 or
later. Callers pinned to v10.x tags are unaffected until they change their reference.

v10 always assumed `arn:aws:iam::403542860824:role/github-deploy-role` in `us-east-1` for both
environments. From v11.1, callers that use `runCdk: true` pass their roles. To keep exactly the v10
behavior, pass the same role for both:

```yaml
    uses: LayeredCraft/devops-templates/.github/workflows/build-deploy.yaml@v11.1
    with:
      runCdk: true
      roleArn: arn:aws:iam::403542860824:role/github-deploy-role
      productionRoleArn: arn:aws:iam::403542860824:role/github-deploy-role
      awsRegion: us-east-1
```

Prefer separate, narrowly trusted development and production roles when you can. Callers with
`runCdk: false` need no change. If a required role is missing, the run stops at its first step with
an error naming the input. A tag run without `productionRoleArn` is refused; it never deploys
production with `roleArn`.

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

## Lambda Native AOT custom build image

`build-deploy.yaml` and `pr-build.yaml` use a custom Native AOT container only when a Lambda project's `aws-lambda-tools-defaults.json` explicitly supplies a custom build image. This is useful when AWS Lambda Tools lacks an official build image for the requested SDK and ARM64 Native AOT combination.

```yaml
functions: '[{"path":"src/MyLambda","name":"my-lambda"}]'
lambdaRuntimeVersion: net11.0
```

The Lambda project's `aws-lambda-tools-defaults.json` declares the image used by Lambda Tools:

```json
{
  "use-container-for-build": true,
  "container-image-for-build": "layeredcraft-lambda-native-aot:11.0.100-arm64-local"
}
```

The reusable workflow selects GitHub's `ubuntu-24.04-arm` runner for `net11.0`, so Lambda Tools sees the same ARM64 host and Lambda architecture. It detects the project setting, then its composite action reads the consumer repository's `global.json` and builds that local Amazon Linux 2023 image from the AWS .NET 10 SAM build image plus the exact SDK. The normal `dotnet-lambda package` command then reads its own defaults and uses the image. Docker is required; the image is local and is not published.

The composite action is resolved from the same repository and exact revision as the reusable workflow. Once AWS supplies the matching official image, remove `containerImageForBuild` and the custom-container path.

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

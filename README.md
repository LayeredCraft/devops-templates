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

## Permissions
When using these shared workflows, make sure to enable Read and Write permissions for your GitHub Actions. This is necessary for the workflows to access and modify the repository contents as needed.

To enable Read and Write permissions:

1. Go to your repository on GitHub.
2. Click on the Settings tab.
3. In the left sidebar, click on Actions.
4. Under Workflow permissions, select Read and write permissions.
5. Click Save to apply the changes.
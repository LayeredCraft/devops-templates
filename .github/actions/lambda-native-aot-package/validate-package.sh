#!/usr/bin/env bash
set -euo pipefail

# Validates that a packaged Lambda ZIP is a genuine, minimal Native AOT artifact - not a build that
# mixes the native executable with managed assemblies that should have been compiled into it. A
# contaminated build environment can make `dotnet lambda package` "succeed" while producing a
# publish output that still contains the app's own managed DLLs alongside `bootstrap` - a package
# that runs (Lambda invokes `bootstrap` regardless) but was never actually the minimal Native AOT
# artifact the build is supposed to produce.
#
# Deliberately does not assert an exact file count or byte size - those vary legitimately by
# consumer (embedded resources, localization cultures, etc.). It asserts the shape every genuine
# Native AOT publish must have, regardless of size: a real ARM64 ELF `bootstrap`, no stray
# obj/bin directories, and no managed DLL at the package root other than culture-specific satellite
# resource assemblies (the one kind of DLL Native AOT cannot inline, loaded via reflection for
# locale fallback).
#
# Usage: validate-package.sh <zip-path> <label-for-messages>

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <zip-path> <label>" >&2
  exit 1
fi

ZIP_PATH="$1"
LABEL="$2"

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "FAIL [$LABEL]: package not found at $ZIP_PATH" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

unzip -q "$ZIP_PATH" -d "$WORK_DIR"

FAILURES=()

if [[ ! -f "$WORK_DIR/bootstrap" ]]; then
  FAILURES+=("no 'bootstrap' entry point found at package root")
else
  FILE_OUT="$(file -b "$WORK_DIR/bootstrap")"
  if [[ "$FILE_OUT" != *"ELF"* ]] || [[ "$FILE_OUT" != *"ARM aarch64"* ]]; then
    FAILURES+=("'bootstrap' is not an ARM64 ELF executable (file said: $FILE_OUT)")
  fi
  if [[ ! -x "$WORK_DIR/bootstrap" ]]; then
    FAILURES+=("'bootstrap' is not marked executable")
  fi
fi

if find "$WORK_DIR" -type d \( -iname obj -o -iname bin \) | grep -q .; then
  FAILURES+=("package contains an 'obj' or 'bin' directory - raw build output leaked into publish")
fi

shopt -s nullglob
ROOT_DLLS=("$WORK_DIR"/*.dll)
shopt -u nullglob
if (( ${#ROOT_DLLS[@]} > 0 )); then
  NAMES=()
  for f in "${ROOT_DLLS[@]}"; do NAMES+=("$(basename "$f")"); done
  FAILURES+=("package root contains managed DLL(s) that should have been compiled into bootstrap: ${NAMES[*]}")
fi

while IFS= read -r -d '' sat; do
  base="$(basename "$sat")"
  if [[ "$base" != *.resources.dll ]]; then
    FAILURES+=("unexpected non-resource DLL under a culture subdirectory: ${sat#"$WORK_DIR"/}")
  fi
done < <(find "$WORK_DIR" -mindepth 2 -maxdepth 2 -iname "*.dll" -print0)

if (( ${#FAILURES[@]} > 0 )); then
  echo "FAIL [$LABEL]: $ZIP_PATH does not look like a genuine Native AOT artifact:" >&2
  for f in "${FAILURES[@]}"; do echo "  - $f" >&2; done
  exit 1
fi

echo "PASS [$LABEL]: $ZIP_PATH looks like a genuine, minimal Native AOT package"
echo "  bootstrap: $(file -b "$WORK_DIR/bootstrap")"
echo "  package size: $(du -h "$ZIP_PATH" | cut -f1)"
echo "  file count: $(find "$WORK_DIR" -type f | wc -l | tr -d ' ')"

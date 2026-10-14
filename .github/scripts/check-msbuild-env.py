#!/usr/bin/env python3
"""Fails when a workflow or composite action exports an MSBuild output-path property as an env var.

MSBuild reads environment variables as properties (case-insensitively), so an environment variable
such as `outputPath` silently becomes `OutputPath` for every project built in that job and redirects
all build output into one folder (#45). Checks every `env:` mapping and every `NAME=... >> $GITHUB_ENV`
write under .github/workflows and .github/actions.
"""
import pathlib
import re
import sys

import yaml

RESERVED = {
    "outputpath", "outdir", "baseoutputpath", "intermediateoutputpath",
    "baseintermediateoutputpath", "publishdir", "packageoutputpath",
}
GITHUB_ENV_WRITE = re.compile(r'''^\s*echo\s+["']?([A-Za-z_][A-Za-z0-9_]*)=.*>>\s*"?\$\{?GITHUB_ENV''', re.MULTILINE)


def walk(node, path, problems, source):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "env" and isinstance(value, dict):
                for name in value:
                    if str(name).lower() in RESERVED:
                        problems.append(f"{source}: {'/'.join(path)}/env/{name}")
            if key == "run" and isinstance(value, str):
                for name in GITHUB_ENV_WRITE.findall(value):
                    if name.lower() in RESERVED:
                        problems.append(f"{source}: {'/'.join(path)} writes {name} to $GITHUB_ENV")
            walk(value, path + [str(key)], problems, source)
    elif isinstance(node, list):
        for index, item in enumerate(node):
            walk(item, path + [str(index)], problems, source)


def main(root: str) -> int:
    base = pathlib.Path(root)
    files = sorted(base.glob(".github/workflows/*.y*ml")) + sorted(base.glob(".github/actions/**/action.y*ml"))
    problems: list[str] = []
    for file in files:
        walk(yaml.safe_load(file.read_text()), [], problems, str(file.relative_to(base)))
    for problem in problems:
        print(f"::error::MSBuild reads environment variables as properties; rename this variable: {problem}")
    print(f"Checked {len(files)} files; {len(problems)} MSBuild property collision(s).")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))

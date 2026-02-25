#!/usr/bin/env bash
set -euo pipefail

branch="${1:-feat/rbac-system-fixes}"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: not inside a git repository." >&2
  exit 1
fi

current_branch="$(git branch --show-current || true)"
if [[ -z "${current_branch}" ]]; then
  echo "Error: detached HEAD. Checkout a branch first." >&2
  exit 1
fi

if [[ "${current_branch}" != "${branch}" ]]; then
  echo "Switching to ${branch}..."
  git checkout "${branch}"
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Error: working tree not clean. Commit/stash your changes first." >&2
  git status -sb
  exit 1
fi

echo "Fetching upstream..."
git fetch upstream

echo "Checking out upstream/main package-lock.json..."
git checkout upstream/main -- package-lock.json

if git diff --quiet -- package-lock.json; then
  echo "No changes to package-lock.json after checkout. Nothing to commit."
else
  git add package-lock.json
  git commit -m "chore: align package-lock with upstream"
fi

echo "Pushing ${branch} to origin..."
git push origin "${branch}"

echo "Done."

#!/bin/bash
set -euo pipefail

# sf-prep-worktree.sh — create the isolated worktree stage 3b (dev) works in.
#
# Prints the worktree path on stdout (and NOTHING else on stdout) so the caller
# can `cd "$(sf-prep-worktree.sh N)")`. Diagnostics go to stderr.
#
# Worktrees are namespaced per repo so the same issue number in two repos never
# collides. Branch: sf/impl-<N>, based on the repo's default branch.
#
# Usage: sf-prep-worktree.sh <issue-number>
# Env:
#   SF_REPO_DIR      main checkout to branch from (default: this repo's root)
#   SF_WORKTREE_DIR  base dir for worktrees (default: ~/sf-worktrees)

issue_num="${1:?usage: sf-prep-worktree.sh <issue-number>}"
REPO_DIR="${SF_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BASE="${SF_WORKTREE_DIR:-$HOME/sf-worktrees}"

cd "$REPO_DIR"

repo_slug=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null | tr '/' '-')
[ -z "$repo_slug" ] && repo_slug="$(basename "$REPO_DIR")"
default_branch=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo main)

wt="$BASE/$repo_slug/impl-$issue_num"
branch="sf/impl-$issue_num"

# Idempotent: reuse the worktree if it already exists.
if git worktree list --porcelain | grep -qxF "worktree $wt"; then
    echo "worktree already exists: $wt" >&2
    echo "$wt"
    exit 0
fi

echo "fetching + creating worktree $wt (branch $branch from $default_branch)" >&2
git fetch --quiet origin "$default_branch"
mkdir -p "$(dirname "$wt")"

# Reuse the branch if it already exists (e.g. a retried run), else create it.
if git show-ref --verify --quiet "refs/heads/$branch"; then
    git worktree add "$wt" "$branch" >&2
else
    git worktree add "$wt" -b "$branch" "origin/$default_branch" >&2
fi

echo "$wt"

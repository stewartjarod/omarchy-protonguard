#!/usr/bin/env bash
# Bring main up to date with upstream, then push it to our fork.
#
# Run by hand, or from `omarchy update` through the post-update hook
# (~/.config/omarchy/hooks/post-update.d/protonvpn-sync).
#
# Our fork's main carries our own commits (feature work, the
# stewartjarod.protonvpn id rename) and is the branch the marketplace lists, so
# it is never rewritten: upstream changes are merged in and pushed normally,
# never rebased or force-pushed. If the merge conflicts, we undo it and stop,
# so main is never left half-merged. Fix it by hand with:
#   git merge origin/main
set -euo pipefail

PLUGIN_DIR=${PROTONVPN_DIR:-$HOME/.config/omarchy/plugins/stewartjarod.protonvpn}
BRANCH=main

cd "$PLUGIN_DIR"

# Never merge over uncommitted edits.
if [[ -n $(git status --porcelain) ]]; then
  echo "protonvpn sync: uncommitted changes in $PLUGIN_DIR, skipping" >&2
  exit 1
fi

git fetch --quiet origin
git fetch --quiet fork

git checkout --quiet "$BRANCH"

# Catch up with anything pushed to the fork from elsewhere (the dev clone)
# before merging, so the push below stays a fast-forward.
if ! git merge --quiet --ff-only "fork/$BRANCH"; then
  echo "protonvpn sync: local $BRANCH has diverged from fork/$BRANCH, branch left unchanged." >&2
  exit 1
fi

if ! git merge --quiet --no-edit origin/main; then
  git merge --abort
  echo "protonvpn sync: merging origin/main conflicts, branch left unchanged." >&2
  echo "protonvpn sync: resolve with: cd $PLUGIN_DIR && git merge origin/main" >&2
  exit 1
fi

git push --quiet fork "$BRANCH"

echo "protonvpn sync: $BRANCH is $(git rev-parse --short HEAD), pushed to fork."

#!/bin/bash
# Build MacProton.app from a runtime built by macos/build.sh, zip it and
# publish it as a GitHub release for the current tag.
#
# usage: macos/release.sh RUNTIME_DIST [REPO]
#
# Tag the commit first (git tag -a vX.Y.Z) and put the release notes in
# macos/release-notes/vX.Y.Z.md. REPO defaults to W1nkelnet/MacProton.

set -euo pipefail

proton=$(cd "$(dirname "$0")/.." && pwd)
dist=${1:?usage: macos/release.sh RUNTIME_DIST [REPO]}
repo=${2:-W1nkelnet/MacProton}
tag=$(git -C "$proton" describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null) || {
    echo "HEAD has no vX.Y.Z tag" >&2
    exit 1
}
notes=$proton/macos/release-notes/$tag.md
[ -f "$notes" ] || { echo "Missing release notes $notes" >&2; exit 1; }
git -C "$proton" diff-index --quiet --ignore-submodules HEAD -- || {
    echo "Uncommitted changes, commit them first" >&2
    exit 1
}

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
"$proton/macos/app/build-app.sh" "$out" "$dist"

# ditto keeps the symlinks in the runtime
zip=$out/MacProton-$tag.zip
(cd "$out" && ditto -c -k --keepParent MacProton.app "$zip" && shasum -a 256 "${zip##*/}" > "$zip.sha256")

git -C "$proton" push "https://github.com/$repo.git" "$tag"
gh release create "$tag" "$zip" "$zip.sha256" --repo "$repo" --title "MacProton $tag" --notes-file "$notes"

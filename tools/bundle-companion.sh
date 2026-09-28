#!/bin/sh
# Packs the host companion (host/) into assets/companion/ so the app can
# upload and install it over SFTP from the "Agent hooks" screen.
#
#   tools/bundle-companion.sh          rebuild assets/companion/ from host/
#   tools/bundle-companion.sh --check  exit 1 when assets/companion/ is stale
#
# assets/companion/ holds exactly two files:
#   companion.tar.gz  bin/, lib/, vendor/, install.sh, package.json, README.md
#                     (never tests), as one gzipped ustar archive
#   manifest.json     version, archive name and the sha256 of every file
#                     inside the archive
# The companion ships as an archive because App Store Connect rejects any
# script (a file starting with #!) inside an iOS app as unsigned code, even
# when it is not executable. The phone uploads the archive, unpacks it with
# tar on the host and checks the sha256 sums before running install.sh.
#
# The archive is deterministic (sorted names, fixed mtime, owner and mode,
# gzip -n), so re-running this without host/ changes gives identical bytes.
# Building needs GNU tar (gtar on macOS); --check works with any tar and
# compares the unpacked files with host/ byte for byte.
#
# The output is committed so builds are reproducible without running this;
# re-run it (and commit) whenever host/ changes. A widget test fails while
# the bundle and host/ disagree.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/host"
DEST="$ROOT/assets/companion"
ARCHIVE=companion.tar.gz

files() {
  (cd "$SRC" && {
    find bin lib vendor -type f
    echo install.sh
    echo package.json
    echo README.md
  } | LC_ALL=C sort)
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

manifest() {
  version=$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$SRC/package.json" | head -n 1)
  printf '{\n  "version": "%s",\n  "archive": "%s",\n  "files": {\n' "$version" "$ARCHIVE"
  for f in $(files); do
    printf '    "%s": "%s"\n' "$f" "$(sha256 "$SRC/$f")"
  done | sed '$!s/$/,/'
  printf '  }\n}\n'
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ "${1:-}" = "--check" ]; then
  status=0
  # Nothing but the archive and its manifest: any other file (a script
  # with #!, an executable) would be flagged by App Store Connect.
  for f in $(cd "$DEST" && find . -type f | sed 's|^\./||' | LC_ALL=C sort); do
    case "$f" in
      "$ARCHIVE"|manifest.json) ;;
      *) echo "unexpected file (ship it inside $ARCHIVE): assets/companion/$f" >&2; status=1 ;;
    esac
    if [ -x "$DEST/$f" ] || [ "$(head -c 2 "$DEST/$f")" = '#!' ]; then
      echo "script or executable (App Store rejects it): assets/companion/$f" >&2
      status=1
    fi
  done
  if [ ! -f "$DEST/$ARCHIVE" ]; then
    echo "missing: assets/companion/$ARCHIVE" >&2
    exit 1
  fi
  mkdir "$TMP/x"
  tar -xzf "$DEST/$ARCHIVE" -C "$TMP/x"
  packed=$(cd "$TMP/x" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
  [ "$packed" = "$(files)" ] || { echo "stale: $ARCHIVE holds other files than host/" >&2; status=1; }
  for f in $(files); do
    cmp -s "$SRC/$f" "$TMP/x/$f" || { echo "stale: $ARCHIVE:$f" >&2; status=1; }
  done
  manifest | cmp -s - "$DEST/manifest.json" || { echo "stale: assets/companion/manifest.json" >&2; status=1; }
  exit $status
fi

if command -v gtar >/dev/null 2>&1; then
  TAR=gtar
elif tar --version 2>/dev/null | head -n 1 | grep -q 'GNU tar'; then
  TAR=tar
else
  echo "GNU tar is needed to build a reproducible archive (macOS: brew install gnu-tar)" >&2
  exit 1
fi

# Stage with explicit modes so the archive does not depend on the checkout's
# permissions or umask: scripts 0755 (they run on the host), the rest 0644.
mkdir "$TMP/stage"
for f in $(files); do
  mkdir -p "$TMP/stage/$(dirname "$f")"
  cp "$SRC/$f" "$TMP/stage/$f"
  case "$f" in
    bin/*|install.sh) chmod 755 "$TMP/stage/$f" ;;
    *) chmod 644 "$TMP/stage/$f" ;;
  esac
done

# File entries only (no directory entries); tar creates bin/, lib/ and vendor/.
# shellcheck disable=SC2046 # the sorted file list is split on purpose
(cd "$TMP/stage" && "$TAR" --format=ustar --sort=name --mtime=@0 \
  --owner=0 --group=0 --numeric-owner --no-recursion \
  -cf - $(files)) | gzip -n -9 > "$TMP/$ARCHIVE"

# Only this script's own outputs are replaced; the old per-file layout
# (bin/, lib/, install.sh, ...) is removed.
mkdir -p "$DEST"
for f in $(cd "$DEST" && find . -type f | sed 's|^\./||'); do
  case "$f" in "$ARCHIVE"|manifest.json) ;; *) rm -f "$DEST/$f" ;; esac
done
find "$DEST" -mindepth 1 -type d -empty -delete
cp "$TMP/$ARCHIVE" "$DEST/$ARCHIVE"
chmod 644 "$DEST/$ARCHIVE"
manifest > "$DEST/manifest.json"
echo "packed $(files | wc -l | tr -d ' ') files into assets/companion/$ARCHIVE (version $(sed -n 's/.*"version": "\(.*\)".*/\1/p' "$DEST/manifest.json"))"

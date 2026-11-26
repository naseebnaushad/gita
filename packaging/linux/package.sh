#!/usr/bin/env bash
# Usage: package.sh <deb|rpm> <flutter linux bundle dir> <version> <out dir> [x64|arm64]
# Needs fpm (gem install fpm); rpm also needs the `rpm` package.
set -euo pipefail
fmt=$1 bundle=$(cd "$2" && pwd) version=$3 out=$4 arch=${5:-x64}
case "$arch" in
  x64) deb_arch=amd64 rpm_arch=x86_64 ;;
  arm64) deb_arch=arm64 rpm_arch=aarch64 ;;
  *) echo "unknown architecture: $arch" >&2; exit 2 ;;
esac
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"; out=$(cd "$out" && pwd)
root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
"$here/stage.sh" "$bundle" "$root"

common=(-s dir -n gita -v "$version" --iteration 1
  --license MIT --url https://github.com/naseebnaushad/gita
  --maintainer "naseebnaushad <naseebnaushad46@gmail.com>"
  --description "Keeps each git project on the right GitHub account.")
case "$fmt" in
  deb) deps=(-d libgtk-3-0 -d libsecret-1-0 --deb-recommends libsecret-tools
             -a "$deb_arch" -t deb -p "$out/gita_${version}_${deb_arch}.deb") ;;
  rpm) deps=(-d gtk3 -d libsecret -a "$rpm_arch" -t rpm
             -p "$out/gita-${version}-1.${rpm_arch}.rpm") ;;
  *) echo "unknown format: $fmt" >&2; exit 2 ;;
esac
fpm "${common[@]}" "${deps[@]}" -C "$root" .
ls -l "$out"

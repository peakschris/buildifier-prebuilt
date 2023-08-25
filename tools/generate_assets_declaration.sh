#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <version>"
  exit 1
fi

readonly version="$1"

assets=()

for binary in buildifier buildozer; do
  for os in darwin linux windows; do
    for arch in amd64 arm64; do
      filename=$binary-$os-$arch
      if [[ "$os" == "windows" ]]; then
        if [[ "$arch" == "arm64" ]]; then
          continue
        fi

        filename="$filename.exe"
      fi

      url=https://github.com/bazelbuild/buildtools/releases/download/$version/$filename
      bin=$(mktemp)
      if ! curl --fail -L "$url" -o "$bin"; then
        echo "error: failed to download $url"
        exit 1
      fi

      sha=$(shasum -a 256 "$bin" | cut -d ' ' -f 1)
      assets+=("            \"${binary}_${os}_${arch}\": \"$sha\",")
    done
  done
done

cat <<-EOF
load("@buildifier_prebuilt//:defs.bzl", "buildifier_prebuilt_register_toolchains", "buildtools_assets")

buildifier_prebuilt_register_toolchains(
    assets = buildtools_assets(
        version = "$version",
        names = ["buildifier", "buildozer"],
        platforms = ["darwin", "linux", "windows"],
        arches = ["amd64", "arm64"],
        sha256_values = {
$(printf '%s\n' "${assets[@]}")
        },
    ),
)
EOF

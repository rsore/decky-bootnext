#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
release_dir="${project_dir}/release"

for command in node pnpm zip; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "Required command not found: ${command}" >&2
    exit 1
  fi
done

version="$(
  node -e \
    'process.stdout.write(require(process.argv[1]).version)' \
    "${project_dir}/package.json"
)"

temporary_dir="$(mktemp -d)"
trap 'rm -rf -- "${temporary_dir}"' EXIT

plugin_dir="${temporary_dir}/decky-bootnext"
archive="${release_dir}/decky-bootnext-v${version}.zip"

echo "Building BootNext..."
pnpm --dir "${project_dir}" run build

if [[ ! -f "${project_dir}/dist/index.js" ]]; then
  echo "Build did not produce dist/index.js" >&2
  exit 1
fi

echo "Packaging BootNext v${version}..."
mkdir -p "${plugin_dir}/dist" "${plugin_dir}/scripts" "${release_dir}"

cp \
  "${project_dir}/LICENSE" \
  "${project_dir}/README.md" \
  "${project_dir}/main.py" \
  "${project_dir}/package.json" \
  "${project_dir}/plugin.json" \
  "${plugin_dir}/"

cp \
  "${project_dir}/dist/index.js" \
  "${plugin_dir}/dist/"

cp \
  "${project_dir}/scripts/deploy.sh" \
  "${plugin_dir}/scripts/"

rm -f -- "${archive}"

(
  cd "${temporary_dir}"
  zip -qr "${archive}" decky-bootnext
)

echo "Created ${archive}"

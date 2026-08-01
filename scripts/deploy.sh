#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Config variables, copy `.deck.env.example` to `.deck.env` to override
config_file="${BOOTNEXT_DECK_CONFIG:-${project_dir}/.deck.env}"
if [[ -f "${config_file}" ]]; then
  source "${config_file}"
fi
deck_host="${DECK_HOST:-steamdeck}"
deck_port="${DECK_PORT:-22}"
deck_user="${DECK_USER:-deck}"
deck_ssh_key="${DECK_SSH_KEY:-}"
deck_plugin_dir="${DECK_PLUGIN_DIR:-/home/deck/homebrew/plugins/decky-bootnext}"
remote_stage="/tmp/decky-bootnext-deploy-${deck_user}"
control_path="/tmp/decky-bootnext-ssh-${deck_user}-$$"

# Close SSH connection on exit
cleanup() {
  if [[ -S "${control_path}" ]]; then
    ssh -o "ControlPath=${control_path}" -O exit "${target:-}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Ensure required programs are in PATH
for command in rsync ssh; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "Required command not found: ${command}" >&2
    exit 1
  fi
done

# Check that plugin has been built
if [[ ! -f "${project_dir}/dist/index.js" ]]; then
  echo "Missing dist/index.js; run 'pnpm run build' first." >&2
  exit 1
fi

# When running through WSL on Windows, the hostname cannot always reliably
# be used directly, so something like `deck@steamdeck` may not work.
# To work around this we try asking the windows host to evaluate the actual
# IP address of the hostname first
resolved_deck_host="${deck_host}"
if ! getent ahostsv4 "${deck_host}" >/dev/null 2>&1 \
  && grep -qi microsoft /proc/version 2>/dev/null \
  && command -v powershell.exe >/dev/null 2>&1; then
  windows_host="${deck_host%.local}"
  windows_address="$(
    powershell.exe -NoProfile -NonInteractive -Command \
      "Resolve-DnsName -Name '${windows_host}' -Type A -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty IPAddress" \
      2>/dev/null | tr -d '\r' | head -n 1 || true
  )"
  if [[ "${windows_address}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    resolved_deck_host="${windows_address}"
    echo "Resolved ${deck_host} through Windows: ${resolved_deck_host}"
  fi
fi

ssh_args=(
  -p "${deck_port}"
  -o ControlMaster=auto
  -o ControlPersist=60
  -o "ControlPath=${control_path}"
)
rsync_ssh=(
  ssh
  -p "${deck_port}"
  -o ControlMaster=auto
  -o ControlPersist=60
  -o "ControlPath=${control_path}"
)
if [[ -n "${deck_ssh_key}" ]]; then
  ssh_args+=(-i "${deck_ssh_key}")
  rsync_ssh+=(-i "${deck_ssh_key}")
fi

target="${deck_user}@${resolved_deck_host}"

echo "Staging BootNext on ${target}..."
ssh "${ssh_args[@]}" "${target}" \
  "rm -rf -- '${remote_stage}' && mkdir -p '${remote_stage}/dist'"
rsync -az \
  -e "${rsync_ssh[*]}" \
  "${project_dir}/LICENSE" \
  "${project_dir}/README.md" \
  "${project_dir}/main.py" \
  "${project_dir}/package.json" \
  "${project_dir}/plugin.json" \
  "${target}:${remote_stage}/"
rsync -az \
  -e "${rsync_ssh[*]}" \
  "${project_dir}/dist/index.js" \
  "${target}:${remote_stage}/dist/"

echo "Installing the plugin and restarting Decky..."
printf -v remote_command \
  "sudo rm -rf -- %q && sudo mv -- %q %q && sudo chown -R root:root -- %q && sudo systemctl restart plugin_loader" \
  "${deck_plugin_dir}" "${remote_stage}" "${deck_plugin_dir}" "${deck_plugin_dir}"
ssh -tt "${ssh_args[@]}" "${target}" "${remote_command}"

echo "BootNext deployed to ${deck_host} (${resolved_deck_host})."

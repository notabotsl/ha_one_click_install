#!/usr/bin/env bash
# =============================================================================
#  ha-stack one-click installer
#
#  Installs Home Assistant (container) + Mosquitto + Zigbee2MQTT + Node-RED +
#  ESPHome (+ optional Matter server, code-server, HACS) on Debian/Ubuntu using
#  Docker Compose, driven by an Ansible playbook that runs on the machine
#  itself.
#
#  Quick start (on the target Debian machine):
#    curl -fsSL https://raw.githubusercontent.com/notabotsl/ha_one_click_install/main/install.sh | sudo bash
#
#  With options:
#    curl -fsSL .../install.sh | sudo bash -s -- --tz Europe/Madrid --with-matter
#
#  Re-running is safe: the playbook is idempotent and your settings are kept in
#  /etc/ha-stack/config.yml.
# =============================================================================
set -Eeuo pipefail

REPO_URL="${HA_STACK_REPO:-https://github.com/notabotsl/ha_one_click_install.git}"
BRANCH="${HA_STACK_BRANCH:-main}"
SRC_DIR="${HA_STACK_SRC:-/opt/ha-stack-installer}"
CONFIG_DIR="/etc/ha-stack"
CONFIG_FILE="${CONFIG_DIR}/config.yml"
LOG_FILE="/var/log/ha-stack-install.log"
ANSIBLE_CORE_SPEC="${ANSIBLE_CORE_SPEC:-ansible-core>=2.15,<2.21}"

UPDATE_SRC=1
EXTRA_ARGS=()
declare -A SETTINGS=()

c_blue=$'\e[1;34m'; c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'; c_off=$'\e[0m'
[[ -t 1 ]] || { c_blue=""; c_yellow=""; c_red=""; c_off=""; }
info() { printf '%s==>%s %s\n' "$c_blue" "$c_off" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$c_yellow" "$c_off" "$*" >&2; }
die()  { printf '%s[error]%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: install.sh [options] [-- extra ansible-playbook args]

Options (persisted to /etc/ha-stack/config.yml):
  --tz ZONE               Timezone, e.g. Europe/Madrid (default: keep host's)
  --dir PATH              Stack directory (default: /opt/ha-stack)
  --zigbee-device PATH    Zigbee coordinator, e.g. /dev/serial/by-id/usb-...
                          (default: autodetect)
  --zigbee-adapter TYPE   zstack | ember | deconz | zigate | zboss (default: guess)
  --no-zigbee             Do not deploy Zigbee2MQTT
  --no-nodered            Do not deploy Node-RED
  --no-esphome            Do not deploy ESPHome
  --no-hacs               Do not install HACS
  --no-backup             Do not install the daily backup timer
  --with-matter           Deploy the Matter server
  --with-code-server      Deploy code-server (VS Code in the browser)

One-shot options:
  --update                Pull newer container images during this run
  --local                 Use the directory this script lives in (no git)
  --no-pull               Do not 'git pull' the installer sources
  --branch NAME           Git branch to install from (default: main)
  -h, --help              Show this help

Anything after "--" is passed to ansible-playbook (e.g. -- -e ha_admin_user=me -v).
EOF
}

# ----------------------------------------------------------------------------
# Arguments
# ----------------------------------------------------------------------------
SCRIPT_PATH="${BASH_SOURCE[0]:-}"
LOCAL_MODE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tz)              SETTINGS[ha_timezone]="${2:?}"; shift ;;
    --dir)             SETTINGS[ha_stack_dir]="${2:?}"; shift ;;
    --zigbee-device)   SETTINGS[zigbee_device]="${2:?}"; shift ;;
    --zigbee-adapter)  SETTINGS[zigbee_adapter]="${2:?}"; shift ;;
    --no-zigbee)       SETTINGS[ha_zigbee2mqtt_enabled]=false ;;
    --no-nodered)      SETTINGS[ha_nodered_enabled]=false ;;
    --no-esphome)      SETTINGS[ha_esphome_enabled]=false ;;
    --no-hacs)         SETTINGS[ha_hacs_enabled]=false ;;
    --no-backup)       SETTINGS[ha_backup_enabled]=false ;;
    --with-matter)     SETTINGS[ha_matter_enabled]=true ;;
    --with-code-server) SETTINGS[ha_codeserver_enabled]=true ;;
    --update)          EXTRA_ARGS+=(-e ha_update_images=true) ;;
    --local)           LOCAL_MODE=1 ;;
    --no-pull)         UPDATE_SRC=0 ;;
    --branch)          BRANCH="${2:?}"; shift ;;
    -h|--help)         usage; exit 0 ;;
    --)                shift; EXTRA_ARGS+=("$@"); break ;;
    *)                 usage >&2; die "Unknown option: $1" ;;
  esac
  shift
done

# ----------------------------------------------------------------------------
# Pre-flight checks
# ----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  if [[ -n "$SCRIPT_PATH" && -f "$SCRIPT_PATH" ]] && command -v sudo >/dev/null; then
    exec sudo -E bash "$SCRIPT_PATH" "$@"
  fi
  die "Please run as root, e.g.: curl -fsSL <url>/install.sh | sudo bash"
fi

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
info "ha-stack installer — $(date -Is) — log: $LOG_FILE"

[[ -r /etc/os-release ]] || die "Cannot detect OS (/etc/os-release missing)."
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
  debian|raspbian|ubuntu) ;;
  *) [[ "${ID_LIKE:-}" == *debian* ]] || die "Unsupported OS '${ID:-?}'. Debian 12+ (or Ubuntu 22.04+) is required."
     warn "OS '${ID}' is Debian-like but untested." ;;
esac

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64|arm64) ;;
  *) die "Architecture '$ARCH' is not supported by current Home Assistant images (need amd64 or arm64)." ;;
esac

# Running from a checkout (bash install.sh / ./install.sh) instead of curl|bash?
# The managed checkout in $SRC_DIR (used by `ha-stack reconfigure`) is still
# git-updated; any other checkout is used as-is and never touched by git.
if [[ -n "$SCRIPT_PATH" && -f "$(dirname "$SCRIPT_PATH")/site.yml" ]]; then
  script_dir="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
  if [[ $LOCAL_MODE -eq 1 || "$script_dir" != "$SRC_DIR" ]]; then
    SRC_DIR="$script_dir"
    LOCAL_MODE=1
  fi
elif [[ $LOCAL_MODE -eq 1 ]]; then
  die "--local needs the script to be run from a checkout (bash ./install.sh --local)."
fi

# ----------------------------------------------------------------------------
# Bootstrap packages
# ----------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -y -q -o DPkg::Lock::Timeout=300)
info "Installing bootstrap packages (git, python3, venv)…"
"${APT[@]}" update
"${APT[@]}" install --no-install-recommends \
  ca-certificates curl git python3 python3-venv python3-apt python3-pip

# ----------------------------------------------------------------------------
# Installer sources
# ----------------------------------------------------------------------------
if [[ $LOCAL_MODE -eq 1 ]]; then
  info "Using local sources in $SRC_DIR"
elif [[ -d "$SRC_DIR/.git" ]]; then
  if [[ $UPDATE_SRC -eq 1 ]]; then
    info "Updating installer sources in $SRC_DIR ($BRANCH)…"
    git -C "$SRC_DIR" fetch --quiet origin "$BRANCH"
    git -C "$SRC_DIR" checkout --quiet "$BRANCH"
    git -C "$SRC_DIR" reset --quiet --hard "origin/$BRANCH"
  fi
else
  info "Cloning $REPO_URL ($BRANCH) into $SRC_DIR…"
  git clone --quiet --depth 1 --branch "$BRANCH" "$REPO_URL" "$SRC_DIR"
fi
cd "$SRC_DIR"

# ----------------------------------------------------------------------------
# Ansible (isolated virtualenv, so we get a recent ansible-core everywhere)
# ----------------------------------------------------------------------------
VENV="/opt/ha-stack-installer-venv"
if [[ ! -x "$VENV/bin/ansible-playbook" ]]; then
  info "Creating Ansible virtualenv in $VENV…"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
fi
"$VENV/bin/pip" install --quiet --upgrade "$ANSIBLE_CORE_SPEC"
info "Installing Ansible collections…"
"$VENV/bin/ansible-galaxy" collection install --upgrade -r requirements.yml -p "$SRC_DIR/collections" >/dev/null

# ----------------------------------------------------------------------------
# Persist user settings
# ----------------------------------------------------------------------------
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
if [[ ! -f "$CONFIG_FILE" ]]; then
  cat >"$CONFIG_FILE" <<'EOF'
---
# ha-stack local settings. Every variable from group_vars/all.yml in the
# installer repository can be overridden here. Re-run `sudo ha-stack reconfigure`
# after editing.
ha_stack_config_version: 1
EOF
fi
set_conf() {  # set_conf key value  — simple "key: value" upsert
  local key="$1" val="$2" line
  if [[ "$val" == true || "$val" == false ]]; then line="${key}: ${val}"; else line="${key}: \"${val//\"/\\\"}\""; fi
  if grep -qE "^${key}:" "$CONFIG_FILE"; then
    local tmp; tmp="$(mktemp)"
    awk -v k="$key" -v l="$line" 'index($0, k":")==1 {print l; next} {print}' "$CONFIG_FILE" >"$tmp"
    cat "$tmp" >"$CONFIG_FILE"; rm -f "$tmp"
  else
    printf '%s\n' "$line" >>"$CONFIG_FILE"
  fi
}
for key in "${!SETTINGS[@]}"; do set_conf "$key" "${SETTINGS[$key]}"; done
chmod 600 "$CONFIG_FILE"

# ----------------------------------------------------------------------------
# Run the playbook against this machine
# ----------------------------------------------------------------------------
info "Running Ansible playbook (this can take a while on first run)…"
export ANSIBLE_CONFIG="$SRC_DIR/ansible.cfg"
export ANSIBLE_FORCE_COLOR="${ANSIBLE_FORCE_COLOR:-1}"
"$VENV/bin/ansible-playbook" -i inventory/local.yml site.yml \
  -e "@$CONFIG_FILE" -e "ha_stack_src_dir=$SRC_DIR" "${EXTRA_ARGS[@]}"

info "Done. Manage the stack with: sudo ha-stack help"

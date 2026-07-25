#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Pterodactyl Panel installer for Termux and PRoot environments.
# This project is independent from the official Pterodactyl project and is
# inspired by the GPL-licensed pterodactyl-installer project.

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_NAME="pterodactyl-proot"
CONTAINER_NAME="pterodactyl-panel"
CONTAINER_IMAGE="ubuntu:24.04"
MANAGED_MARKER="managed-by-pterodactyl-proot-v1"
PANEL_DIR="${PTERO_PANEL_DIR:-/var/www/pterodactyl}"
ETC_DIR="${PTERO_ETC_DIR:-/etc/pterodactyl-proot}"
STATE_DIR="${PTERO_STATE_DIR:-/var/lib/pterodactyl-proot}"
LOG_DIR="${PTERO_LOG_DIR:-/var/log/pterodactyl-proot}"
RUN_DIR="${PTERO_RUN_DIR:-/run/pterodactyl-proot}"
MARIADB_RUN_DIR="$RUN_DIR/mariadb"
REDIS_RUN_DIR="$RUN_DIR/redis"
PHP_RUN_DIR="$RUN_DIR/php"
NGINX_RUN_DIR="$RUN_DIR/nginx"
INSTALL_CONFIG="$ETC_DIR/install.conf"
INSTALL_STATE_DIR="$STATE_DIR/install-state"
MANAGED_FILE="$ETC_DIR/managed-by"
INSTALL_LOG="$LOG_DIR/install.log"
GUEST_INSTALLER="/usr/local/share/pterodactyl-proot/install.sh"
RUNTIME_BIN="${PTERO_RUNTIME_BIN:-/usr/local/bin/ptero-runtime}"
OFFICIAL_PANEL_API="https://api.github.com/repos/pterodactyl/panel/releases/latest"

# BASH_SOURCE may be relative (for example, "./install.sh"). Installation later
# changes into the Panel directory, so preserve an absolute source path now.
INSTALLER_SOURCE=${BASH_SOURCE[0]}
if [[ $INSTALLER_SOURCE != /* ]]; then
  INSTALLER_SOURCE="$PWD/${INSTALLER_SOURCE#./}"
fi

COLOR_RED=$'\033[0;31m'
COLOR_GREEN=$'\033[0;32m'
COLOR_YELLOW=$'\033[1;33m'
COLOR_NC=$'\033[0m'

TEMP_POLICY_CREATED=0
POLICY_WAS_PRESENT=0
POLICY_BACKUP=/usr/sbin/policy-rc.d.pterodactyl-proot-backup
BOOTSTRAP_MARIADB_PID=""
BOOTSTRAP_REDIS_PID=""
PHP_VERSION=""
GUEST_OS=""
GUEST_VERSION=""
INSTALL_LOG_ACTIVE=0

append_install_log() {
  [[ $INSTALL_LOG_ACTIVE == 1 ]] || return 0
  printf '%s\n' "$*" >>"$INSTALL_LOG" 2>/dev/null || true
}

info() {
  printf '%s\n' "* $*"
  append_install_log "* $*"
}

success() {
  printf '%s\n' "* ${COLOR_GREEN}SUCCESS${COLOR_NC}: $*"
  append_install_log "* SUCCESS: $*"
}

warn() {
  printf '%s\n' "* ${COLOR_YELLOW}WARNING${COLOR_NC}: $*" >&2
  append_install_log "* WARNING: $*"
}

die() {
  printf '%s\n' "* ${COLOR_RED}ERROR${COLOR_NC}: $*" >&2
  append_install_log "* ERROR: $*"
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

redact_error_command() {
  local command=${1:-unknown}
  local normalized
  normalized=$(printf '%s' "$command" | tr '[:lower:]' '[:upper:]')
  if [[ $normalized == *PASSWORD* ||
    $normalized == *APP_KEY* ||
    $normalized == *TOKEN* ||
    $normalized == *SECRET* ]]; then
    printf '%s\n' "[redacted because the command may contain a secret]"
  else
    printf '%s\n' "$command"
  fi
}

on_error() {
  local status=$?
  local line=${1:-unknown}
  local command=${2:-unknown}
  local context=${FUNCNAME[1]:-main}
  local safe_command
  trap - ERR
  safe_command=$(redact_error_command "$command")
  printf '%s\n' "* ${COLOR_RED}ERROR${COLOR_NC}: Installation failed near line $line." >&2
  printf '%s\n' "* Context: $context" >&2
  printf '%s\n' "* Command: $safe_command" >&2
  append_install_log "* ERROR: Installation failed near line $line."
  append_install_log "* Context: $context"
  append_install_log "* Command: $safe_command"
  if [[ -n ${INSTALL_LOG:-} && -f ${INSTALL_LOG:-} ]]; then
    printf '%s\n' "* Review $INSTALL_LOG, fix the reported issue, then rerun the installer to resume." >&2
  fi
  exit "$status"
}

cleanup_policy_rc() {
  if [[ $TEMP_POLICY_CREATED == 1 ]]; then
    rm -f /usr/sbin/policy-rc.d
    if [[ $POLICY_WAS_PRESENT == 1 && ( -e $POLICY_BACKUP || -L $POLICY_BACKUP ) ]]; then
      mv "$POLICY_BACKUP" /usr/sbin/policy-rc.d
    fi
    TEMP_POLICY_CREATED=0
  fi
}

stop_bootstrap_services() {
  local pid
  for pid in "$BOOTSTRAP_REDIS_PID" "$BOOTSTRAP_MARIADB_PID"; do
    if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done

  for pid in "$BOOTSTRAP_REDIS_PID" "$BOOTSTRAP_MARIADB_PID"; do
    if [[ -n $pid ]]; then
      wait "$pid" 2>/dev/null || true
    fi
  done
}

cleanup_guest() {
  stop_bootstrap_services
  cleanup_policy_rc
}

detect_mode() {
  if [[ ${PTERO_INTERNAL_GUEST:-0} == 1 ]]; then
    printf '%s\n' guest
    return
  fi

  if [[ -r /etc/os-release ]]; then
    local detected_id
    detected_id=$(awk -F= '$1 == "ID" {gsub(/"/, "", $2); print tolower($2)}' /etc/os-release)
    if [[ $detected_id == ubuntu || $detected_id == debian ]]; then
      printf '%s\n' guest
      return
    fi
  fi

  if [[ -n ${TERMUX_VERSION:-} || ${PREFIX:-} == /data/data/*/files/usr ]]; then
    printf '%s\n' termux
    return
  fi

  printf '%s\n' unsupported
}

normalize_arch() {
  local arch=${1:-}
  case "$arch" in
    aarch64 | arm64)
      printf '%s\n' arm64
      ;;
    x86_64 | amd64)
      printf '%s\n' amd64
      ;;
    *)
      return 1
      ;;
  esac
}

select_guest_platform() {
  local os=$1
  local version=$2

  case "$os:$version" in
    ubuntu:24.04 | ubuntu:24)
      PHP_VERSION=8.3
      ;;
    debian:12 | debian:12.*)
      PHP_VERSION=8.2
      ;;
    debian:13 | debian:13.*)
      PHP_VERSION=8.3
      ;;
    ubuntu:26.04 | ubuntu:26)
      return 26
      ;;
    *)
      return 1
      ;;
  esac
}

validate_port() {
  local port=${1:-}
  [[ $port =~ ^[0-9]+$ ]] || return 1
  ((port >= 1024 && port <= 65535))
}

validate_email() {
  local value=${1:-}
  [[ $value =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

validate_username() {
  local value=${1:-}
  [[ $value =~ ^[A-Za-z0-9._-]{3,32}$ ]]
}

validate_http_url() {
  local value=${1:-}
  local expected_port=${2:-}
  local url_port

  [[ $value =~ ^http://(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9.-]+):([0-9]{1,5})$ ]] || return 1
  url_port=${BASH_REMATCH[2]}
  validate_port "$url_port" || return 1
  [[ -z $expected_port || $url_port == "$expected_port" ]]
}

port_in_use() {
  local port=${1:-}
  command_exists ss || return 1
  ss -H -ltn 2>/dev/null |
    awk '{print $4}' |
    grep -Eq "(^|\\]|:)$port$"
}

detect_lan_ip() {
  local candidate=""
  if command_exists ip; then
    candidate=$(ip -4 route get 1.1.1.1 2>/dev/null |
      awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')
  fi
  if [[ -z $candidate ]] && command_exists hostname; then
    candidate=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  [[ $candidate =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && printf '%s\n' "$candidate"
}

validate_timezone() {
  local value=${1:-}
  # The PHP expression intentionally uses PHP's $argv, not a shell variable.
  # shellcheck disable=SC2016
  php -r 'exit(in_array($argv[1], timezone_identifiers_list(), true) ? 0 : 1);' "$value" 2>/dev/null
}

validate_admin_password() {
  local value=${1:-}
  ((${#value} >= 8)) || return 1
  [[ $value =~ [A-Z] ]] || return 1
  [[ $value =~ [a-z] ]] || return 1
  [[ $value =~ [0-9] ]]
}

generate_secret() {
  openssl rand -hex 32
}

step_done() {
  [[ -f "$INSTALL_STATE_DIR/$1.done" ]]
}

mark_step() {
  mkdir -p "$INSTALL_STATE_DIR"
  : >"$INSTALL_STATE_DIR/$1.done"
  chmod 600 "$INSTALL_STATE_DIR/$1.done"
}

assert_managed_guest() {
  [[ -f $MANAGED_FILE ]] || die "This installation is not marked as managed by $PROJECT_NAME."
  grep -Fxq "$MANAGED_MARKER" "$MANAGED_FILE" || die "The management marker in $MANAGED_FILE is not recognized."
}

warn_resources() {
  local path=${1:-.}
  local available_kb
  local memory_kb=""
  available_kb=$(df -Pk "$path" 2>/dev/null | awk 'NR == 2 {print $4}')
  if [[ $available_kb =~ ^[0-9]+$ ]] && ((available_kb < 4194304)); then
    warn "Less than 4 GiB of free storage is available. The installation may run out of space."
  fi
  if [[ -r /proc/meminfo ]]; then
    memory_kb=$(awk '$1 == "MemTotal:" {print $2}' /proc/meminfo)
  fi
  if [[ $memory_kb =~ ^[0-9]+$ ]] && ((memory_kb < 2097152)); then
    warn "Less than 2 GiB of memory is available. MariaDB, Composer, or the Panel may be killed under load."
  fi
}

copy_self() {
  local destination=$1
  local source=$INSTALLER_SOURCE
  [[ -f $source ]] ||
    die "Installer source $source is no longer available. Rerun from a saved install.sh file."
  mkdir -p "$(dirname "$destination")"
  cp "$source" "$destination"
  chmod 755 "$destination"
}

write_termux_controller() {
  local destination="$HOME/.local/bin/ptero-panel"
  mkdir -p "$(dirname "$destination")" "$HOME/.local/state/pterodactyl-proot"

  cat >"$destination" <<'CONTROLLER'
#!/data/data/com.termux/files/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

CONTAINER="pterodactyl-panel"
MARKER="managed-by-pterodactyl-proot-v1"
BOOT_FILE="$HOME/.termux/boot/pterodactyl-panel"
HOST_LOG_DIR="$HOME/.local/state/pterodactyl-proot"

die() {
  printf '%s\n' "* ERROR: $*" >&2
  exit 1
}

need_container() {
  command -v proot-distro >/dev/null 2>&1 || die "proot-distro is not installed."
  proot-distro list -q 2>/dev/null | grep -Fxq "$CONTAINER" || die "Container '$CONTAINER' is not installed."
  proot-distro login "$CONTAINER" -- sh -c "grep -Fxq '$MARKER' /etc/pterodactyl-proot/managed-by" ||
    die "Container '$CONTAINER' is not managed by this installer."
}

guest() {
  proot-distro login "$CONTAINER" -- "$@"
}

start_panel() {
  need_container
  if guest /usr/local/bin/ptero-runtime running >/dev/null 2>&1; then
    printf '%s\n' "* Panel services are already running."
    guest /usr/local/bin/ptero-runtime status
    return
  fi

  if command -v termux-wake-lock >/dev/null 2>&1; then
    termux-wake-lock || true
  fi

  mkdir -p "$HOST_LOG_DIR"
  proot-distro login --detach "$CONTAINER" -- /usr/local/bin/ptero-runtime foreground

  local attempt
  for attempt in $(seq 1 30); do
    if guest /usr/local/bin/ptero-runtime healthy >/dev/null 2>&1; then
      printf '%s\n' "* Panel services started."
      guest /usr/local/bin/ptero-runtime status
      return
    fi
    sleep 1
  done

  guest /usr/local/bin/ptero-runtime status || true
  die "Panel services did not become healthy. Run: ptero-panel logs"
}

stop_panel() {
  need_container
  if [[ ${1:-} == --force ]]; then
    proot-distro kill "$CONTAINER"
    command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock || true
    printf '%s\n' "* Forced the PRoot session to stop."
    return
  fi

  if ! guest /usr/local/bin/ptero-runtime running >/dev/null 2>&1; then
    printf '%s\n' "* Panel services are not running."
    return
  fi

  guest /usr/local/bin/ptero-runtime stop || true
  local attempt
  for attempt in $(seq 1 20); do
    if ! guest /usr/local/bin/ptero-runtime running >/dev/null 2>&1; then
      command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock || true
      printf '%s\n' "* Panel services stopped."
      return
    fi
    sleep 1
  done

  die "Graceful shutdown timed out. Use 'ptero-panel stop --force' only if necessary."
}

enable_boot() {
  mkdir -p "$(dirname "$BOOT_FILE")" "$HOST_LOG_DIR"
  if [[ -e $BOOT_FILE ]] && ! grep -Fq "managed-by-pterodactyl-proot-v1" "$BOOT_FILE"; then
    die "Refusing to overwrite unmanaged boot file: $BOOT_FILE"
  fi

  cat >"$BOOT_FILE" <<'BOOT'
#!/data/data/com.termux/files/usr/bin/sh
# managed-by-pterodactyl-proot-v1
"$HOME/.local/bin/ptero-panel" start >>"$HOME/.local/state/pterodactyl-proot/boot.log" 2>&1
BOOT
  chmod 700 "$BOOT_FILE"
  printf '%s\n' "* Boot hook enabled."
  printf '%s\n' "* Install and open Termux:Boot once, then exempt Termux from Android battery optimization."
}

disable_boot() {
  if [[ ! -e $BOOT_FILE ]]; then
    printf '%s\n' "* Boot hook is not enabled."
    return
  fi
  grep -Fq "managed-by-pterodactyl-proot-v1" "$BOOT_FILE" ||
    die "Refusing to remove unmanaged boot file: $BOOT_FILE"
  rm -f "$BOOT_FILE"
  printf '%s\n' "* Boot hook disabled."
}

usage() {
  cat <<'USAGE'
Usage: ptero-panel COMMAND

Commands:
  start                 Start all Panel services in a detached PRoot session
  stop [--force]        Gracefully stop services, or explicitly kill the session
  restart               Restart all services
  status                Show service and HTTP health
  logs [service]        Show recent logs (add --follow to follow)
  shell                 Open a shell in the managed Ubuntu guest
  network               Change bind mode, port, and APP_URL
  doctor                Run diagnostics without printing secrets
  app-key               Display APP_KEY for secure backup
  boot enable|disable   Manage the optional Termux:Boot hook
USAGE
}

main() {
  local command=${1:-}
  case "$command" in
    start)
      start_panel
      ;;
    stop)
      stop_panel "${2:-}"
      ;;
    restart)
      stop_panel
      start_panel
      ;;
    status | logs | network | doctor | app-key)
      need_container
      shift
      guest /usr/local/bin/ptero-runtime "$command" "$@"
      ;;
    shell)
      need_container
      exec proot-distro login "$CONTAINER"
      ;;
    boot)
      case "${2:-}" in
        enable) enable_boot ;;
        disable) disable_boot ;;
        *) usage; exit 2 ;;
      esac
      ;;
    help | --help | -h | "")
      usage
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
CONTROLLER

  chmod 755 "$destination"
  success "Installed Termux controller at $destination"
}

termux_phase() {
  local cached_installer="$HOME/.local/share/pterodactyl-proot/install.sh"
  local arch
  local guest_exists=0

  [[ ${EUID:-1} -ne 0 ]] || die "Do not run the Termux phase as root."
  arch=$(normalize_arch "$(uname -m)") || die "Only ARM64 and x86_64 devices are supported."
  info "Detected Termux on $arch."
  warn_resources "$HOME"

  if ! command_exists pkg; then
    die "The Termux package manager was not found. Install a current Termux build from F-Droid or GitHub."
  fi

  local proot_default=no
  command_exists proot-distro && proot_default=yes
  if prompt_yes_no "Do you already have proot-distro installed in Termux?" "$proot_default"; then
    command_exists proot-distro ||
      die "You selected yes, but the 'proot-distro' command was not found. Rerun and select no so it can be installed."
    info "Using the existing proot-distro installation."
    pkg install -y curl
  else
    info "Installing proot-distro and Termux prerequisites..."
    pkg install -y curl proot-distro
  fi

  command_exists proot-distro || die "proot-distro installation failed."
  proot-distro install --help 2>&1 | grep -q 'IMAGE' ||
    die "This proot-distro is too old. Update Termux packages and rerun the installer."
  proot-distro login --help 2>&1 | grep -q -- '--detach' ||
    die "This proot-distro lacks detached sessions. Update Termux packages and rerun the installer."

  copy_self "$cached_installer"

  if proot-distro list -q 2>/dev/null | grep -Fxq "$CONTAINER_NAME"; then
    guest_exists=1
    if ! proot-distro login "$CONTAINER_NAME" -- sh -c \
      "grep -Fxq '$MANAGED_MARKER' '$MANAGED_FILE'" >/dev/null 2>&1; then
      die "A container named '$CONTAINER_NAME' already exists but is not owned by this installer. It will not be reset or overwritten."
    fi
    info "Reusing the existing managed container."

    if proot-distro login "$CONTAINER_NAME" -- /usr/local/bin/ptero-runtime running >/dev/null 2>&1; then
      info "Stopping the existing Panel runtime before resuming installation..."
      proot-distro login "$CONTAINER_NAME" -- /usr/local/bin/ptero-runtime stop || true
      local _
      for _ in $(seq 1 20); do
        if ! proot-distro login "$CONTAINER_NAME" -- /usr/local/bin/ptero-runtime running >/dev/null 2>&1; then
          break
        fi
        sleep 1
      done
      if proot-distro login "$CONTAINER_NAME" -- /usr/local/bin/ptero-runtime running >/dev/null 2>&1; then
        die "The existing runtime did not stop. Use 'ptero-panel stop --force' only after checking for active guest shells."
      fi
    fi
  fi

  if [[ $guest_exists == 0 ]]; then
    info "Creating the dedicated Ubuntu 24.04 PRoot guest..."
    proot-distro install "$CONTAINER_IMAGE" --name "$CONTAINER_NAME"
    proot-distro login "$CONTAINER_NAME" -- sh -c \
      "install -d -m 711 '$ETC_DIR' &&
       printf '%s\\n' '$MANAGED_MARKER' >'$MANAGED_FILE' &&
       chmod 600 '$MANAGED_FILE'"
  fi

  info "Entering the managed guest to install the Panel..."
  proot-distro login \
    --bind "$HOME/.local/share/pterodactyl-proot:/mnt/pterodactyl-installer" \
    "$CONTAINER_NAME" -- \
    env PTERO_INTERNAL_GUEST=1 bash /mnt/pterodactyl-installer/install.sh --guest

  write_termux_controller
  if [[ :$PATH: != *":$HOME/.local/bin:"* ]]; then
    warn "Add \$HOME/.local/bin to PATH to run 'ptero-panel' directly."
  fi

  "$HOME/.local/bin/ptero-panel" start
  printf '\n'
  success "Pterodactyl Panel installation completed."
  info "Use '$HOME/.local/bin/ptero-panel status' to check it."
}

setup_guest_logging() {
  mkdir -p "$ETC_DIR" "$STATE_DIR" "$INSTALL_STATE_DIR" "$LOG_DIR" "$RUN_DIR"
  # Service users must be able to traverse ETC_DIR to reach their own private
  # configuration files. Individual secret-bearing files remain mode 0600.
  chmod 711 "$ETC_DIR"
  chmod 700 "$STATE_DIR" "$INSTALL_STATE_DIR"
  touch "$INSTALL_LOG"
  chmod 600 "$INSTALL_LOG"
  INSTALL_LOG_ACTIVE=1
  info "Installation events are logged to $INSTALL_LOG."
}

load_guest_os() {
  [[ -r /etc/os-release ]] || die "Cannot identify the guest operating system."
  # shellcheck disable=SC1091
  source /etc/os-release
  GUEST_OS=${ID,,}
  GUEST_VERSION=${VERSION_ID//\"/}

  normalize_arch "$(uname -m)" >/dev/null ||
    die "Only ARM64 and x86_64 guests are supported."

  local platform_status=0
  select_guest_platform "$GUEST_OS" "$GUEST_VERSION" || platform_status=$?
  if [[ $platform_status != 0 ]]; then
    if [[ $platform_status == 26 ]]; then
      die "Ubuntu 26.04 ships PHP 8.5, which current Pterodactyl Panel releases do not support. Exit this guest and run install.sh from Termux so it can create the Ubuntu 24.04 guest."
    fi
    die "Unsupported guest: $GUEST_OS $GUEST_VERSION. Supported direct guests are Ubuntu 24.04, Debian 12, and Debian 13."
  fi

  info "Detected $GUEST_OS $GUEST_VERSION with PHP $PHP_VERSION."
}

create_management_marker() {
  if [[ -e $PANEL_DIR/.env && ! -f $MANAGED_FILE ]]; then
    die "An existing Panel installation was found at $PANEL_DIR. Refusing to overwrite it."
  fi

  if [[ -f $MANAGED_FILE ]] && ! grep -Fxq "$MANAGED_MARKER" "$MANAGED_FILE"; then
    die "An unrecognized management marker exists at $MANAGED_FILE."
  fi

  printf '%s\n' "$MANAGED_MARKER" >"$MANAGED_FILE"
  chmod 600 "$MANAGED_FILE"
}

stop_guest_runtime_for_install() {
  [[ -x $RUNTIME_BIN ]] || return 0
  if "$RUNTIME_BIN" running >/dev/null 2>&1; then
    info "Stopping the existing Panel runtime before resuming installation..."
    "$RUNTIME_BIN" stop || true
    local _
    for _ in $(seq 1 20); do
      "$RUNTIME_BIN" running >/dev/null 2>&1 || return 0
      sleep 1
    done
    die "The existing Panel runtime did not stop cleanly."
  fi
}

check_internal_ports() {
  local port
  for port in 3306 6379; do
    if port_in_use "$port"; then
      die "TCP port $port is already in use. The managed MariaDB and Redis services require ports 3306 and 6379 in PRoot's shared network namespace."
    fi
  done
}

setup_policy_rc() {
  if [[ -e $POLICY_BACKUP || -L $POLICY_BACKUP ]]; then
    warn "Recovering a preserved policy-rc.d from an interrupted installation."
    rm -f /usr/sbin/policy-rc.d
    mv "$POLICY_BACKUP" /usr/sbin/policy-rc.d
  fi

  POLICY_WAS_PRESENT=0
  if [[ -e /usr/sbin/policy-rc.d || -L /usr/sbin/policy-rc.d ]]; then
    cp -a /usr/sbin/policy-rc.d "$POLICY_BACKUP"
    rm -f /usr/sbin/policy-rc.d
    POLICY_WAS_PRESENT=1
  fi

  cat >/usr/sbin/policy-rc.d <<'POLICY'
#!/bin/sh
exit 101
POLICY
  chmod 755 /usr/sbin/policy-rc.d
  TEMP_POLICY_CREATED=1
}

install_debian13_php_repo() {
  local key_deb=/tmp/debsuryorg-archive-keyring.deb
  if [[ ! -f /usr/share/keyrings/debsuryorg-archive-keyring.gpg ]]; then
    curl -fsSL -o "$key_deb" https://packages.sury.org/debsuryorg-archive-keyring.deb
    dpkg -i "$key_deb"
    rm -f "$key_deb"
  fi

  printf '%s\n' \
    "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ trixie main" \
    >/etc/apt/sources.list.d/php-sury.list
}

install_dependencies() {
  if step_done dependencies; then
    info "Dependencies step already completed."
    return
  fi

  setup_policy_rc
  export DEBIAN_FRONTEND=noninteractive
  info "Updating package repositories..."
  apt-get update
  if [[ $GUEST_OS == ubuntu ]]; then
    apt-get install -y software-properties-common
    add-apt-repository -y universe
    apt-get update
  fi
  apt-get install -y \
    ca-certificates curl jq gnupg lsb-release openssl \
    nginx mariadb-server mariadb-client redis-server supervisor \
    unzip tar git procps iproute2 netcat-openbsd tzdata

  if [[ $GUEST_OS == debian && ${GUEST_VERSION%%.*} == 13 ]]; then
    install_debian13_php_repo
    apt-get update
  fi

  local php_packages=(
    "php$PHP_VERSION"
    "php$PHP_VERSION-cli"
    "php$PHP_VERSION-common"
    "php$PHP_VERSION-fpm"
    "php$PHP_VERSION-gd"
    "php$PHP_VERSION-mysql"
    "php$PHP_VERSION-mbstring"
    "php$PHP_VERSION-bcmath"
    "php$PHP_VERSION-xml"
    "php$PHP_VERSION-curl"
    "php$PHP_VERSION-zip"
  )
  apt-get install -y "${php_packages[@]}"

  php -r 'exit(version_compare(PHP_VERSION, "8.2.0", ">=") && version_compare(PHP_VERSION, "8.4.0", "<") ? 0 : 1);' ||
    die "Installed PHP $(php -r 'echo PHP_VERSION;') is outside Pterodactyl's supported 8.2/8.3 range."

  local required_extension
  for required_extension in curl dom gd mbstring openssl pdo_mysql posix tokenizer xml zip; do
    php -m | grep -Fxiq "$required_extension" ||
      die "Required PHP extension '$required_extension' is missing."
  done

  cleanup_policy_rc
  mark_step dependencies
  success "Dependencies installed."
}

install_composer() {
  if command_exists composer &&
    COMPOSER_ALLOW_SUPERUSER=1 composer --no-interaction --version 2>/dev/null |
      grep -q 'version 2'; then
    mark_step composer
    return
  fi

  local expected actual installer=/tmp/composer-setup.php
  info "Downloading and verifying Composer..."
  expected=$(curl -fsSL https://composer.github.io/installer.sig)
  curl -fsSL -o "$installer" https://getcomposer.org/installer
  actual=$(php -r "echo hash_file('sha384', '$installer');")
  [[ $actual == "$expected" ]] || die "Composer installer signature verification failed."
  php "$installer" --install-dir=/usr/local/bin --filename=composer --2
  rm -f "$installer"
  COMPOSER_ALLOW_SUPERUSER=1 composer --no-interaction --version |
    grep -q 'version 2' || die "Composer 2 installation failed."
  mark_step composer
}

prompt_default() {
  local prompt=$1
  local default=$2
  local result
  read -r -p "* $prompt [$default]: " result
  printf '%s\n' "${result:-$default}"
}

prompt_yes_no() {
  local prompt=$1
  local default=${2:-no}
  local result suffix
  if [[ $default == yes ]]; then
    suffix=Y/n
  else
    suffix=y/N
  fi
  read -r -p "* $prompt ($suffix): " result
  result=${result,,}
  if [[ -z $result ]]; then
    [[ $default == yes ]]
  else
    [[ $result == y || $result == yes ]]
  fi
}

prompt_network_values() {
  local choice=""
  local default_url
  local detected_ip=""

  while [[ $choice != 1 && $choice != 2 ]]; do
    printf '%s\n' "* Panel binding:"
    printf '%s\n' "  [1] Localhost only (safer; remote Wings cannot reach it)"
    printf '%s\n' "  [2] LAN (reachable from other devices on your network)"
    read -r -p "* Select [1]: " choice
    choice=${choice:-1}
  done

  if [[ $choice == 1 ]]; then
    PANEL_BIND=127.0.0.1
  else
    PANEL_BIND=0.0.0.0
  fi

  while true; do
    PANEL_PORT=$(prompt_default "Panel HTTP port" "${PANEL_PORT:-8080}")
    if ! validate_port "$PANEL_PORT"; then
      warn "Port must be an integer from 1024 through 65535."
      continue
    fi
    if [[ ${PTERO_ALLOWED_PORT:-} != "$PANEL_PORT" ]] && port_in_use "$PANEL_PORT"; then
      warn "Port $PANEL_PORT is already in use in the shared Android network namespace."
      continue
    fi
    break
  done

  if [[ $PANEL_BIND == 127.0.0.1 ]]; then
    default_url="http://127.0.0.1:$PANEL_PORT"
  else
    detected_ip=$(detect_lan_ip || true)
    if [[ -n $detected_ip ]]; then
      default_url="http://$detected_ip:$PANEL_PORT"
    else
      default_url=""
    fi
  fi

  while true; do
    PANEL_URL=$(prompt_default "Exact Panel URL, including the same port" "${PANEL_URL:-$default_url}")
    if validate_http_url "$PANEL_URL" "$PANEL_PORT"; then
      if [[ $PANEL_BIND == 0.0.0.0 && $PANEL_URL =~ ^http://(127\.0\.0\.1|localhost): ]]; then
        warn "LAN mode needs the phone's LAN IP address or a LAN-resolvable hostname."
        continue
      fi
      break
    fi
    warn "Use an exact URL such as http://192.168.1.10:$PANEL_PORT, with no path."
  done
}

save_install_config() {
  local temp="$INSTALL_CONFIG.tmp"
  umask 077
  {
    printf 'PANEL_BIND=%q\n' "$PANEL_BIND"
    printf 'PANEL_PORT=%q\n' "$PANEL_PORT"
    printf 'PANEL_URL=%q\n' "$PANEL_URL"
    printf 'TIMEZONE=%q\n' "$TIMEZONE"
    printf 'ADMIN_EMAIL=%q\n' "$ADMIN_EMAIL"
    printf 'ADMIN_USERNAME=%q\n' "$ADMIN_USERNAME"
    printf 'ADMIN_FIRST=%q\n' "$ADMIN_FIRST"
    printf 'ADMIN_LAST=%q\n' "$ADMIN_LAST"
    printf 'SERVICE_EMAIL=%q\n' "$SERVICE_EMAIL"
    printf 'TELEMETRY=%q\n' "$TELEMETRY"
    printf 'PHP_VERSION=%q\n' "$PHP_VERSION"
    printf 'DB_NAME=%q\n' "$DB_NAME"
    printf 'DB_USER=%q\n' "$DB_USER"
    printf 'DB_PASSWORD=%q\n' "$DB_PASSWORD"
    printf 'REDIS_PASSWORD=%q\n' "$REDIS_PASSWORD"
    printf 'PANEL_RELEASE=%q\n' "${PANEL_RELEASE:-}"
  } >"$temp"
  chmod 600 "$temp"
  mv "$temp" "$INSTALL_CONFIG"
}

load_install_config() {
  [[ -f $INSTALL_CONFIG ]] || return 1
  # The file is generated exclusively by save_install_config using shell-escaped values.
  # shellcheck disable=SC1090
  source "$INSTALL_CONFIG"
  return 0
}

collect_install_inputs() {
  if load_install_config; then
    info "Reusing the saved installation configuration."
    info "Panel URL: $PANEL_URL"
    info "Administrator: $ADMIN_EMAIL"
    mark_step inputs
    return
  fi

  prompt_network_values

  local detected_timezone=UTC
  if [[ -s /etc/timezone ]]; then
    detected_timezone=$(head -n 1 /etc/timezone)
  fi
  while true; do
    TIMEZONE=$(prompt_default "Panel timezone" "$detected_timezone")
    validate_timezone "$TIMEZONE" && break
    warn "That is not a timezone recognized by PHP."
  done

  while true; do
    ADMIN_EMAIL=$(prompt_default "Administrator email" "admin@example.com")
    validate_email "$ADMIN_EMAIL" && break
    warn "Enter a valid email address."
  done
  SERVICE_EMAIL=$ADMIN_EMAIL

  while true; do
    ADMIN_USERNAME=$(prompt_default "Administrator username" "admin")
    validate_username "$ADMIN_USERNAME" && break
    warn "Use 3-32 letters, numbers, dots, underscores, or hyphens."
  done

  ADMIN_FIRST=$(prompt_default "Administrator first name" "Panel")
  ADMIN_LAST=$(prompt_default "Administrator last name" "Admin")

  if prompt_yes_no "Enable anonymous Pterodactyl telemetry?" no; then
    TELEMETRY=true
  else
    TELEMETRY=false
  fi

  DB_NAME=panel
  DB_USER=pterodactyl
  DB_PASSWORD=$(generate_secret)
  REDIS_PASSWORD=$(generate_secret)
  PANEL_RELEASE=""
  save_install_config
  mark_step inputs
}

render_mariadb_config() {
  cat >"$ETC_DIR/mariadb.cnf" <<EOF
[client]
protocol=socket
socket=$MARIADB_RUN_DIR/mariadb.sock

[mysqld]
user=mysql
bind-address=127.0.0.1
port=3306
socket=$MARIADB_RUN_DIR/mariadb.sock
pid-file=$MARIADB_RUN_DIR/mariadb.pid
datadir=/var/lib/mysql
skip-name-resolve
skip-host-cache
innodb_use_native_aio=0
EOF
}

render_redis_config() {
  cat >"$ETC_DIR/redis.conf" <<EOF
bind 127.0.0.1
protected-mode yes
port 6379
daemonize no
supervised no
pidfile $REDIS_RUN_DIR/redis.pid
loglevel notice
logfile ""
dir /var/lib/redis
dbfilename dump.rdb
save 900 1
save 300 10
save 60 10000
requirepass $REDIS_PASSWORD
EOF
  chmod 600 "$ETC_DIR/redis.conf"
  chown redis:redis "$ETC_DIR/redis.conf" /var/lib/redis
}

render_php_config() {
  cat >"$ETC_DIR/php-fpm.conf" <<EOF
[global]
pid = $PHP_RUN_DIR/php-fpm.pid
error_log = $LOG_DIR/php-fpm-error.log
daemonize = no
include = $ETC_DIR/php-pool.conf
EOF

  cat >"$ETC_DIR/php-pool.conf" <<EOF
[pterodactyl]
user = www-data
group = www-data
listen = $PHP_RUN_DIR/php-fpm.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = 8
pm.process_idle_timeout = 15s
pm.max_requests = 500
clear_env = no
catch_workers_output = yes
php_admin_value[upload_max_filesize] = 100M
php_admin_value[post_max_size] = 100M
php_admin_value[memory_limit] = 256M
EOF
}

render_nginx_config_to() {
  local destination=$1
  cat >"$destination" <<EOF
user www-data;
worker_processes 1;
pid $NGINX_RUN_DIR/nginx.pid;
error_log $LOG_DIR/nginx-error.log warn;

events {
    worker_connections 512;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log $LOG_DIR/nginx-access.log;
    server_tokens off;
    sendfile off;
    client_body_temp_path /tmp/pterodactyl-client-body;
    proxy_temp_path /tmp/pterodactyl-proxy;
    fastcgi_temp_path /tmp/pterodactyl-fastcgi;

    server {
        listen $PANEL_BIND:$PANEL_PORT;
        server_name _;
        root $PANEL_DIR/public;
        index index.php;
        charset utf-8;
        client_max_body_size 100m;
        client_body_timeout 120s;

        location / {
            try_files \$uri \$uri/ /index.php?\$query_string;
        }

        location = /favicon.ico { access_log off; log_not_found off; }
        location = /robots.txt  { access_log off; log_not_found off; }

        location ~ \.php\$ {
            try_files \$uri =404;
            fastcgi_split_path_info ^(.+\.php)(/.+)\$;
            fastcgi_pass unix:$PHP_RUN_DIR/php-fpm.sock;
            fastcgi_index index.php;
            include /etc/nginx/fastcgi_params;
            fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
            fastcgi_param HTTP_PROXY "";
            fastcgi_intercept_errors off;
            fastcgi_connect_timeout 300;
            fastcgi_send_timeout 300;
            fastcgi_read_timeout 300;
        }

        location ~ /\. {
            deny all;
        }
    }
}
EOF
}

render_supervisor_config() {
  cat >"$ETC_DIR/supervisord.conf" <<EOF
[unix_http_server]
file=$RUN_DIR/supervisor.sock
chmod=0700

[supervisord]
logfile=$LOG_DIR/supervisord.log
logfile_maxbytes=10MB
logfile_backups=3
pidfile=$RUN_DIR/supervisord.pid
nodaemon=true
childlogdir=$LOG_DIR
minfds=1024

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix://$RUN_DIR/supervisor.sock

[program:mariadb]
command=/usr/sbin/mariadbd --defaults-file=$ETC_DIR/mariadb.cnf
priority=10
autostart=true
autorestart=true
startsecs=5
stopsignal=TERM
stopasgroup=true
killasgroup=true
stdout_logfile=$LOG_DIR/mariadb.log
stderr_logfile=$LOG_DIR/mariadb-error.log
stdout_logfile_maxbytes=10MB
stderr_logfile_maxbytes=10MB

[program:redis]
command=/usr/bin/redis-server $ETC_DIR/redis.conf
user=redis
priority=20
autostart=true
autorestart=true
startsecs=2
stopsignal=TERM
stopasgroup=true
killasgroup=true
stdout_logfile=$LOG_DIR/redis.log
stderr_logfile=$LOG_DIR/redis-error.log
stdout_logfile_maxbytes=10MB
stderr_logfile_maxbytes=10MB

[program:php-fpm]
command=/usr/sbin/php-fpm$PHP_VERSION --nodaemonize --fpm-config $ETC_DIR/php-fpm.conf
priority=30
autostart=true
autorestart=true
startsecs=2
stopsignal=QUIT
stopasgroup=true
killasgroup=true
stdout_logfile=$LOG_DIR/php-fpm.log
stderr_logfile=$LOG_DIR/php-fpm-error.log
stdout_logfile_maxbytes=10MB
stderr_logfile_maxbytes=10MB

[program:nginx]
command=/usr/sbin/nginx -c $ETC_DIR/nginx.conf -g "daemon off;"
priority=40
autostart=true
autorestart=true
startsecs=2
stopsignal=QUIT
stopasgroup=true
killasgroup=true
stdout_logfile=$LOG_DIR/nginx.log
stderr_logfile=$LOG_DIR/nginx-error.log
stdout_logfile_maxbytes=10MB
stderr_logfile_maxbytes=10MB

[program:queue]
command=/usr/bin/php $PANEL_DIR/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3 --no-interaction
directory=$PANEL_DIR
user=www-data
environment=HOME="$PANEL_DIR"
priority=50
autostart=true
autorestart=true
startsecs=2
stopsignal=TERM
stopasgroup=true
killasgroup=true
stdout_logfile=$LOG_DIR/queue.log
stderr_logfile=$LOG_DIR/queue-error.log
stdout_logfile_maxbytes=10MB
stderr_logfile_maxbytes=10MB

[program:scheduler]
command=/usr/bin/php $PANEL_DIR/artisan schedule:work --no-interaction
directory=$PANEL_DIR
user=www-data
environment=HOME="$PANEL_DIR"
priority=60
autostart=true
autorestart=true
startsecs=2
stopsignal=TERM
stopasgroup=true
killasgroup=true
stdout_logfile=$LOG_DIR/scheduler.log
stderr_logfile=$LOG_DIR/scheduler-error.log
stdout_logfile_maxbytes=10MB
stderr_logfile_maxbytes=10MB
EOF
}

write_runtime_script() {
  mkdir -p "$(dirname "$RUNTIME_BIN")"
  cat >"$RUNTIME_BIN" <<'RUNTIME'
#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

ETC_DIR=/etc/pterodactyl-proot
RUN_DIR=/run/pterodactyl-proot
MARIADB_RUN_DIR=$RUN_DIR/mariadb
REDIS_RUN_DIR=$RUN_DIR/redis
PHP_RUN_DIR=$RUN_DIR/php
NGINX_RUN_DIR=$RUN_DIR/nginx
LOG_DIR=/var/log/pterodactyl-proot
PANEL_DIR=/var/www/pterodactyl
CONFIG=$ETC_DIR/install.conf
SUPERVISOR_CONFIG=$ETC_DIR/supervisord.conf
INSTALLER=/usr/local/share/pterodactyl-proot/install.sh

die() {
  printf '%s\n' "* ERROR: $*" >&2
  exit 1
}

load_config() {
  [[ -f $CONFIG ]] || die "Missing $CONFIG"
  # shellcheck disable=SC1090
  source "$CONFIG"
}

prepare_runtime() {
  mkdir -p \
    "$RUN_DIR" "$MARIADB_RUN_DIR" "$REDIS_RUN_DIR" "$PHP_RUN_DIR" "$NGINX_RUN_DIR" \
    "$LOG_DIR" /tmp/pterodactyl-client-body /tmp/pterodactyl-proxy /tmp/pterodactyl-fastcgi
  chown mysql:mysql "$MARIADB_RUN_DIR"
  chown redis:redis "$REDIS_RUN_DIR"
  chown www-data:www-data "$PHP_RUN_DIR"
  chmod 755 "$RUN_DIR" "$NGINX_RUN_DIR"
  chmod 750 "$MARIADB_RUN_DIR" "$REDIS_RUN_DIR" "$PHP_RUN_DIR"
  rm -f "$RUN_DIR/supervisor.sock" "$RUN_DIR/supervisord.pid"
}

ctl() {
  supervisorctl -c "$SUPERVISOR_CONFIG" "$@"
}

running() {
  [[ -S $RUN_DIR/supervisor.sock ]] && ctl pid >/dev/null 2>&1
}

healthy() {
  load_config
  running || return 1
  ctl status 2>/dev/null |
    awk 'BEGIN {ok=1; count=0} {count++} $2 != "RUNNING" {ok=0} END {exit (ok && count >= 6) ? 0 : 1}' ||
    return 1
  curl -fsS --max-time 5 "$PANEL_URL" >/dev/null
}

show_status() {
  load_config
  printf '%s\n' "* Panel URL: $PANEL_URL"
  if ! running; then
    printf '%s\n' "* Runtime: stopped"
    return 1
  fi
  printf '%s\n' "* Runtime: running"
  ctl status || true
  if curl -fsS --max-time 5 "$PANEL_URL" >/dev/null; then
    printf '%s\n' "* HTTP health: OK"
  else
    printf '%s\n' "* HTTP health: FAILED"
    return 1
  fi
}

show_logs() {
  local service=${1:-}
  local follow=${2:-}
  local files=()
  if [[ -n $service && $service != --follow ]]; then
    [[ $service =~ ^[a-z0-9-]+$ ]] || die "Invalid service name."
    files=("$LOG_DIR/$service.log" "$LOG_DIR/$service-error.log")
  else
    follow=${service:-$follow}
    files=("$LOG_DIR"/*.log)
  fi

  local existing=()
  local file
  for file in "${files[@]}"; do
    [[ -f $file ]] && existing+=("$file")
  done
  ((${#existing[@]} > 0)) || die "No matching log files exist yet."

  if [[ $follow == --follow ]]; then
    tail -n 100 -F "${existing[@]}"
  else
    tail -n 100 "${existing[@]}"
  fi
}

doctor() {
  load_config
  local failed=0
  printf '%s\n' "* Guest: $(. /etc/os-release; printf '%s %s' "$ID" "$VERSION_ID")"
  printf '%s\n' "* Architecture: $(uname -m)"
  printf '%s\n' "* PHP: $(php -r 'echo PHP_VERSION;')"
  printf '%s\n' "* Storage:"
  df -h "$PANEL_DIR" | tail -n 1
  nginx -t -c "$ETC_DIR/nginx.conf" || failed=1
  php -m | grep -Fxiq pdo_mysql || { printf '%s\n' "* Missing pdo_mysql"; failed=1; }
  if running; then
    ctl status || failed=1
  else
    printf '%s\n' "* Runtime is stopped."
    failed=1
  fi
  curl -fsS --max-time 5 "$PANEL_URL" >/dev/null ||
    { printf '%s\n' "* Panel HTTP check failed: $PANEL_URL"; failed=1; }
  return "$failed"
}

app_key() {
  local value
  value=$(grep -m1 '^APP_KEY=' "$PANEL_DIR/.env" || true)
  [[ -n $value ]] || die "APP_KEY is not configured."
  printf '%s\n' "$value"
  printf '%s\n' "* Store this in a password manager or encrypted backup. Never share it."
}

usage() {
  printf '%s\n' "Usage: ptero-runtime {foreground|stop|running|healthy|status|logs|network|doctor|app-key}"
}

main() {
  case "${1:-}" in
    foreground)
      load_config
      running && die "Runtime is already running."
      prepare_runtime
      exec supervisord -n -c "$SUPERVISOR_CONFIG"
      ;;
    stop)
      running || exit 0
      ctl shutdown
      ;;
    running)
      running
      ;;
    healthy)
      healthy
      ;;
    status)
      show_status
      ;;
    logs)
      shift
      show_logs "$@"
      ;;
    network)
      exec env PTERO_INTERNAL_GUEST=1 bash "$INSTALLER" --network
      ;;
    doctor)
      doctor
      ;;
    app-key)
      app_key
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
RUNTIME
  chmod 755 "$RUNTIME_BIN"
}

prepare_service_directories() {
  mkdir -p \
    "$RUN_DIR" "$MARIADB_RUN_DIR" "$REDIS_RUN_DIR" "$PHP_RUN_DIR" "$NGINX_RUN_DIR" \
    "$LOG_DIR" /var/lib/mysql /var/lib/redis \
    /tmp/pterodactyl-client-body /tmp/pterodactyl-proxy /tmp/pterodactyl-fastcgi
  chown -R mysql:mysql /var/lib/mysql
  chown -R redis:redis /var/lib/redis
  chown mysql:mysql "$MARIADB_RUN_DIR"
  chown redis:redis "$REDIS_RUN_DIR"
  chown www-data:www-data "$PHP_RUN_DIR"
  chown -R www-data:www-data \
    /tmp/pterodactyl-client-body /tmp/pterodactyl-proxy /tmp/pterodactyl-fastcgi
  chmod 755 "$RUN_DIR" "$NGINX_RUN_DIR" "$LOG_DIR"
  chmod 750 "$MARIADB_RUN_DIR" "$REDIS_RUN_DIR" "$PHP_RUN_DIR"

  if [[ ! -d /var/lib/mysql/mysql ]]; then
    info "Initializing MariaDB data files..."
    mariadb-install-db --user=mysql --datadir=/var/lib/mysql --skip-test-db
  fi
}

render_configs() {
  load_install_config || die "Installation configuration is missing."
  prepare_service_directories
  render_mariadb_config
  render_redis_config
  render_php_config
  render_nginx_config_to "$ETC_DIR/nginx.conf"
  render_supervisor_config
  write_runtime_script
  chmod 600 "$ETC_DIR"/*.conf
  mark_step configs
}

sha256_file() {
  local file=$1
  if command_exists sha256sum; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

verify_release_digest() {
  local file=$1
  local digest=$2
  local expected=${digest#sha256:}
  local actual
  [[ $digest == sha256:* && ${#expected} == 64 ]] || return 1
  actual=$(sha256_file "$file")
  [[ $actual == "$expected" ]]
}

download_panel() {
  if [[ -f $PANEL_DIR/artisan && -f $PANEL_DIR/composer.json ]]; then
    info "Panel files already exist; preserving them."
    mark_step panel_download
    return
  fi

  local metadata=/tmp/pterodactyl-release.json
  local archive=/tmp/pterodactyl-panel.tar.gz
  local tag url digest

  info "Resolving the latest stable Pterodactyl Panel release..."
  curl -fsSL -H 'Accept: application/vnd.github+json' -o "$metadata" "$OFFICIAL_PANEL_API"
  jq -e '.draft == false and .prerelease == false' "$metadata" >/dev/null ||
    die "GitHub returned a draft or prerelease instead of a stable Panel release."
  tag=$(jq -er '.tag_name' "$metadata")
  url=$(jq -er '.assets[] | select(.name == "panel.tar.gz") | .browser_download_url' "$metadata")
  digest=$(jq -er '.assets[] | select(.name == "panel.tar.gz") | .digest' "$metadata")

  info "Downloading Pterodactyl Panel $tag..."
  curl -fL --retry 3 -o "$archive" "$url"
  verify_release_digest "$archive" "$digest" ||
    die "The Panel archive SHA-256 digest does not match GitHub release metadata."

  mkdir -p "$PANEL_DIR"
  tar -xzf "$archive" -C "$PANEL_DIR"
  rm -f "$archive" "$metadata"
  [[ -f $PANEL_DIR/artisan && -f $PANEL_DIR/composer.json ]] ||
    die "The downloaded Panel archive is incomplete."

  PANEL_RELEASE=$tag
  save_install_config
  mark_step panel_download
}

install_panel_dependencies() {
  info "Installing Panel Composer dependencies..."
  (
    cd "$PANEL_DIR"
    [[ -f .env ]] || cp .env.example .env
    COMPOSER_ALLOW_SUPERUSER=1 composer install \
      --no-dev --optimize-autoloader --no-interaction --no-progress
  )
  mark_step panel_dependencies
}

start_bootstrap_services() {
  stop_bootstrap_services
  rm -f \
    "$MARIADB_RUN_DIR/mariadb.sock" "$MARIADB_RUN_DIR/mariadb.pid" \
    "$REDIS_RUN_DIR/redis.pid"

  /usr/sbin/mariadbd --defaults-file="$ETC_DIR/mariadb.cnf" \
    >"$LOG_DIR/mariadb-bootstrap.log" 2>&1 &
  BOOTSTRAP_MARIADB_PID=$!

  # Match the long-running Supervisor identity so bootstrap shutdown cannot
  # leave root-owned Redis persistence files behind.
  runuser -u redis -- /usr/bin/redis-server "$ETC_DIR/redis.conf" \
    >"$LOG_DIR/redis-bootstrap.log" 2>&1 &
  BOOTSTRAP_REDIS_PID=$!

  local _
  for _ in $(seq 1 60); do
    if mariadb-admin --protocol=socket --socket="$MARIADB_RUN_DIR/mariadb.sock" ping >/dev/null 2>&1 &&
      redis-cli -h 127.0.0.1 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning ping 2>/dev/null | grep -Fxq PONG; then
      return
    fi
    sleep 1
  done

  tail -n 50 "$LOG_DIR/mariadb-bootstrap.log" "$LOG_DIR/redis-bootstrap.log" 2>/dev/null || true
  die "MariaDB and Redis did not become ready."
}

configure_database() {
  info "Ensuring the Panel database and restricted database user exist..."
  mariadb --protocol=socket --socket="$MARIADB_RUN_DIR/mariadb.sock" <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD';
ALTER USER '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
  mark_step database
}

env_value() {
  local key=$1
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$PANEL_DIR/.env"
}

configure_panel() (
  local app_key
  cd "$PANEL_DIR"

  app_key=$(env_value APP_KEY)
  if [[ -z $app_key ]]; then
    php artisan key:generate --force --no-interaction
  fi

  php artisan p:environment:setup \
    --author="$SERVICE_EMAIL" \
    --url="$PANEL_URL" \
    --timezone="$TIMEZONE" \
    --cache=redis \
    --session=redis \
    --queue=redis \
    --redis-host=127.0.0.1 \
    --redis-pass="$REDIS_PASSWORD" \
    --redis-port=6379 \
    --settings-ui=true \
    --telemetry="$TELEMETRY"

  php artisan p:environment:database \
    --host=127.0.0.1 \
    --port=3306 \
    --database="$DB_NAME" \
    --username="$DB_USER" \
    --password="$DB_PASSWORD"

  php artisan migrate --seed --force --no-interaction
  mark_step panel_config
)

prompt_admin_password() {
  local first second
  while true; do
    read -r -s -p "* Administrator password: " first
    printf '\n'
    if ! validate_admin_password "$first"; then
      warn "Use at least 8 characters with uppercase, lowercase, and a number."
      continue
    fi
    read -r -s -p "* Confirm administrator password: " second
    printf '\n'
    [[ $first == "$second" ]] || {
      warn "Passwords did not match."
      continue
    }
    ADMIN_PASSWORD=$first
    return
  done
}

create_admin() {
  local existing
  existing=$(mariadb \
    --protocol=tcp -h 127.0.0.1 -P 3306 \
    -u "$DB_USER" "-p$DB_PASSWORD" "$DB_NAME" -Nse \
    "SELECT COUNT(*) FROM users WHERE email = '$ADMIN_EMAIL';")
  if [[ $existing != 0 ]]; then
    info "Administrator $ADMIN_EMAIL already exists; preserving it."
    mark_step admin
    return
  fi

  prompt_admin_password
  (
    cd "$PANEL_DIR"
    php artisan p:user:make \
      --email="$ADMIN_EMAIL" \
      --username="$ADMIN_USERNAME" \
      --name-first="$ADMIN_FIRST" \
      --name-last="$ADMIN_LAST" \
      --password="$ADMIN_PASSWORD" \
      --admin=1
  )
  unset ADMIN_PASSWORD
  mark_step admin
}

finalize_guest() {
  chown -R www-data:www-data "$PANEL_DIR"
  chmod -R u=rwX,g=rX,o= "$PANEL_DIR"
  chmod -R ug=rwX "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache"
  copy_self "$GUEST_INSTALLER"
  nginx -t -c "$ETC_DIR/nginx.conf"
  mark_step complete

  printf '\n'
  success "Guest installation is complete."
  info "Panel URL: $PANEL_URL"
  info "Wings was not installed because PRoot cannot provide Docker, cgroups, or namespaces."
  info "For a remote Wings host:"
  info "  1. Make this Panel URL reachable from that real Docker-capable Linux host."
  info "  2. In the Panel admin area, create a Location, Node, and Allocations."
  info "  3. Open the Node Configuration tab and transfer config.yml or use Generate Token."
  info "  4. Follow https://pterodactyl.io/wings/1.0/installing.html on the remote host."
  if [[ ${PTERO_INTERNAL_GUEST:-0} == 1 ]]; then
    info "Back up APP_KEY after startup with: ptero-panel app-key"
  else
    info "Keep services running with: /usr/local/bin/ptero-runtime foreground"
    info "Back up APP_KEY with: /usr/local/bin/ptero-runtime app-key"
  fi
}

guest_phase() {
  [[ ${EUID:-1} -eq 0 ]] || die "Run the guest installation as the PRoot root user."
  setup_guest_logging
  trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
  trap cleanup_guest EXIT

  load_guest_os
  warn_resources /
  create_management_marker
  stop_guest_runtime_for_install
  install_dependencies
  check_internal_ports
  install_composer
  collect_install_inputs
  render_configs
  download_panel
  install_panel_dependencies

  start_bootstrap_services
  configure_database
  configure_panel
  create_admin
  stop_bootstrap_services
  finalize_guest
}

update_env_url() {
  local temp="$PANEL_DIR/.env.tmp"
  awk -v replacement="APP_URL=$PANEL_URL" '
    BEGIN {done=0}
    /^APP_URL=/ {print replacement; done=1; next}
    {print}
    END {if (!done) print replacement}
  ' "$PANEL_DIR/.env" >"$temp"
  chown www-data:www-data "$temp"
  chmod 640 "$temp"
  mv "$temp" "$PANEL_DIR/.env"
}

apply_network_change() {
  local candidate=$1
  mv "$candidate" "$ETC_DIR/nginx.conf" || return 1
  save_install_config || return 1
  update_env_url || return 1
  (
    cd "$PANEL_DIR" || exit 1
    php artisan config:clear --no-interaction
  ) || return 1

  if [[ -S $RUN_DIR/supervisor.sock ]]; then
    supervisorctl -c "$ETC_DIR/supervisord.conf" restart nginx || return 1
  fi
}

network_phase() {
  [[ ${EUID:-1} -eq 0 ]] || die "Run network reconfiguration as the PRoot root user."
  load_guest_os
  load_install_config || die "No managed installation configuration was found."
  assert_managed_guest

  local old_bind=$PANEL_BIND
  local old_port=$PANEL_PORT
  local old_url=$PANEL_URL
  local candidate="$ETC_DIR/nginx.conf.new"
  local backup_dir
  local runtime_was_running=0

  backup_dir=$(mktemp -d)
  cp "$ETC_DIR/nginx.conf" "$backup_dir/nginx.conf"
  cp "$INSTALL_CONFIG" "$backup_dir/install.conf"
  cp "$PANEL_DIR/.env" "$backup_dir/panel.env"
  [[ -S $RUN_DIR/supervisor.sock ]] && runtime_was_running=1

  PTERO_ALLOWED_PORT=$old_port
  prompt_network_values
  unset PTERO_ALLOWED_PORT
  render_nginx_config_to "$candidate"
  nginx -t -c "$candidate" || {
    rm -f "$candidate"
    PANEL_BIND=$old_bind
    PANEL_PORT=$old_port
    PANEL_URL=$old_url
    rm -rf "$backup_dir"
    die "The new Nginx configuration failed validation; no changes were applied."
  }

  if ! apply_network_change "$candidate"; then
    warn "Network reconfiguration failed; restoring the previous configuration."
    PANEL_BIND=$old_bind
    PANEL_PORT=$old_port
    PANEL_URL=$old_url
    cp "$backup_dir/nginx.conf" "$ETC_DIR/nginx.conf"
    cp "$backup_dir/install.conf" "$INSTALL_CONFIG"
    cp "$backup_dir/panel.env" "$PANEL_DIR/.env"
    if [[ $runtime_was_running == 1 ]]; then
      supervisorctl -c "$ETC_DIR/supervisord.conf" restart nginx || true
    fi
    rm -rf "$backup_dir"
    die "The previous network configuration was restored."
  fi
  rm -rf "$backup_dir"
  success "Panel network configuration updated to $PANEL_URL."
}

usage() {
  cat <<'USAGE'
Usage: bash install.sh

Run from current Termux to create a managed Ubuntu 24.04 PRoot guest, or run
inside an existing Ubuntu 24.04, Debian 12, or Debian 13 PRoot guest.
USAGE
}

main() {
  local mode
  case "${1:-}" in
    --help | -h)
      usage
      return
      ;;
  esac

  info "Starting the Pterodactyl PRoot installer..."
  mode=$(detect_mode)
  info "Launch environment: $mode."
  if [[ ${1:-} == --network ]]; then
    [[ $mode == guest ]] || die "Network reconfiguration must run inside the managed guest."
    network_phase
    return
  fi

  case "$mode" in
    termux)
      termux_phase
      ;;
    guest)
      guest_phase
      ;;
    *)
      die "Run this installer from Termux or inside a supported Debian/Ubuntu PRoot guest."
      ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
elif [[ ${PTERO_INSTALLER_LIBRARY_MODE:-0} != 1 ]]; then
  warn "install.sh was sourced, so installation did not start. Run it with: bash install.sh"
fi

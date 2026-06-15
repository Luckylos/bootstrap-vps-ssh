#!/usr/bin/env bash
set -Eeuo pipefail

HOME=${HOME:-/root}
TARGET_USER="root"
ROOT_HOME="/root"
SSH_PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICbs++si36y/pN/dKDG5qA/l/K8hEAgvlntcI9koaFzt'
ROOT_LOGIN_MODE='prohibit-password'
AUTHORIZED_KEYS_PATH="${AUTHORIZED_KEYS_PATH:-$ROOT_HOME/.ssh/authorized_keys}"
SSH_DIR="$(dirname "$AUTHORIZED_KEYS_PATH")"
SSHD_CONFIG_PATH="${SSHD_CONFIG_PATH:-/etc/ssh/sshd_config}"
PUBLIC_IP_OVERRIDE="${PUBLIC_IP_OVERRIDE:-}"
SSH_PORT_OVERRIDE="${SSH_PORT_OVERRIDE:-}"
SKIP_SSHD_REPAIR="${SKIP_SSHD_REPAIR:-0}"
SKIP_SSHD_RELOAD="${SKIP_SSHD_RELOAD:-0}"
MANAGED_BEGIN="# BEGIN bootstrap-vps-ssh"
MANAGED_END="# END bootstrap-vps-ssh"

PUBLIC_IP=""
SSH_PORT=""
CONFIG_CHANGED=0
TEMP_ITEMS=()

err() {
  printf 'ERROR: %s\n' "$*" >&2
}

register_temp() {
  TEMP_ITEMS+=("$1")
}

cleanup() {
  local item
  for item in "${TEMP_ITEMS[@]}"; do
    [[ -n "$item" ]] || continue
    rm -rf -- "$item" 2>/dev/null || true
  done
}

trap cleanup EXIT

expect_no_args() {
  if [[ "$#" -ne 0 ]]; then
    err "no arguments supported"
    exit 1
  fi
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    err "must run as root"
    exit 1
  fi
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "missing command: $cmd"
    exit 1
  fi
}

ensure_requirements() {
  local cmd
  for cmd in awk grep sed curl getent chmod chown mkdir touch install stat dirname; do
    require_command "$cmd"
  done

  if ! command -v ss >/dev/null 2>&1 && ! command -v sshd >/dev/null 2>&1; then
    err "missing both ss and sshd; cannot detect ssh port"
    exit 1
  fi

  if [[ "$SKIP_SSHD_REPAIR" != "1" ]]; then
    require_command sshd
  fi
}

validate_pubkey() {
  if [[ ! "$SSH_PUBKEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-[[:alnum:]-]+)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]]; then
    err "invalid SSH public key format"
    exit 1
  fi
}

validate_ipv4() {
  local ip="$1"
  local IFS=.
  local octets
  read -r -a octets <<< "$ip"
  [[ "${#octets[@]}" -eq 4 ]] || return 1

  local octet
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    ((octet >= 0 && octet <= 255)) || return 1
  done
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  ((port >= 1 && port <= 65535))
}

detect_public_ip() {
  local candidate service

  if [[ -n "$PUBLIC_IP_OVERRIDE" ]]; then
    if ! validate_ipv4 "$PUBLIC_IP_OVERRIDE"; then
      err "PUBLIC_IP_OVERRIDE is not a valid IPv4 address"
      exit 1
    fi
    PUBLIC_IP="$PUBLIC_IP_OVERRIDE"
    return 0
  fi

  for service in \
    "https://api.ipify.org" \
    "https://ipv4.icanhazip.com" \
    "https://ifconfig.me/ip"; do
    candidate="$(curl -4fsS --max-time 8 "$service" 2>/dev/null | tr -d '[:space:]' || true)"
    if validate_ipv4 "$candidate"; then
      PUBLIC_IP="$candidate"
      return 0
    fi
  done

  err "failed to detect public IPv4; set PUBLIC_IP_OVERRIDE if outbound IP lookup is blocked"
  exit 1
}

get_effective_sshd_config() {
  local host_value
  host_value="$(hostname 2>/dev/null || printf 'localhost')"
  sshd -T -f "$SSHD_CONFIG_PATH" -C "user=$TARGET_USER,host=$host_value,addr=127.0.0.1" 2>/dev/null || true
}

detect_ssh_port() {
  local candidate

  if [[ -n "$SSH_PORT_OVERRIDE" ]]; then
    if ! validate_port "$SSH_PORT_OVERRIDE"; then
      err "SSH_PORT_OVERRIDE is not a valid TCP port"
      exit 1
    fi
    SSH_PORT="$SSH_PORT_OVERRIDE"
    return 0
  fi

  if command -v ss >/dev/null 2>&1; then
    candidate="$(ss -H -tlnp 2>/dev/null | awk '/sshd/ {print $4; exit}' | sed -E 's/.*:([0-9]+)$/\1/' || true)"
    if validate_port "$candidate"; then
      SSH_PORT="$candidate"
      return 0
    fi
  fi

  candidate="$(get_effective_sshd_config | awk '$1=="port" {print $2; exit}' || true)"
  if validate_port "$candidate"; then
    SSH_PORT="$candidate"
    return 0
  fi

  if [[ -f "$SSHD_CONFIG_PATH" ]]; then
    candidate="$(awk '
      BEGIN{port=""}
      /^[[:space:]]*#/ {next}
      /^[[:space:]]*Match[[:space:]]/ {exit}
      tolower($1)=="port" {port=$2}
      END{print port}
    ' "$SSHD_CONFIG_PATH")"
    if validate_port "$candidate"; then
      SSH_PORT="$candidate"
      return 0
    fi
  fi

  SSH_PORT="22"
}

ensure_ssh_dir() {
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  touch "$AUTHORIZED_KEYS_PATH"
  chmod 600 "$AUTHORIZED_KEYS_PATH"
  chown -R "$TARGET_USER:$TARGET_USER" "$SSH_DIR"
}

append_pubkey_if_missing() {
  if grep -qxF "$SSH_PUBKEY" "$AUTHORIZED_KEYS_PATH" 2>/dev/null; then
    return 0
  fi

  printf '%s\n' "$SSH_PUBKEY" >> "$AUTHORIZED_KEYS_PATH"
  chmod 600 "$AUTHORIZED_KEYS_PATH"
  chown "$TARGET_USER:$TARGET_USER" "$AUTHORIZED_KEYS_PATH"
}

emit_managed_block() {
  printf '%s\n' "$MANAGED_BEGIN"
  printf '%s\n' 'PubkeyAuthentication yes'
  printf '%s\n' 'AuthorizedKeysFile .ssh/authorized_keys'
  printf 'PermitRootLogin %s\n' "$ROOT_LOGIN_MODE"
  printf '%s\n' "$MANAGED_END"
}

rebuild_sshd_config() {
  local cleaned_file="$1"
  local output_file="$2"
  local block_file="$3"

  awk -v block="$block_file" '
    BEGIN {inserted=0}
    !inserted && /^[[:space:]]*Match[[:space:]]/ {
      while ((getline line < block) > 0) print line
      close(block)
      print ""
      inserted=1
    }
    {print}
    END {
      if (!inserted) {
        if (NR > 0) print ""
        while ((getline line < block) > 0) print line
        close(block)
      }
    }
  ' "$cleaned_file" > "$output_file"
}

repair_sshd_if_needed() {
  local resolved current_pubkey current_authkeys current_root need_fix
  local tmp_clean tmp_final tmp_block mode owner group

  [[ "$SKIP_SSHD_REPAIR" == "1" ]] && return 0

  if [[ ! -f "$SSHD_CONFIG_PATH" ]]; then
    err "sshd config not found: $SSHD_CONFIG_PATH"
    exit 1
  fi

  need_fix=0
  resolved="$(get_effective_sshd_config)"
  if [[ -z "$resolved" ]]; then
    need_fix=1
  else
    current_pubkey="$(awk '$1=="pubkeyauthentication" {print $2; exit}' <<< "$resolved")"
    current_authkeys="$(awk '$1=="authorizedkeysfile" {print $2; exit}' <<< "$resolved")"
    current_root="$(awk '$1=="permitrootlogin" {print $2; exit}' <<< "$resolved")"

    [[ "$current_pubkey" == "yes" ]] || need_fix=1
    [[ "$current_authkeys" == *'.ssh/authorized_keys'* ]] || need_fix=1
    case "$current_root" in
      yes|prohibit-password|without-password) ;;
      *) need_fix=1 ;;
    esac
  fi

  [[ "$need_fix" -eq 0 ]] && return 0

  tmp_clean="$(mktemp)"
  tmp_final="$(mktemp)"
  tmp_block="$(mktemp)"
  register_temp "$tmp_clean"
  register_temp "$tmp_final"
  register_temp "$tmp_block"

  emit_managed_block > "$tmp_block"

  awk -v begin="$MANAGED_BEGIN" -v end="$MANAGED_END" '
    $0 == begin {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' "$SSHD_CONFIG_PATH" > "$tmp_clean"

  rebuild_sshd_config "$tmp_clean" "$tmp_final" "$tmp_block"

  if ! sshd -t -f "$tmp_final" >/dev/null 2>&1; then
    err "sshd config validation failed after managed block update"
    exit 1
  fi

  mode="$(stat -c '%a' "$SSHD_CONFIG_PATH")"
  owner="$(stat -c '%u' "$SSHD_CONFIG_PATH")"
  group="$(stat -c '%g' "$SSHD_CONFIG_PATH")"
  install -o "$owner" -g "$group" -m "$mode" "$tmp_final" "$SSHD_CONFIG_PATH"
  CONFIG_CHANGED=1
}

reload_sshd_if_needed() {
  local unit

  [[ "$CONFIG_CHANGED" -eq 1 ]] || return 0
  [[ "$SKIP_SSHD_RELOAD" == "1" ]] && return 0

  if command -v systemctl >/dev/null 2>&1; then
    for unit in sshd ssh; do
      if systemctl status "$unit" >/dev/null 2>&1; then
        systemctl reload "$unit" >/dev/null 2>&1 && return 0
        systemctl restart "$unit" >/dev/null 2>&1 && return 0
      fi
    done
  fi

  if command -v service >/dev/null 2>&1; then
    for unit in sshd ssh; do
      service "$unit" reload >/dev/null 2>&1 && return 0
      service "$unit" restart >/dev/null 2>&1 && return 0
    done
  fi

  err "updated sshd config but failed to reload/restart ssh service"
  exit 1
}

print_result() {
  printf 'SSH_IP=%s\n' "$PUBLIC_IP"
  printf 'SSH_PORT=%s\n' "$SSH_PORT"
}

main() {
  expect_no_args "$@"
  require_root
  ensure_requirements
  validate_pubkey
  detect_public_ip
  detect_ssh_port
  ensure_ssh_dir
  append_pubkey_if_missing
  repair_sshd_if_needed
  reload_sshd_if_needed
  print_result
}

if [[ "${BASH_SOURCE[0]-}" == "$0" || -z "${BASH_SOURCE[0]-}" ]]; then
  main "$@"
fi

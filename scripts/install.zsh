#!/bin/zsh -f

emulate -L zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
umask 077

readonly LABEL="io.github.hosamajjf.utm-bridge-fdb-guard"
readonly LEGACY_LABEL="com.hosamajjf.utm-bridge-fdb-guard"
readonly TARGET_ROOT="/Library/Application Support/UTMBridgeFDBGuard"
readonly TARGET_BIN_DIR="${TARGET_ROOT}/bin"
readonly TARGET_BIN="${TARGET_BIN_DIR}/utm-bridge-fdb-guard"
readonly TARGET_CONFIG="${TARGET_ROOT}/config.plist"
readonly TARGET_VERSION="${TARGET_ROOT}/VERSION"
readonly TARGET_MANIFEST="${TARGET_ROOT}/install-manifest.txt"
readonly TARGET_LOCK="${TARGET_ROOT}/run.lock"
readonly TARGET_PLIST="/Library/LaunchDaemons/${LABEL}.plist"

readonly SOURCE_ROOT="${0:A:h:h}"
readonly SOURCE_BIN="${SOURCE_ROOT}/bin/utm-bridge-fdb-guard"
readonly SOURCE_PLIST="${SOURCE_ROOT}/launchd/${LABEL}.plist"
readonly SOURCE_VERSION="${SOURCE_ROOT}/VERSION"

typeset requested_uplink=""
typeset requested_bridge="auto"
typeset -a requested_guest_macs
typeset assume_yes=0
typeset upgrade=0
typeset reconfigure=0
typeset install_dry_run=0
typeset configuration_requested=0

usage() {
  print "Usage: sudo ./scripts/install.zsh [options]"
  print ""
  print "Options:"
  print "  --uplink IFACE       Physical uplink (default: current default route interface)"
  print "  --bridge auto|NAME   Auto-discover or pin one bridge (default: auto)"
  print "  --guest-mac MAC      Pin accepted guest MAC; may be repeated"
  print "  --dry-run            Install with deletion disabled in config"
  print "  --upgrade            Replace an existing installation of this package"
  print "  --reconfigure        Replace the existing config during --upgrade"
  print "  --yes                Do not prompt after the read-only scan"
}

fail() {
  print -u2 -- "install.zsh: $*"
  exit 1
}

valid_interface_name() {
  [[ "$1" =~ '^[A-Za-z][A-Za-z0-9._-]*$' ]]
}

valid_bridge_name() {
  [[ "$1" =~ '^bridge[0-9]+$' ]]
}

root_owned_not_group_other_writable() {
  local path="$1"
  local owner mode mode_value mode_token
  owner="$(/usr/bin/stat -f '%Su:%Sg' "${path}" 2>/dev/null)" || return 1
  mode="$(/usr/bin/stat -f '%Lp' "${path}" 2>/dev/null)" || return 1
  [[ "${owner}" == "root:wheel" && "${mode}" =~ '^[0-7]{3,4}$' ]] || return 1
  mode_value=$(( 8#${mode} ))
  (( (mode_value & 8#022) == 0 )) || return 1
  mode_token="$(/bin/ls -lde "${path}" 2>/dev/null | /usr/bin/awk 'NR == 1 { print $1; exit }')" || return 1
  [[ -n "${mode_token}" && "${mode_token}" != *+* ]]
}

normalize_mac() {
  local raw="${1:l}"
  local -a parts
  local part formatted output=""
  local value
  parts=("${(@s.:.)raw}")
  (( ${#parts} == 6 )) || return 1
  for part in "${parts[@]}"; do
    [[ "${part}" =~ '^[0-9a-f]{1,2}$' ]] || return 1
    value=$(( 16#${part} ))
    printf -v formatted '%02x' "${value}"
    [[ -n "${output}" ]] && output+=":"
    output+="${formatted}"
  done
  REPLY="${output}"
}

while (( $# > 0 )); do
  case "$1" in
    --uplink)
      (( $# >= 2 )) || fail "--uplink requires an interface"
      requested_uplink="$2"
      configuration_requested=1
      shift 2
      ;;
    --bridge)
      (( $# >= 2 )) || fail "--bridge requires auto or bridgeN"
      requested_bridge="$2"
      configuration_requested=1
      shift 2
      ;;
    --guest-mac)
      (( $# >= 2 )) || fail "--guest-mac requires a MAC address"
      normalize_mac "$2" || fail "invalid guest MAC: $2"
      requested_guest_macs+=("${REPLY}")
      configuration_requested=1
      shift 2
      ;;
    --dry-run)
      install_dry_run=1
      configuration_requested=1
      shift
      ;;
    --upgrade)
      upgrade=1
      shift
      ;;
    --reconfigure)
      reconfigure=1
      shift
      ;;
    --yes)
      assume_yes=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

(( EUID == 0 )) || fail "run this installer with sudo"
[[ ! -L "${SOURCE_BIN}" && -x "${SOURCE_BIN}" && \
   ! -L "${SOURCE_PLIST}" && -f "${SOURCE_PLIST}" && \
   ! -L "${SOURCE_VERSION}" && -f "${SOURCE_VERSION}" ]] || \
  fail "release files are incomplete under ${SOURCE_ROOT}"

typeset temp_dir
temp_dir="$(/usr/bin/mktemp -d /private/tmp/utm-bridge-fdb-guard.install.XXXXXX)" || fail "mktemp failed"
/bin/chmod -N "${temp_dir}"
/bin/chmod 0700 "${temp_dir}"
trap '/bin/rm -rf "${temp_dir}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

readonly STAGED_RELEASE_BIN="${temp_dir}/utm-bridge-fdb-guard"
readonly STAGED_RELEASE_PLIST="${temp_dir}/${LABEL}.plist"
readonly STAGED_RELEASE_VERSION="${temp_dir}/VERSION"
/bin/cp -pP "${SOURCE_BIN}" "${STAGED_RELEASE_BIN}"
/bin/cp -pP "${SOURCE_PLIST}" "${STAGED_RELEASE_PLIST}"
/bin/cp -pP "${SOURCE_VERSION}" "${STAGED_RELEASE_VERSION}"
for staged_release_file in "${STAGED_RELEASE_BIN}" "${STAGED_RELEASE_PLIST}" "${STAGED_RELEASE_VERSION}"; do
  [[ ! -L "${staged_release_file}" && -f "${staged_release_file}" ]] || \
    fail "release input changed while it was being staged"
  /bin/chmod -N "${staged_release_file}"
  /usr/bin/xattr -c "${staged_release_file}"
  /usr/sbin/chown root:wheel "${staged_release_file}"
done
/bin/chmod 0700 "${STAGED_RELEASE_BIN}"
/bin/chmod 0600 "${STAGED_RELEASE_PLIST}" "${STAGED_RELEASE_VERSION}"

/bin/zsh -n "${STAGED_RELEASE_BIN}" || fail "guard script failed syntax validation"
/usr/bin/plutil -lint "${STAGED_RELEASE_PLIST}" >/dev/null || fail "LaunchDaemon plist is invalid"
staged_label="$(/usr/bin/plutil -extract Label raw -o - "${STAGED_RELEASE_PLIST}" 2>/dev/null)" || \
  fail "LaunchDaemon plist has no Label"
staged_argument_count="$(/usr/bin/plutil -extract ProgramArguments raw -o - "${STAGED_RELEASE_PLIST}" 2>/dev/null)" || \
  fail "LaunchDaemon plist has no ProgramArguments"
[[ "${staged_label}" == "${LABEL}" && "${staged_argument_count}" == "4" ]] || \
  fail "LaunchDaemon identity or ProgramArguments count is invalid"
typeset -a expected_program_arguments
expected_program_arguments=("${TARGET_BIN}" run --config "${TARGET_CONFIG}")
for (( staged_argument_index = 0; staged_argument_index < 4; staged_argument_index++ )); do
  staged_argument="$(/usr/bin/plutil -extract "ProgramArguments.${staged_argument_index}" raw -o - "${STAGED_RELEASE_PLIST}" 2>/dev/null)" || \
    fail "LaunchDaemon ProgramArguments are unreadable"
  [[ "${staged_argument}" == "${expected_program_arguments[staged_argument_index + 1]}" ]] || \
    fail "LaunchDaemon ProgramArguments do not match the fixed installation paths"
done
if /usr/bin/plutil -extract Program raw -o - "${STAGED_RELEASE_PLIST}" >/dev/null 2>&1; then
  fail "LaunchDaemon plist must not define a separate Program path"
fi

source_version="$(<"${STAGED_RELEASE_VERSION}")"
binary_version="$("${STAGED_RELEASE_BIN}" version 2>/dev/null | /usr/bin/awk '{print $2}')"
[[ -n "${source_version}" && "${source_version}" == "${binary_version}" ]] || \
  fail "VERSION does not match the guard binary"

if [[ ${reconfigure} -eq 1 && ${upgrade} -ne 1 ]]; then
  fail "--reconfigure requires --upgrade"
fi

if /bin/launchctl print "system/${LEGACY_LABEL}" >/dev/null 2>&1 || \
  [[ -e "/Library/LaunchDaemons/${LEGACY_LABEL}.plist" || \
     -L "/Library/LaunchDaemons/${LEGACY_LABEL}.plist" ]]; then
  fail "the legacy machine-specific guard is installed; uninstall it before installing this package"
fi

[[ ! -L "${TARGET_ROOT}" ]] || fail "refusing to install through a symbolic-link installation root"
[[ ! -L "${TARGET_PLIST}" ]] || fail "refusing to replace a symbolic-link LaunchDaemon plist"

typeset daemon_loaded=0
if /bin/launchctl print "system/${LABEL}" >/dev/null 2>&1; then
  daemon_loaded=1
fi

typeset existing=0
typeset preserved_config_only=0
if [[ -e "${TARGET_ROOT}" && ! -e "${TARGET_PLIST}" ]] && (( daemon_loaded == 0 )); then
  [[ ! -L "${TARGET_ROOT}" && -d "${TARGET_ROOT}" ]] || \
    fail "refusing to use an unexpected preserved configuration root"
  typeset -a preserved_entries
  preserved_entries=("${TARGET_ROOT}"/*(DN))
  if (( ${#preserved_entries} == 1 )) && [[ "${preserved_entries[1]}" == "${TARGET_CONFIG}" ]]; then
    [[ ! -L "${TARGET_CONFIG}" && -f "${TARGET_CONFIG}" ]] || \
      fail "refusing to use a non-regular preserved configuration"
    root_owned_not_group_other_writable "${TARGET_ROOT}" || \
      fail "preserved configuration root must be root:wheel-owned and not group/other writable"
    root_owned_not_group_other_writable "${TARGET_CONFIG}" || \
      fail "preserved configuration must be root:wheel-owned and not group/other writable"
    /usr/bin/plutil -lint "${TARGET_CONFIG}" >/dev/null || \
      fail "preserved configuration is not a valid plist"
    preserved_config_only=1
  fi
fi
if (( preserved_config_only == 0 )) && \
  { [[ -e "${TARGET_PLIST}" || -e "${TARGET_ROOT}" ]] || (( daemon_loaded == 1 )); }; then
  existing=1
fi
if (( existing == 1 && upgrade == 0 )); then
  fail "an installation already exists; use --upgrade after inspecting it"
fi
if (( existing == 0 && preserved_config_only == 0 && upgrade == 1 )); then
  fail "--upgrade was requested but no installation exists"
fi
if (( (existing == 1 || preserved_config_only == 1) && reconfigure == 0 && configuration_requested == 1 )); then
  fail "configuration options require --upgrade --reconfigure when a configuration already exists"
fi
if (( existing == 1 )); then
  [[ ! -L "${TARGET_ROOT}" && -d "${TARGET_ROOT}" ]] || \
    fail "refusing to upgrade an unexpected installation root"
  [[ ! -L "${TARGET_BIN_DIR}" && -d "${TARGET_BIN_DIR}" ]] || \
    fail "refusing to upgrade an unexpected binary directory"
  [[ ! -L "${TARGET_PLIST}" && -f "${TARGET_PLIST}" ]] || \
    fail "refusing to upgrade without the expected regular LaunchDaemon plist"
  installed_label="$(/usr/bin/plutil -extract Label raw -o - "${TARGET_PLIST}" 2>/dev/null)" || \
    fail "existing LaunchDaemon plist is unreadable"
  installed_argument_count="$(/usr/bin/plutil -extract ProgramArguments raw -o - "${TARGET_PLIST}" 2>/dev/null)" || \
    fail "existing LaunchDaemon plist has no ProgramArguments"
  [[ "${installed_label}" == "${LABEL}" && "${installed_argument_count}" == "4" ]] || \
    fail "existing files do not belong to ${LABEL}"
  for (( installed_argument_index = 0; installed_argument_index < 4; installed_argument_index++ )); do
    installed_argument="$(/usr/bin/plutil -extract "ProgramArguments.${installed_argument_index}" raw -o - "${TARGET_PLIST}" 2>/dev/null)" || \
      fail "existing LaunchDaemon ProgramArguments are unreadable"
    [[ "${installed_argument}" == "${expected_program_arguments[installed_argument_index + 1]}" ]] || \
      fail "existing LaunchDaemon ProgramArguments do not belong to this package"
  done
  if /usr/bin/plutil -extract Program raw -o - "${TARGET_PLIST}" >/dev/null 2>&1; then
    fail "existing LaunchDaemon has an unexpected separate Program path"
  fi
  [[ ! -L "${TARGET_BIN}" && -f "${TARGET_BIN}" ]] || \
    fail "existing guard binary is missing or not a regular file"
  [[ ! -L "${TARGET_CONFIG}" && -f "${TARGET_CONFIG}" ]] || \
    fail "existing configuration is missing or not a regular file"
  root_owned_not_group_other_writable "${TARGET_ROOT}" || \
    fail "existing installation root has unsafe ownership or permissions"
  root_owned_not_group_other_writable "${TARGET_BIN_DIR}" || \
    fail "existing binary directory has unsafe ownership or permissions"
  root_owned_not_group_other_writable "${TARGET_PLIST}" || \
    fail "existing LaunchDaemon plist has unsafe ownership or permissions"
  root_owned_not_group_other_writable "${TARGET_BIN}" || \
    fail "existing guard binary has unsafe ownership or permissions"
  root_owned_not_group_other_writable "${TARGET_CONFIG}" || \
    fail "existing configuration has unsafe ownership or permissions"
  for optional_path in "${TARGET_VERSION}" "${TARGET_MANIFEST}" "${TARGET_LOCK}"; do
    if [[ -e "${optional_path}" || -L "${optional_path}" ]]; then
      [[ ! -L "${optional_path}" && -f "${optional_path}" ]] || \
        fail "refusing to upgrade an unexpected package metadata file"
      root_owned_not_group_other_writable "${optional_path}" || \
        fail "existing package metadata has unsafe ownership or permissions"
    fi
  done
fi

typeset build_new_config=1
if (( (existing == 1 || preserved_config_only == 1) && reconfigure == 0 )); then
  build_new_config=0
fi
if (( build_new_config == 1 )); then
  if [[ -z "${requested_uplink}" ]]; then
    requested_uplink="$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/^[[:space:]]*interface:/ {print $2; exit}')"
  fi
  [[ -n "${requested_uplink}" ]] || fail "could not detect the default-route interface; pass --uplink"
  valid_interface_name "${requested_uplink}" || fail "invalid uplink name: ${requested_uplink}"
  if [[ "${requested_bridge}" != "auto" ]]; then
    valid_bridge_name "${requested_bridge}" || fail "invalid bridge name: ${requested_bridge}"
  fi
fi

typeset staged_config="${temp_dir}/config.plist"
if (( build_new_config == 1 )); then
  /usr/bin/plutil -create xml1 "${staged_config}"
  /usr/bin/plutil -insert Version -integer 1 "${staged_config}"
  if [[ "${requested_bridge}" == "auto" ]]; then
    /usr/bin/plutil -insert BridgePolicy -string auto "${staged_config}"
    /usr/bin/plutil -insert AllowedBridges -array "${staged_config}"
  else
    /usr/bin/plutil -insert BridgePolicy -string allowlist "${staged_config}"
    /usr/bin/plutil -insert AllowedBridges -array "${staged_config}"
    /usr/bin/plutil -insert AllowedBridges.0 -string "${requested_bridge}" "${staged_config}"
  fi
  /usr/bin/plutil -insert UplinkPolicy -string explicit "${staged_config}"
  /usr/bin/plutil -insert AllowedUplinks -array "${staged_config}"
  /usr/bin/plutil -insert AllowedUplinks.0 -string "${requested_uplink}" "${staged_config}"
  /usr/bin/plutil -insert AllowedGuestMACs -array "${staged_config}"
  if (( ${#requested_guest_macs} == 0 )); then
    /usr/bin/plutil -insert GuestEvidence -string learned-any "${staged_config}"
  else
    /usr/bin/plutil -insert GuestEvidence -string allowlist "${staged_config}"
    typeset i
    for (( i = 1; i <= ${#requested_guest_macs}; i++ )); do
      /usr/bin/plutil -insert "AllowedGuestMACs.$(( i - 1 ))" -string "${requested_guest_macs[i]}" "${staged_config}"
    done
  fi
  if (( install_dry_run == 1 )); then
    /usr/bin/plutil -insert DryRun -bool true "${staged_config}"
  else
    /usr/bin/plutil -insert DryRun -bool false "${staged_config}"
  fi
  /usr/bin/plutil -lint "${staged_config}" >/dev/null || fail "generated configuration is invalid"
fi

typeset scan_config="${staged_config}"
if (( (existing == 1 || preserved_config_only == 1) && reconfigure == 0 )) && \
  [[ -f "${TARGET_CONFIG}" ]]; then
  scan_config="${TARGET_CONFIG}"
  print "Preserving existing configuration."
fi

print "Read-only topology scan:"
"${STAGED_RELEASE_BIN}" scan --config "${scan_config}" --verbose || \
  fail "guard rejected the proposed configuration"

if (( assume_yes == 0 )); then
  print -n "Install the LaunchDaemon with this configuration? [y/N] "
  typeset answer
  read -r answer
  [[ "${answer:l}" == "y" || "${answer:l}" == "yes" ]] || {
    print "Cancelled; no files were installed."
    exit 0
  }
fi

typeset backup_dir="${temp_dir}/backup"
typeset was_loaded=0
typeset mutation_started=0

rollback() {
  local status="$1"
  setopt LOCAL_OPTIONS NO_ERR_EXIT
  trap - EXIT INT TERM HUP
  if (( status != 0 && mutation_started == 1 )); then
    print -u2 "Installation failed; restoring the previous state."
    /bin/launchctl bootout "system/${LABEL}" >/dev/null 2>&1 || true
    /bin/rm -f "${TARGET_PLIST}" "${TARGET_BIN}" "${TARGET_CONFIG}" "${TARGET_VERSION}" "${TARGET_MANIFEST}" "${TARGET_LOCK}"
    if [[ -d "${backup_dir}" ]]; then
      [[ -f "${backup_dir}/daemon.plist" ]] && /usr/bin/install -o root -g wheel -m 0644 "${backup_dir}/daemon.plist" "${TARGET_PLIST}"
      [[ -f "${backup_dir}/guard" ]] && /usr/bin/install -o root -g wheel -m 0755 "${backup_dir}/guard" "${TARGET_BIN}"
      [[ -f "${backup_dir}/config.plist" ]] && /usr/bin/install -o root -g wheel -m 0644 "${backup_dir}/config.plist" "${TARGET_CONFIG}"
      [[ -f "${backup_dir}/VERSION" ]] && /usr/bin/install -o root -g wheel -m 0644 "${backup_dir}/VERSION" "${TARGET_VERSION}"
      [[ -f "${backup_dir}/install-manifest.txt" ]] && /usr/bin/install -o root -g wheel -m 0644 "${backup_dir}/install-manifest.txt" "${TARGET_MANIFEST}"
      [[ -f "${backup_dir}/run.lock" ]] && /usr/bin/install -o root -g wheel -m 0600 "${backup_dir}/run.lock" "${TARGET_LOCK}"
      for restored_path in "${TARGET_ROOT}" "${TARGET_BIN_DIR}" "${TARGET_PLIST}" "${TARGET_BIN}" \
        "${TARGET_CONFIG}" "${TARGET_VERSION}" "${TARGET_MANIFEST}" "${TARGET_LOCK}"; do
        [[ -e "${restored_path}" ]] && /bin/chmod -N "${restored_path}"
      done
      if (( was_loaded == 1 )); then
        /bin/launchctl bootstrap system "${TARGET_PLIST}" >/dev/null 2>&1 || true
      fi
    fi
    /bin/rmdir "${TARGET_BIN_DIR}" 2>/dev/null || true
    /bin/rmdir "${TARGET_ROOT}" 2>/dev/null || true
  fi
  /bin/rm -rf "${temp_dir}"
  exit ${status}
}
trap 'rollback $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if (( existing == 1 || preserved_config_only == 1 )); then
  /bin/mkdir -p "${backup_dir}"
  [[ -f "${TARGET_PLIST}" ]] && /bin/cp -p "${TARGET_PLIST}" "${backup_dir}/daemon.plist"
  [[ -f "${TARGET_BIN}" ]] && /bin/cp -p "${TARGET_BIN}" "${backup_dir}/guard"
  [[ -f "${TARGET_CONFIG}" ]] && /bin/cp -p "${TARGET_CONFIG}" "${backup_dir}/config.plist"
  [[ -f "${TARGET_VERSION}" ]] && /bin/cp -p "${TARGET_VERSION}" "${backup_dir}/VERSION"
  [[ -f "${TARGET_MANIFEST}" ]] && /bin/cp -p "${TARGET_MANIFEST}" "${backup_dir}/install-manifest.txt"
  [[ -f "${TARGET_LOCK}" ]] && /bin/cp -p "${TARGET_LOCK}" "${backup_dir}/run.lock"
fi

was_loaded=${daemon_loaded}
mutation_started=1
if (( was_loaded == 1 )); then
  /bin/launchctl bootout "system/${LABEL}"
fi

/usr/bin/install -d -o root -g wheel -m 0755 "${TARGET_ROOT}" "${TARGET_BIN_DIR}"
/bin/chmod -N "${TARGET_ROOT}" "${TARGET_BIN_DIR}"
/usr/bin/install -o root -g wheel -m 0755 "${STAGED_RELEASE_BIN}" "${TARGET_BIN}"
if (( build_new_config == 1 )); then
  /usr/bin/install -o root -g wheel -m 0644 "${staged_config}" "${TARGET_CONFIG}"
fi
/usr/bin/install -o root -g wheel -m 0644 "${STAGED_RELEASE_VERSION}" "${TARGET_VERSION}"
/usr/bin/install -o root -g wheel -m 0644 "${STAGED_RELEASE_PLIST}" "${TARGET_PLIST}"
/usr/bin/install -o root -g wheel -m 0600 /dev/null "${TARGET_LOCK}"

{
  print "${TARGET_BIN}"
  print "${TARGET_CONFIG}"
  print "${TARGET_VERSION}"
  print "${TARGET_LOCK}"
  print "${TARGET_PLIST}"
} >| "${temp_dir}/install-manifest.txt"
/usr/bin/install -o root -g wheel -m 0644 "${temp_dir}/install-manifest.txt" "${TARGET_MANIFEST}"

for installed_path in "${TARGET_ROOT}" "${TARGET_BIN_DIR}" "${TARGET_PLIST}" "${TARGET_BIN}" \
  "${TARGET_CONFIG}" "${TARGET_VERSION}" "${TARGET_MANIFEST}" "${TARGET_LOCK}"; do
  /bin/chmod -N "${installed_path}"
  root_owned_not_group_other_writable "${installed_path}" || \
    fail "installed path has unsafe ownership, permissions, or ACL: ${installed_path}"
done

/bin/launchctl bootstrap system "${TARGET_PLIST}"
/bin/launchctl kickstart -k "system/${LABEL}"
/bin/launchctl print "system/${LABEL}" >/dev/null

mutation_started=0
trap - EXIT INT TERM HUP
/bin/rm -rf "${temp_dir}"

print "Installed ${LABEL}."
print "Run: sudo '${TARGET_BIN}' doctor --config '${TARGET_CONFIG}'"

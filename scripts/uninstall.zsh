#!/bin/zsh -f

emulate -L zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL

readonly LABEL="io.github.hosamajjf.utm-bridge-fdb-guard"
readonly TARGET_ROOT="/Library/Application Support/UTMBridgeFDBGuard"
readonly TARGET_BIN_DIR="${TARGET_ROOT}/bin"
readonly TARGET_BIN="${TARGET_BIN_DIR}/utm-bridge-fdb-guard"
readonly TARGET_CONFIG="${TARGET_ROOT}/config.plist"
readonly TARGET_VERSION="${TARGET_ROOT}/VERSION"
readonly TARGET_MANIFEST="${TARGET_ROOT}/install-manifest.txt"
readonly TARGET_LOCK="${TARGET_ROOT}/run.lock"
readonly TARGET_PLIST="/Library/LaunchDaemons/${LABEL}.plist"

fail() {
  print -u2 -- "uninstall.zsh: $*"
  exit 1
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

typeset keep_config=0
if [[ "${1:-}" == "--keep-config" ]]; then
  keep_config=1
  shift
fi
(( $# == 0 )) || {
  print -u2 "Usage: sudo ./scripts/uninstall.zsh [--keep-config]"
  exit 2
}
(( EUID == 0 )) || fail "run this uninstaller with sudo"

[[ ! -L "${TARGET_ROOT}" ]] || fail "refusing to uninstall through a symbolic-link installation root"
[[ ! -L "${TARGET_PLIST}" ]] || fail "refusing to remove a symbolic-link LaunchDaemon plist"
if (( keep_config == 1 )) && [[ ! -f "${TARGET_CONFIG}" || -L "${TARGET_CONFIG}" ]]; then
  fail "--keep-config requires an existing regular configuration file"
fi

typeset daemon_loaded=0
if /bin/launchctl print "system/${LABEL}" >/dev/null 2>&1; then
  daemon_loaded=1
fi

if [[ ! -e "${TARGET_PLIST}" && ! -e "${TARGET_ROOT}" ]] && (( daemon_loaded == 0 )); then
  print "${LABEL} is not installed."
  exit 0
fi

if (( daemon_loaded == 1 )) && [[ ! -e "${TARGET_PLIST}" ]]; then
  fail "refusing to unload a service without its on-disk LaunchDaemon plist"
fi

if [[ -e "${TARGET_PLIST}" ]]; then
  [[ ! -L "${TARGET_PLIST}" && -f "${TARGET_PLIST}" ]] || \
    fail "refusing to remove a non-regular LaunchDaemon plist"
  root_owned_not_group_other_writable "${TARGET_PLIST}" || \
    fail "LaunchDaemon plist has unsafe ownership or permissions"
  installed_label="$(/usr/bin/plutil -extract Label raw -o - "${TARGET_PLIST}" 2>/dev/null)" || {
    fail "refusing to remove an unreadable LaunchDaemon plist"
  }
  installed_argument_count="$(/usr/bin/plutil -extract ProgramArguments raw -o - "${TARGET_PLIST}" 2>/dev/null)" || {
    fail "refusing to remove a plist without ProgramArguments"
  }
  [[ "${installed_label}" == "${LABEL}" && "${installed_argument_count}" == "4" ]] || \
    fail "refusing to remove a LaunchDaemon that does not belong to this package"
  typeset -a expected_program_arguments
  expected_program_arguments=("${TARGET_BIN}" run --config "${TARGET_CONFIG}")
  for (( installed_argument_index = 0; installed_argument_index < 4; installed_argument_index++ )); do
    installed_argument="$(/usr/bin/plutil -extract "ProgramArguments.${installed_argument_index}" raw -o - "${TARGET_PLIST}" 2>/dev/null)" || \
      fail "refusing to remove a plist with unreadable ProgramArguments"
    [[ "${installed_argument}" == "${expected_program_arguments[installed_argument_index + 1]}" ]] || \
      fail "refusing to remove a LaunchDaemon with unexpected ProgramArguments"
  done
  if /usr/bin/plutil -extract Program raw -o - "${TARGET_PLIST}" >/dev/null 2>&1; then
    fail "refusing to remove a LaunchDaemon with a separate Program path"
  fi
fi

if [[ -e "${TARGET_ROOT}" ]]; then
  [[ ! -L "${TARGET_ROOT}" && -d "${TARGET_ROOT}" ]] || \
    fail "refusing to remove files through an unexpected installation root"
  root_owned_not_group_other_writable "${TARGET_ROOT}" || \
    fail "installation root has unsafe ownership or permissions"

  if [[ ! -e "${TARGET_PLIST}" ]]; then
    typeset -a preserved_entries
    preserved_entries=("${TARGET_ROOT}"/*(DN))
    (( ${#preserved_entries} == 1 )) && [[ "${preserved_entries[1]}" == "${TARGET_CONFIG}" ]] || \
      fail "refusing to remove an unrecognized incomplete installation"
    [[ ! -L "${TARGET_CONFIG}" && -f "${TARGET_CONFIG}" ]] || \
      fail "refusing to remove a non-regular preserved configuration"
    root_owned_not_group_other_writable "${TARGET_CONFIG}" || \
      fail "preserved configuration has unsafe ownership, permissions, or ACL"
  fi

  if [[ -e "${TARGET_BIN_DIR}" || -L "${TARGET_BIN_DIR}" ]]; then
    [[ ! -L "${TARGET_BIN_DIR}" && -d "${TARGET_BIN_DIR}" ]] || \
      fail "refusing to remove files through an unexpected binary directory"
    root_owned_not_group_other_writable "${TARGET_BIN_DIR}" || \
      fail "binary directory has unsafe ownership or permissions"
  fi

  for package_file in "${TARGET_BIN}" "${TARGET_CONFIG}" "${TARGET_VERSION}" "${TARGET_MANIFEST}" "${TARGET_LOCK}"; do
    if [[ -e "${package_file}" || -L "${package_file}" ]]; then
      [[ ! -L "${package_file}" && -f "${package_file}" ]] || \
        fail "refusing to remove a non-regular package file: ${package_file}"
      root_owned_not_group_other_writable "${package_file}" || \
        fail "package file has unsafe ownership or permissions: ${package_file}"
    fi
  done
fi

if (( daemon_loaded == 1 )); then
  /bin/launchctl bootout "system/${LABEL}" || {
    fail "could not unload ${LABEL}; no files were removed"
  }
fi

/bin/rm -f "${TARGET_PLIST}" "${TARGET_BIN}" "${TARGET_VERSION}" "${TARGET_MANIFEST}" "${TARGET_LOCK}"
if (( keep_config == 0 )); then
  /bin/rm -f "${TARGET_CONFIG}"
fi
/bin/rmdir "${TARGET_ROOT}/bin" 2>/dev/null || true
/bin/rmdir "${TARGET_ROOT}" 2>/dev/null || true

print "Uninstalled ${LABEL}."
if (( keep_config == 1 )); then
  print "Preserved ${TARGET_CONFIG}."
fi

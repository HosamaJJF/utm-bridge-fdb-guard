#!/bin/zsh -f

emulate -L zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL

[[ "${GITHUB_ACTIONS:-}" == "true" ]] || {
  print -u2 'install-lifecycle.zsh is restricted to an ephemeral GitHub Actions runner.'
  exit 1
}
(( EUID == 0 )) || {
  print -u2 'install-lifecycle.zsh must run as root.'
  exit 1
}

readonly repo_dir="${0:A:h:h}"
readonly installer="${repo_dir}/scripts/install.zsh"
readonly uninstaller="${repo_dir}/scripts/uninstall.zsh"
readonly label="io.github.hosamajjf.utm-bridge-fdb-guard"
readonly target_root="/Library/Application Support/UTMBridgeFDBGuard"
readonly target_bin_dir="${target_root}/bin"
readonly target_bin="${target_bin_dir}/utm-bridge-fdb-guard"
readonly target_config="${target_root}/config.plist"
readonly target_version="${target_root}/VERSION"
readonly target_manifest="${target_root}/install-manifest.txt"
readonly target_lock="${target_root}/run.lock"
readonly target_plist="/Library/LaunchDaemons/${label}.plist"

typeset temp_dir
temp_dir="$(/usr/bin/mktemp -d "${RUNNER_TEMP:-/private/tmp}/utm-bridge-fdb-guard.lifecycle.XXXXXX")"
readonly saved_config="${temp_dir}/config.plist"
typeset cleanup_needed=1

cleanup() {
  local status="$1"
  setopt LOCAL_OPTIONS NO_ERR_EXIT
  trap - EXIT INT TERM HUP
  if (( cleanup_needed == 1 )); then
    /bin/launchctl bootout "system/${label}" >/dev/null 2>&1 || true
    /bin/rm -f "${target_plist}" "${target_bin}" "${target_config}" "${target_version}" \
      "${target_manifest}" "${target_lock}"
    /bin/rmdir "${target_bin_dir}" 2>/dev/null || true
    /bin/rmdir "${target_root}" 2>/dev/null || true
  fi
  /bin/rm -rf "${temp_dir}"
  exit ${status}
}
trap 'cleanup $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

fail() {
  print -u2 -- "install lifecycle: $*"
  exit 1
}

[[ ! -e "${target_root}" && ! -L "${target_root}" && \
   ! -e "${target_plist}" && ! -L "${target_plist}" ]] || \
  fail 'the ephemeral runner was not clean before the test'
if /bin/launchctl print "system/${label}" >/dev/null 2>&1; then
  fail 'the test LaunchDaemon label was already loaded'
fi

uplink="$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/^[[:space:]]*interface:/ { print $2; exit }')"
[[ -n "${uplink}" ]] || fail 'could not determine the runner default-route interface'

"${installer}" --yes --dry-run --uplink "${uplink}"
/bin/launchctl print "system/${label}" >/dev/null || fail 'fresh install did not load the LaunchDaemon'

for installed_path in "${target_root}" "${target_bin_dir}" "${target_bin}" "${target_config}" \
  "${target_version}" "${target_manifest}" "${target_lock}" "${target_plist}"; do
  [[ -e "${installed_path}" && ! -L "${installed_path}" ]] || fail "missing regular installed path: ${installed_path}"
  mode_token="$(/bin/ls -lde "${installed_path}" | /usr/bin/awk 'NR == 1 { print $1; exit }')"
  [[ "${mode_token}" != *+* ]] || fail "installed path retained an ACL: ${installed_path}"
done

config_hash="$(/usr/bin/shasum -a 256 "${target_config}" | /usr/bin/awk '{ print $1 }')"
/bin/mv "${target_config}" "${saved_config}"
missing_config_exit=0
"${uninstaller}" --keep-config >/dev/null 2>&1 || missing_config_exit=$?
(( missing_config_exit != 0 )) || fail '--keep-config succeeded even though config.plist was missing'
/bin/launchctl print "system/${label}" >/dev/null || fail 'failed --keep-config changed the loaded service'
/bin/mv "${saved_config}" "${target_config}"

"${installer}" --yes --upgrade
upgraded_hash="$(/usr/bin/shasum -a 256 "${target_config}" | /usr/bin/awk '{ print $1 }')"
[[ "${upgraded_hash}" == "${config_hash}" ]] || fail 'upgrade without reconfigure changed the config'

"${uninstaller}" --keep-config
[[ -f "${target_config}" && ! -L "${target_config}" ]] || fail 'uninstall did not preserve config.plist'
[[ ! -e "${target_plist}" && ! -e "${target_bin}" && ! -e "${target_lock}" ]] || \
  fail 'uninstall --keep-config left executable service state behind'

"${installer}" --yes
reinstalled_hash="$(/usr/bin/shasum -a 256 "${target_config}" | /usr/bin/awk '{ print $1 }')"
[[ "${reinstalled_hash}" == "${config_hash}" ]] || fail 'reinstall did not reuse the preserved config'
/bin/launchctl print "system/${label}" >/dev/null || fail 'reinstall did not reload the LaunchDaemon'

"${uninstaller}"
[[ ! -e "${target_root}" && ! -e "${target_plist}" ]] || fail 'final uninstall left package paths behind'

cleanup_needed=0
print 'install, upgrade, keep-config reinstall, ACL cleanup, and uninstall lifecycle passed'

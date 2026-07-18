#!/bin/zsh -f

emulate -L zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL

(( EUID == 0 )) || {
  print -u2 'root-security.zsh must run under sudo.'
  exit 1
}

readonly tests_dir="${0:A:h}"
readonly guard="${tests_dir:h}/bin/utm-bridge-fdb-guard"
readonly acl_user="${SUDO_USER:-}"
[[ -n "${acl_user}" && "${acl_user}" != "root" ]] || {
  print -u2 'root-security.zsh requires SUDO_USER to name a non-root account.'
  exit 1
}

typeset temp_dir
temp_dir="$(/usr/bin/mktemp -d /private/tmp/utm-bridge-fdb-guard.security.XXXXXX)"
trap '/bin/rm -rf "${temp_dir}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

readonly config="${temp_dir}/config.plist"
readonly stdout_log="${temp_dir}/stdout.log"
readonly stderr_log="${temp_dir}/stderr.log"
/bin/cp "${tests_dir}/fixtures/config-auto.plist" "${config}"
/usr/sbin/chown root:wheel "${temp_dir}" "${config}"
/bin/chmod 0755 "${temp_dir}"
/bin/chmod 0644 "${config}"
/bin/chmod -N "${temp_dir}" "${config}"

expect_acl_rejection() {
  local description="$1"
  local actual_exit=0
  : > "${stdout_log}"
  : > "${stderr_log}"
  "${guard}" doctor --config "${config}" > "${stdout_log}" 2> "${stderr_log}" || actual_exit=$?
  if (( actual_exit != 2 )) || ! /usr/bin/grep -Fq 'free of ACLs' "${stderr_log}"; then
    print -u2 -- "not ok - ${description}"
    /bin/cat "${stdout_log}" >&2
    /bin/cat "${stderr_log}" >&2
    exit 1
  fi
  print -- "ok - ${description}"
}

/bin/chmod +a "${acl_user} allow write" "${config}"
expect_acl_rejection 'a writable ACL on the root-owned config is rejected'
/bin/chmod -N "${config}"

/bin/chmod +a "${acl_user} allow write" "${temp_dir}"
expect_acl_rejection 'a writable ACL on the config parent is rejected'
/bin/chmod -N "${temp_dir}"

print 'root ACL security tests passed'

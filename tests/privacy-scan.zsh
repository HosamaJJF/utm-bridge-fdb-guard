#!/bin/zsh -f

emulate -L zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL

repo_dir="${0:A:h:h}"
cd "${repo_dir}"

failures=0
setopt GLOB_DOTS
typeset -a scan_files
scan_files=(**/*(.N))
scan_files=("${(@)scan_files:#.git/*}")
scan_files=("${(@)scan_files:#tests/privacy-scan.zsh}")

report_matches() {
  local title="$1"
  local pattern="$2"
  local file file_matches matches=''

  for file in "${scan_files[@]}"; do
    file_matches="$(/usr/bin/grep -nEI -- "${pattern}" "${file}" 2>/dev/null || true)"
    if [[ -n "${file_matches}" ]]; then
      matches+="${file}:"$'\n'"${file_matches}"$'\n'
    fi
  done
  if [[ -n "${matches}" ]]; then
    print -u2 -- "privacy scan: ${title}"
    print -u2 -- "${matches}"
    (( failures += 1 ))
  fi
}

# Repository examples must use documentation addresses rather than copied LAN data.
report_matches 'private IPv4 address found' \
  '(^|[^0-9])(10[.][0-9]{1,3}[.]|192[.]168[.]|172[.](1[6-9]|2[0-9]|3[01])[.])'

# Absolute user-home paths can disclose the workstation account name.
report_matches 'absolute macOS user-home path found' \
  '/Users/[[:alnum:]_.-]+'

# Common credential formats must never enter fixtures, logs, or documentation.
report_matches 'credential-like token or private key found' \
  '(gh[pousr]_[[:alnum:]_]{20,}|github_pat_[[:alnum:]_]{20,}|BEGIN[[:space:]]+(RSA[[:space:]]+|OPENSSH[[:space:]]+|EC[[:space:]]+)?PRIVATE[[:space:]]+KEY)'

# By project convention, all literal MAC examples use locally administered
# addresses under the 02:00:00 prefix. Any other literal is treated as capture.
mac_pattern='([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}'
mac_values=''
for file in "${scan_files[@]}"; do
  mac_values+="$(/usr/bin/grep -Eio -- "${mac_pattern}" "${file}" 2>/dev/null || true)"$'\n'
done
mac_values="$(print -r -- "${mac_values}" | /usr/bin/sort -fu)"

for mac in ${(f)mac_values}; do
  octets=( ${(s.:.)${mac:l}} )
  if [[ "${#octets}" != 6 ]]; then
    print -u2 -- "privacy scan: malformed literal MAC: ${mac}"
    (( failures += 1 ))
    continue
  fi
  canonical=''
  for octet in "${octets[@]}"; do
    canonical+="$(/usr/bin/printf '%02x' "$(( 16#${octet} ))")"
    canonical+=':'
  done
  canonical="${canonical%:}"
  if [[ "${canonical}" != 02:00:00:* && \
        "${canonical}" != '00:00:00:00:00:00' && \
        "${canonical}" != 'ff:ff:ff:ff:ff:ff' ]]; then
    print -u2 -- "privacy scan: non-documentation MAC found: ${mac}"
    (( failures += 1 ))
  fi
done

if (( failures != 0 )); then
  print -u2 -- "privacy scan failed with ${failures} finding group(s)."
  exit 1
fi

print 'privacy scan passed'

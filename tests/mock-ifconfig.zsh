#!/bin/zsh -f

emulate -L zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL

fixture_dir="${UTM_BRIDGE_GUARD_FIXTURE_DIR:?UTM_BRIDGE_GUARD_FIXTURE_DIR is required}"
fixture_base="${UTM_BRIDGE_GUARD_FIXTURE_BASE:-}"
action_log="${UTM_BRIDGE_GUARD_MOCK_ACTION_LOG:?UTM_BRIDGE_GUARD_MOCK_ACTION_LOG is required}"
call_log="${UTM_BRIDGE_GUARD_MOCK_CALL_LOG:-}"

if [[ -n "${call_log}" ]]; then
  {
    local argument
    for argument in "$@"; do
      print -rn -- "${(q)argument} "
    done
    print
  } >> "${call_log}"
fi

print_fixture() {
  local fixture_name="$1"
  local candidate="${fixture_dir}/${fixture_name}"

  if [[ "${fixture_name}" == *'/'* || "${fixture_name}" == *'..'* ]]; then
    print -u2 -- "mock-ifconfig: invalid fixture name: ${fixture_name}"
    return 64
  fi

  if [[ -f "${candidate}.fail" ]]; then
    print -u2 -- "mock-ifconfig: forced failure for ${fixture_name}"
    return 1
  fi

  if [[ -f "${candidate}" ]]; then
    /bin/cat "${candidate}"
    return 0
  fi

  if [[ -n "${fixture_base}" && -f "${fixture_base}/${fixture_name}" ]]; then
    /bin/cat "${fixture_base}/${fixture_name}"
    return 0
  fi

  print -u2 -- "mock-ifconfig: missing fixture: ${fixture_name}"
  return 1
}

normalize_mac() {
  local raw="${1:l}"
  local -a octets
  local octet formatted result=''

  octets=("${(@s.:.)raw}")
  (( ${#octets} == 6 )) || return 1
  for octet in "${octets[@]}"; do
    [[ "${octet}" =~ '^[0-9a-f]{1,2}$' ]] || return 1
    printf -v formatted '%02x' "$(( 16#${octet} ))"
    [[ -z "${result}" ]] || result+=':'
    result+="${formatted}"
  done
  REPLY="${result}"
}

print_addr_fixture() {
  local bridge="$1"
  local deleted_mac=''
  local content line raw_mac

  if [[ -s "${action_log}" ]]; then
    deleted_mac="$(/usr/bin/awk -v bridge="${bridge}" \
      '$1 == bridge && $2 == "deladdr" { value = $3 } END { print value }' \
      "${action_log}")"
  fi
  if [[ -z "${deleted_mac}" ]]; then
    print_fixture "${bridge}.addr.txt"
    return 0
  fi

  content="$(print_fixture "${bridge}.addr.txt")" || return 1
  for line in "${(@f)content}"; do
    raw_mac="${${=line}[1]:-}"
    if normalize_mac "${raw_mac}" && [[ "${REPLY}" == "${deleted_mac:l}" ]]; then
      continue
    fi
    print -r -- "${line}"
  done
}

if [[ "$#" == 1 && "$1" == '-l' ]]; then
  if [[ -f "${fixture_dir}/interfaces.second.txt" && -n "${call_log}" ]]; then
    list_call_count="$(/usr/bin/grep -c '^-l ' "${call_log}" 2>/dev/null || true)"
    if (( list_call_count >= 2 )); then
      print_fixture 'interfaces.second.txt'
      exit 0
    fi
  fi
  print_fixture 'interfaces.txt'
  exit 0
fi

if [[ "$#" == 2 && "$2" == 'addr' ]]; then
  print_addr_fixture "$1"
  exit 0
fi

if [[ "$#" == 3 && "$2" == 'deladdr' ]]; then
  /usr/bin/printf '%s deladdr %s\n' "$1" "${3:l}" >> "${action_log}"
  exit 0
fi

if [[ "$#" == 1 ]]; then
  print_fixture "$1.txt"
  exit 0
fi

print -u2 -- "mock-ifconfig: unsupported invocation: ${(q)@}"
exit 64

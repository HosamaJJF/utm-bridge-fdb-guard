#!/bin/zsh -f

emulate -L zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
unsetopt BG_NICE

tests_dir="${0:A:h}"
repo_dir="${tests_dir:h}"
guard="${repo_dir}/bin/utm-bridge-fdb-guard"
fixtures="${tests_dir}/fixtures"
config_auto="${fixtures}/config-auto.plist"
config_bridge_allowlist="${fixtures}/config-bridge-allowlist.plist"
config_guest_allowlist="${fixtures}/config-guest-allowlist.plist"
temp_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/utm-bridge-fdb-guard-tests.XXXXXX")"
mock_ifconfig="${temp_dir}/mock-ifconfig"
mock_logger="${temp_dir}/mock-logger"
action_log="${temp_dir}/actions.log"
call_log="${temp_dir}/calls.log"
logger_log="${temp_dir}/logger.log"
stdout_log="${temp_dir}/stdout.log"
stderr_log="${temp_dir}/stderr.log"
lock_file="${temp_dir}/run.lock"
lock_ready="${temp_dir}/lock.ready"
test_count=0

cleanup() {
  /bin/rm -rf "${temp_dir}"
}
trap cleanup EXIT INT TERM

if [[ ! -f "${guard}" ]]; then
  print -u2 -- "Missing guard executable: ${guard}"
  exit 1
fi

/bin/cp "${tests_dir}/mock-ifconfig.zsh" "${mock_ifconfig}"
/bin/cp "${tests_dir}/mock-logger.zsh" "${mock_logger}"
/bin/chmod 0700 "${mock_ifconfig}" "${mock_logger}"

reset_logs() {
  : > "${action_log}"
  : > "${call_log}"
  : > "${logger_log}"
  : > "${stdout_log}"
  : > "${stderr_log}"
  : > "${lock_file}"
  /bin/rm -f "${lock_ready}"
}

invoke_guard_expect_exit() {
  local expected_exit="$1"
  local scenario="$2"
  local config="$3"
  local actual_exit=0
  shift 3

  UTM_BRIDGE_GUARD_TEST_MODE=1 \
  UTM_BRIDGE_GUARD_IFCONFIG="${mock_ifconfig}" \
  UTM_BRIDGE_GUARD_LOGGER="${mock_logger}" \
  UTM_BRIDGE_GUARD_LOCK_FILE="${lock_file}" \
  UTM_BRIDGE_GUARD_FIXTURE_DIR="${fixtures}/${scenario}" \
  UTM_BRIDGE_GUARD_FIXTURE_BASE="${fixtures}/base" \
  UTM_BRIDGE_GUARD_MOCK_ACTION_LOG="${action_log}" \
  UTM_BRIDGE_GUARD_MOCK_CALL_LOG="${call_log}" \
  UTM_BRIDGE_GUARD_MOCK_LOGGER_LOG="${logger_log}" \
    /bin/zsh "${guard}" "$@" --config "${config}" \
    > "${stdout_log}" 2> "${stderr_log}" || actual_exit=$?
  if (( actual_exit != expected_exit )); then
    fail "guard exited ${actual_exit}, expected ${expected_exit}, for scenario ${scenario}"
  fi
}

invoke_guard() {
  invoke_guard_expect_exit 0 "$@"
}

fail() {
  local message="$1"
  print -u2 -- "not ok - ${message}"
  if [[ -s "${stdout_log}" ]]; then
    print -u2 -- '--- stdout ---'
    /bin/cat "${stdout_log}" >&2
  fi
  if [[ -s "${stderr_log}" ]]; then
    print -u2 -- '--- stderr ---'
    /bin/cat "${stderr_log}" >&2
  fi
  if [[ -s "${call_log}" ]]; then
    print -u2 -- '--- mock calls ---'
    /bin/cat "${call_log}" >&2
  fi
  exit 1
}

pass() {
  local message="$1"
  (( test_count += 1 ))
  print -- "ok ${test_count} - ${message}"
}

assert_no_action() {
  local message="$1"
  if [[ -s "${action_log}" ]]; then
    print -u2 -- '--- unexpected mutations ---'
    /bin/cat "${action_log}" >&2
    fail "${message}"
  fi
  pass "${message}"
}

assert_action() {
  local expected="$1"
  local message="$2"
  local actual="$(<"${action_log}")"
  if [[ "${actual}" != "${expected}" ]]; then
    print -u2 -- "expected mutation: ${expected}"
    print -u2 -- "actual mutation:   ${actual:-<none>}"
    fail "${message}"
  fi
  pass "${message}"
}

assert_stdout_contains() {
  local expected="$1"
  local message="$2"
  if ! /usr/bin/grep -Fq -- "${expected}" "${stdout_log}"; then
    print -u2 -- "expected stdout to contain: ${expected}"
    fail "${message}"
  fi
  pass "${message}"
}

assert_logger_line() {
  local expected="$1"
  local message="$2"
  if ! /usr/bin/grep -Fxq -- "${expected}" "${logger_log}"; then
    print -u2 -- "expected logger invocation: ${expected}"
    [[ -s "${logger_log}" ]] && /bin/cat "${logger_log}" >&2
    fail "${message}"
  fi
  pass "${message}"
}

print 'TAP version 13'

reset_logs
production_exit=0
UTM_BRIDGE_GUARD_TEST_MODE=0 \
UTM_BRIDGE_GUARD_PLUTIL=/usr/bin/false \
  /bin/zsh "${guard}" doctor --config "${config_auto}" \
  > "${stdout_log}" 2> "${stderr_log}" || production_exit=$?
if (( production_exit != 2 )) || \
  ! /usr/bin/grep -Fq 'configuration and its parent must be root-owned' "${stderr_log}"; then
  fail 'production mode accepted or used a test-only tool override'
fi
pass 'production mode ignores test-only system-tool overrides'

reset_logs
/usr/bin/lockf -k "${lock_file}" /bin/zsh -c \
  '/usr/bin/touch "$1"; /bin/sleep 1' zsh "${lock_ready}" &
lock_holder_pid=$!
for (( lock_wait = 0; lock_wait < 50; lock_wait++ )); do
  [[ -e "${lock_ready}" ]] && break
  /bin/sleep 0.02
done
[[ -e "${lock_ready}" ]] || fail 'could not establish the advisory-lock test holder'
invoke_guard normal "${config_auto}" run
assert_no_action 'an active advisory lock causes a clean no-op without a stale directory'
wait "${lock_holder_pid}"

reset_logs
invoke_guard normal "${config_auto}" scan
assert_no_action 'scan is always read-only'

reset_logs
invoke_guard normal "${config_auto}" run --dry-run
assert_no_action 'run --dry-run is always read-only'
assert_stdout_contains \
  'WOULD_DELETE bridge=bridge100 uplink=en0 mac=02:00:00:00:10:01' \
  'dry-run reports the exact prospective mutation'

reset_logs
invoke_guard normal "${config_auto}" run
assert_action 'bridge100 deladdr 02:00:00:00:10:01' \
  'a unique dynamic host-MAC entry is removed'
assert_stdout_contains \
  'REMOVED bridge=bridge100 uplink=en0 mac=02:00:00:00:10:01' \
  'a successful mutation reports the exact removed entry'
assert_logger_line \
  '-t|utm-bridge-fdb-guard|Removed 02:00:00:00:10:01 learned on en0 from bridge100' \
  'the macOS logger invocation does not use an unsupported double-dash option'

reset_logs
invoke_guard vm-mac-change "${config_auto}" run
assert_action 'bridge100 deladdr 02:00:00:00:10:01' \
  'learned-any mode tolerates a changed VM MAC'

reset_logs
invoke_guard normal "${config_guest_allowlist}" run
assert_action 'bridge100 deladdr 02:00:00:00:10:01' \
  'guest allowlist mode accepts its configured VM MAC'

reset_logs
invoke_guard vm-mac-change "${config_guest_allowlist}" run
assert_no_action 'guest allowlist mode fails closed after an unconfigured VM MAC change'

reset_logs
invoke_guard host-mac-change "${config_auto}" run
assert_action 'bridge100 deladdr 02:00:00:00:10:99' \
  'the current uplink MAC is derived at runtime'

reset_logs
invoke_guard no-guest "${config_auto}" run
assert_no_action 'a vmenet member without learned guest evidence is insufficient'

reset_logs
invoke_guard static-host "${config_auto}" run
assert_no_action 'a static host-MAC FDB entry is never removed'

reset_logs
invoke_guard duplicate-host "${config_auto}" run
assert_no_action 'duplicate host-MAC FDB entries fail closed'

reset_logs
invoke_guard_expect_exit 2 malformed-duplicate-host "${config_auto}" run
assert_no_action 'a truncated duplicate host-MAC row fails closed with an error'

reset_logs
invoke_guard_expect_exit 2 multiple-flags "${config_auto}" run
assert_no_action 'an FDB row with multiple flags fields is rejected as ambiguous'

reset_logs
invoke_guard_expect_exit 2 command-failure "${config_auto}" run
assert_no_action 'a required FDB command failure propagates as a nonzero no-op'

reset_logs
invoke_guard_expect_exit 2 truncated-member "${config_auto}" run
assert_no_action 'a truncated bridge member record fails closed with an error'

reset_logs
invoke_guard_expect_exit 2 multiple-ether "${config_auto}" run
assert_no_action 'multiple uplink ether records fail closed as ambiguous'

reset_logs
invoke_guard notup-header "${config_auto}" run
assert_no_action 'a NOTUP header token is not accepted as the exact UP flag'

reset_logs
invoke_guard_expect_exit 2 duplicate-header-flags "${config_auto}" run
assert_no_action 'duplicate bridge header flag tokens fail closed as ambiguous'

reset_logs
invoke_guard_expect_exit 2 trailing-member-field "${config_auto}" run
assert_no_action 'a member record with trailing unknown fields fails closed'

reset_logs
invoke_guard_expect_exit 2 malformed-member-prefix "${config_auto}" run
assert_no_action 'an unrecognized member-prefixed record fails closed'

reset_logs
invoke_guard_expect_exit 2 malformed-status "${config_auto}" run
assert_no_action 'a malformed uplink status record fails closed with an error'

reset_logs
invoke_guard extra-member "${config_auto}" run
assert_no_action 'a bridge with an additional non-vmenet member is ambiguous'

reset_logs
invoke_guard multi-candidate "${config_auto}" run
assert_no_action 'auto bridge selection fails closed when multiple bridges qualify'

reset_logs
invoke_guard multi-candidate "${config_bridge_allowlist}" run
assert_action 'bridge102 deladdr 02:00:00:00:10:01' \
  'a bridge allowlist resolves an otherwise ambiguous topology'

reset_logs
invoke_guard second-candidate-race "${config_auto}" run
assert_no_action 'a second eligible bridge appearing before mutation fails closed'

reset_logs
invoke_guard multi-vmenet "${config_auto}" run
assert_action 'bridge100 deladdr 02:00:00:00:10:01' \
  'multiple VMs on one bridge still cause exactly one host-MAC deletion'

reset_logs
invoke_guard single-digit-mac "${config_auto}" run
assert_action 'bridge100 deladdr 02:00:00:00:10:01' \
  'single-digit ifconfig MAC octets are normalized before comparison and deletion'

print -- "1..${test_count}"

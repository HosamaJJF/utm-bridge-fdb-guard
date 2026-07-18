#!/bin/zsh -f

emulate -L zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
umask 022

readonly ROOT="${0:A:h:h}"
readonly VERSION="$(<"${ROOT}/VERSION")"
readonly NAME="utm-bridge-fdb-guard-${VERSION}"
readonly DIST="${ROOT}/dist"

typeset allow_dirty=0
if [[ "${1:-}" == "--allow-dirty" ]]; then
  allow_dirty=1
  shift
fi
(( $# == 0 )) || {
  print -u2 'Usage: ./scripts/package.zsh [--allow-dirty]'
  exit 2
}

[[ "${VERSION}" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || {
  print -u2 "Invalid VERSION: ${VERSION}"
  exit 1
}

typeset archive_epoch="${SOURCE_DATE_EPOCH:-}"
typeset git_repo=0
if /usr/bin/git -C "${ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_repo=1
  if (( allow_dirty == 0 )); then
    /usr/bin/git -C "${ROOT}" diff --quiet || {
      print -u2 'Refusing to package unstaged changes; commit or use --allow-dirty for local testing.'
      exit 1
    }
    /usr/bin/git -C "${ROOT}" diff --cached --quiet || {
      print -u2 'Refusing to package staged changes; commit or use --allow-dirty for local testing.'
      exit 1
    }
  fi
  [[ -n "${archive_epoch}" ]] || \
    archive_epoch="$(/usr/bin/git -C "${ROOT}" log -1 --format=%ct 2>/dev/null || true)"
  current_tag="$(/usr/bin/git -C "${ROOT}" describe --tags --exact-match HEAD 2>/dev/null || true)"
  if [[ -n "${current_tag}" && "${current_tag}" != "v${VERSION}" ]]; then
    print -u2 -- "HEAD tag ${current_tag} does not match VERSION ${VERSION}."
    exit 1
  fi
fi
[[ -n "${archive_epoch}" ]] || archive_epoch="$(/bin/date +%s)"
[[ "${archive_epoch}" == <-> ]] || {
  print -u2 -- "Invalid SOURCE_DATE_EPOCH: ${archive_epoch}"
  exit 1
}
archive_stamp="$(/bin/date -r "${archive_epoch}" '+%Y%m%d%H%M.%S')"

typeset temp_dir
temp_dir="$(/usr/bin/mktemp -d /private/tmp/utm-bridge-fdb-guard.package.XXXXXX)" || exit 1
trap '/bin/rm -rf "${temp_dir}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

/bin/mkdir -p "${DIST}" "${temp_dir}/${NAME}"
for path in .github .gitignore CHANGELOG.md LICENSE README.md README.zh-CN.md VERSION bin docs launchd scripts tests; do
  source_special="$(/usr/bin/find "${ROOT}/${path}" ! -type d ! -type f -print -quit)"
  [[ -z "${source_special}" ]] || {
    print -u2 -- "Refusing to package a symbolic link or special file: ${source_special}"
    exit 1
  }
  /bin/cp -R "${ROOT}/${path}" "${temp_dir}/${NAME}/"
done

archive_special="$(/usr/bin/find "${temp_dir}/${NAME}" ! -type d ! -type f -print -quit)"
[[ -z "${archive_special}" ]] || {
  print -u2 -- "Refusing to package a symbolic link or special file: ${archive_special}"
  exit 1
}

if (( git_repo == 1 && allow_dirty == 0 )); then
  readonly expected_files="${temp_dir}/expected-files.txt"
  readonly packaged_files="${temp_dir}/packaged-files.txt"
  /usr/bin/git -C "${ROOT}" ls-files | LC_ALL=C /usr/bin/sort >| "${expected_files}"
  (
    cd "${temp_dir}/${NAME}" || exit 1
    /usr/bin/find . -type f -print | /usr/bin/sed 's|^\./||' | LC_ALL=C /usr/bin/sort >| "${packaged_files}"
  )
  if ! /usr/bin/cmp -s "${expected_files}" "${packaged_files}"; then
    print -u2 'Release package file list does not match the tracked commit:'
    /usr/bin/diff -u "${expected_files}" "${packaged_files}" >&2 || true
    exit 1
  fi
fi

/bin/chmod -RN "${temp_dir}/${NAME}"
/usr/bin/xattr -cr "${temp_dir}/${NAME}"
/usr/bin/find "${temp_dir}/${NAME}" -exec /usr/bin/touch -h -t "${archive_stamp}" {} +

readonly archive_file_list="${temp_dir}/archive-files.txt"
(
  cd "${temp_dir}" || exit 1
  export LC_ALL=C
  /usr/bin/find "${NAME}" -print | /usr/bin/sort >| "${archive_file_list}"
)

export COPYFILE_DISABLE=1
/usr/bin/tar -C "${temp_dir}" -czf "${DIST}/${NAME}.tar.gz" \
  --format ustar \
  --uid 0 --gid 0 --uname root --gname wheel \
  --no-acls --no-xattrs --no-fflags \
  --no-recursion \
  --options 'gzip:!timestamp' \
  -T "${archive_file_list}"
(
  cd "${DIST}" || exit 1
  /usr/bin/shasum -a 256 "${NAME}.tar.gz" >| SHA256SUMS
)
print "Created ${DIST}/${NAME}.tar.gz"
print "Created ${DIST}/SHA256SUMS"

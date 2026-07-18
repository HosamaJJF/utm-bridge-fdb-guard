#!/bin/zsh -f

emulate -L zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL

readonly logger_log="${UTM_BRIDGE_GUARD_MOCK_LOGGER_LOG:?UTM_BRIDGE_GUARD_MOCK_LOGGER_LOG is required}"
print -r -- "${(j:|:)@}" >> "${logger_log}"

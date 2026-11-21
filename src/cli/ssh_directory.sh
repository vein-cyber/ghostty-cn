# GhosttyCN remote directory integration v1. Fixed application-owned payload.
# Runs only for an interactive SSH shell, never for a user remote command.
ghosttycn_shell=${SHELL:-/bin/sh}
case ${ghosttycn_shell##*/} in
  bash)
    # Bash 3 (including macOS /bin/bash) does not support this POSIX ENV
    # injection path. Preserve its normal login startup rather than breaking it.
    "$ghosttycn_shell" --noprofile --norc -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]' </dev/null 2>/dev/null || exec "$ghosttycn_shell" -l
    ;;
  zsh) ;;
  *) exec "$ghosttycn_shell" -l ;;
esac
for ghosttycn_tool in mktemp cat rm rmdir od tr sed; do
  command -v "$ghosttycn_tool" >/dev/null 2>&1 || exec "$ghosttycn_shell" -l
done
# Restrict only file creation, never the interactive session or fallback shell.
# Subshells also preserve non-default masks and changes made by startup files.
ghosttycn_dir=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/ghosttycn-ssh-XXXXXXXXXX") || exec "$ghosttycn_shell" -l
ghosttycn_cleanup() {
  # Exact files in the directory we just created; no recursive deletion.
  rm -f -- "$ghosttycn_dir/report" "$ghosttycn_dir/bash-env" "$ghosttycn_dir/.zshenv"
  rmdir -- "$ghosttycn_dir" 2>/dev/null || :
}
trap ghosttycn_cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
ghosttycn_write_files() {
  cat > "$ghosttycn_dir/report" <<'GHOSTTYCN_REPORT' || return
# GHOSTTYCN_DIRECTORY_REPORT
GHOSTTYCN_REPORT
  cat > "$ghosttycn_dir/bash-env" <<'GHOSTTYCN_BASH' || return
# Bash POSIX ENV injection preserves the actual login-shell flag, then restores
# normal Bash semantics before loading the normal login startup sequence.
if [ "${GHOSTTYCN_ENV_PRESENT-}" = x ]; then
  builtin export ENV="$GHOSTTYCN_ORIGINAL_ENV"
else
  builtin unset ENV
fi
builtin unset GHOSTTYCN_ENV_PRESENT GHOSTTYCN_ORIGINAL_ENV
builtin set +o posix
builtin shopt -u inherit_errexit 2>/dev/null
if [ "${GHOSTTYCN_UNEXPORT_HISTFILE-}" = 1 ]; then
  builtin export -n HISTFILE
fi
builtin unset GHOSTTYCN_UNEXPORT_HISTFILE
if [ -r /etc/profile ]; then builtin source /etc/profile; fi
for __ghosttycn_profile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
  if [ -r "$__ghosttycn_profile" ]; then
    builtin source "$__ghosttycn_profile"
    break
  fi
done
builtin source "$GHOSTTYCN_BOOTSTRAP_DIR/report"
builtin unset __ghosttycn_profile GHOSTTYCN_BOOTSTRAP_DIR
GHOSTTYCN_BASH
  cat > "$ghosttycn_dir/.zshenv" <<'GHOSTTYCN_ZSHENV' || return
if [[ ${GHOSTTYCN_ZDOTDIR_PRESENT-} == x ]]; then
  builtin export ZDOTDIR="$GHOSTTYCN_ORIGINAL_ZDOTDIR"
else
  builtin unset ZDOTDIR
fi
[[ ! -r ${ZDOTDIR-$HOME}/.zshenv ]] || builtin source -- "${ZDOTDIR-$HOME}/.zshenv"
# Do not switch ZDOTDIR back: let zsh load all remaining global/user startup
# files natively with the real directory (including compinit and HISTFILE).
# A one-shot scheduled function runs at the first prompt after startup, even
# when plugins replace precmd_functions in .zshrc. No commands enter stdin.
builtin unset GHOSTTYCN_ZDOTDIR_PRESENT GHOSTTYCN_ORIGINAL_ZDOTDIR
if builtin zmodload zsh/sched 2>/dev/null; then
  _ghosttycn_directory_init() {
    builtin source -- "$GHOSTTYCN_BOOTSTRAP_DIR/report"
    builtin unset GHOSTTYCN_BOOTSTRAP_DIR
    builtin unfunction _ghosttycn_directory_init
  }
  builtin sched +0 _ghosttycn_directory_init
else
  # An unusually minimal zsh still logs in normally without directory reports.
  builtin unset GHOSTTYCN_BOOTSTRAP_DIR
fi
GHOSTTYCN_ZSHENV
}
if ! (umask 077; ghosttycn_write_files); then
  ghosttycn_cleanup
  trap - 0
  exec "$ghosttycn_shell" -l
fi
export GHOSTTYCN_BOOTSTRAP_DIR="$ghosttycn_dir"
case ${ghosttycn_shell##*/} in
  bash)
    export GHOSTTYCN_ENV_PRESENT=${ENV+x}
    export GHOSTTYCN_ORIGINAL_ENV=${ENV-}
    if [ -z "${HISTFILE+x}" ]; then
      export HISTFILE="$HOME/.bash_history" GHOSTTYCN_UNEXPORT_HISTFILE=1
    fi
    ENV="$ghosttycn_dir/bash-env" "$ghosttycn_shell" --noprofile --posix -il
    ;;
  zsh)
    export GHOSTTYCN_ZDOTDIR_PRESENT=${ZDOTDIR+x}
    export GHOSTTYCN_ORIGINAL_ZDOTDIR=${ZDOTDIR-}
    ZDOTDIR="$ghosttycn_dir" "$ghosttycn_shell" -il
    ;;
esac
exit "$?"

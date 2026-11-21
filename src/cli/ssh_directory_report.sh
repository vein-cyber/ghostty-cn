# Session-only Bash/Zsh hook shared by automatic setup and troubleshooting.
_ghosttycn_report_pwd() {
  local ghosttycn_exit_status=$?
  local encoded
  encoded=$(printf '%s' "${PWD#/}" | od -An -v -tx1 | tr -d ' \n' | sed 's/../%&/g')
  printf '\033]7;file://ghosttycn-remote.invalid/%s\007' "$encoded"
  return "$ghosttycn_exit_status"
}
if [ -n "${BASH_VERSION-}" ]; then
  if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
    [[ " ${PROMPT_COMMAND[*]} " == *" _ghosttycn_report_pwd "* ]] || PROMPT_COMMAND+=(_ghosttycn_report_pwd)
  elif [[ ${PROMPT_COMMAND-} != *"_ghosttycn_report_pwd"* ]]; then
    PROMPT_COMMAND="${PROMPT_COMMAND-}"$'\n''_ghosttycn_report_pwd'
  fi
elif [ -n "${ZSH_VERSION-}" ]; then
  typeset -ga precmd_functions
  (( ${precmd_functions[(Ie)_ghosttycn_report_pwd]} )) || precmd_functions+=(_ghosttycn_report_pwd)
fi
_ghosttycn_report_pwd

# ── Tab completion of ned's and nedfmt's options in bash, zsh and fish: `ned --completions SHELL` prints the
#    script. The options come from the program's own --help when Tab is pressed, so the script never goes stale ──

const
  # (the option column of --help: each line that starts "  -", up to its two spaces; "--out:FILE" as "--out:")
  ComplOpts = """"$1" --help 2>/dev/null | sed -n 's/^  \(-[^ ].*\)/\1/p' | sed 's/  .*//; s/:[^ ,]*/:/g' | tr ', ' '\n\n' | grep '^-'"""

  ComplBash = """# ned's and nedfmt's options for bash's Tab: ned --completions bash > ~/.local/share/bash-completion/completions/ned
__ned_opts() { """ & ComplOpts & """; }
_ned() {
  local cur=${COMP_WORDS[COMP_CWORD]}
  if [[ $cur == -* ]]; then
    COMPREPLY=($(compgen -W "$(__ned_opts "${COMP_WORDS[0]}")" -- "$cur"))
    [[ ${#COMPREPLY[@]} == 1 && ${COMPREPLY[0]} == *: ]] && compopt -o nospace
  else
    COMPREPLY=($(compgen -f -- "$cur"))
  fi
}
complete -o filenames -o bashdefault -F _ned ned nedfmt
"""

  ComplZsh = """#compdef ned nedfmt
# ned's and nedfmt's options for zsh's Tab: ned --completions zsh > "${fpath[1]}/_ned" (a folder on $fpath)
__ned_opts() { """ & ComplOpts & """; }
if [[ $PREFIX == -* ]]; then
  local -a opts
  opts=(${(f)"$(__ned_opts $words[1])"})
  compadd -a opts
else
  _files
fi
"""

  ComplFish = """# ned's and nedfmt's options for fish's Tab: ned --completions fish > ~/.config/fish/completions/ned.fish
function __ned_opts
    set -l prog (commandline -opc)[1]
    command $prog --help 2>/dev/null | string replace -rf '^  (-\S.*)' '$1' | string replace -r '  .*' '' |
        string replace -ra ':[^ ,]*' ':' | string split ' ' | string trim -c ',' | string match -- '-*'
end
for prog in ned nedfmt
    complete -c $prog -n 'string match -q -- "-*" (commandline -ct)' -a '(__ned_opts)'
end
"""

proc shellCompletion(shell: string): string =
  ## the completion script for a shell (bash, zsh, fish), "" for one ned has none for
  case shell.toLowerAscii
  of "bash": ComplBash
  of "zsh": ComplZsh
  of "fish": ComplFish
  else: ""

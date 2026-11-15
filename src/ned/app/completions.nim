# ── Tab completion of ned's and nedfmt's options in bash, zsh, fish, PowerShell and nushell: `ned --completions
#    SHELL` prints the script. The options come from the program's own --help when Tab is pressed, so the script
#    never goes stale ──

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

  ComplPwsh = """# ned's and nedfmt's options for PowerShell's Tab — in your profile ($PROFILE):
#   ned --completions pwsh | Out-String | Invoke-Expression
foreach ($__nedProg in 'ned', 'nedfmt') {
  Register-ArgumentCompleter -Native -CommandName $__nedProg -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    if (-not "$wordToComplete".StartsWith('-')) { return }
    $exe = $commandAst.CommandElements[0].Extent.Text
    & $exe --help 2>$null | ForEach-Object {
      if ($_ -match '^  (-\S.*)') {
        (($Matches[1] -replace '  .*', '') -replace ':[^ ,]*', ':') -split '[, ]+' | Where-Object { $_ -like '-*' }
      }
    } | Where-Object { $_ -like "$wordToComplete*" } | Select-Object -Unique | ForEach-Object {
      [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterName', $_)
    }
  }
}
"""

  ComplNu = """# ned's and nedfmt's options for nushell's Tab (with what completed other programs before, kept):
#   ned --completions nu | save -f ($nu.default-config-dir | path join ned.nu)   then in config.nu: source ned.nu
let __ned_prev = $env.config.completions.external.completer?
$env.config.completions.external.completer = {|spans|
  let word = ($spans | last)
  if (($spans | first | path basename) in ['ned' 'nedfmt']) and ($word | str starts-with '-') {
    ^($spans | first) --help | lines | where {|l| $l =~ '^  -\S' } | each {|l|
      $l | str substring 2.. | split row '  ' | first | str replace -ra ':[^ ,]*' ':' | split row -r '[, ]+'
    } | flatten | where {|o| ($o | str starts-with '-') and ($o | str starts-with $word) } | uniq
  } else if $__ned_prev != null { do $__ned_prev $spans } else { null }
}
"""

proc shellCompletion(shell: string): string =
  ## the completion script for a shell (bash, zsh, fish, pwsh or powershell, nu or nushell), "" for one ned has
  ## none for
  case shell.toLowerAscii
  of "bash": ComplBash
  of "zsh": ComplZsh
  of "fish": ComplFish
  of "pwsh", "powershell": ComplPwsh
  of "nu", "nushell": ComplNu
  else: ""

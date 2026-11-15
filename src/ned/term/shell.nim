# ── shell integration: the shell marks each prompt, command line, output and exit code (OSC 133), and says the
#    folder it is in (OSC 7) ──

const NedBashSI = """# ned: shell integration (OSC 133 marks: prompt, command, output, exit code). Made by ned, read by bash.
if [ -z "$__ned_si" ]; then
  __ned_si=1
  [ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"
  __ned_si_prompt() { local s=$?; printf '\033]133;D;%s\007\033]7;file://%s\007\033]133;A\007' "$s" "$PWD"; return $s; }
  __ned_si_ps1() { case "$PS1" in *'133;B'*) ;; *) PS1="$PS1"'\[\033]133;B\007\]' ;; esac; }
  if [ "$(declare -p PROMPT_COMMAND 2>/dev/null | cut -c1-10)" = "declare -a" ]; then
    PROMPT_COMMAND=(__ned_si_prompt "${PROMPT_COMMAND[@]}" __ned_si_ps1)
  else
    PROMPT_COMMAND="__ned_si_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}; __ned_si_ps1"
  fi
  PS0="${PS0}"$'\033]133;C\007'
fi
"""

const NedZshEnv = """# ned: shell integration — your own .zshenv, then ned's .zshrc (which reads yours)
__ned_si_dir="$ZDOTDIR"
ZDOTDIR="${NED_USER_ZDOTDIR:-$HOME}"
[[ -r "$ZDOTDIR/.zshenv" ]] && source "$ZDOTDIR/.zshenv"
NED_USER_ZDOTDIR="$ZDOTDIR"
ZDOTDIR="$__ned_si_dir"
"""

const NedZshRc = """# ned: shell integration (OSC 133 marks: prompt, command, output, exit code). Made by ned, read by zsh.
ZDOTDIR="$NED_USER_ZDOTDIR"
unset NED_USER_ZDOTDIR __ned_si_dir
[[ -r "$ZDOTDIR/.zshrc" ]] && source "$ZDOTDIR/.zshrc"
__ned_si_precmd() { local s=$?; print -rn -- $'\e]133;D;'"$s"$'\a\e]7;file://'"$PWD"$'\a\e]133;A\a'; return $s }
__ned_si_b() { [[ "$PS1" == *'133;B'* ]] || PS1="$PS1"$'%{\e]133;B\a%}' }
__ned_si_preexec() { print -rn -- $'\e]133;C\a' }
precmd_functions=(__ned_si_precmd $precmd_functions __ned_si_b)
preexec_functions+=(__ned_si_preexec)
"""

const NedFishSI = """# ned: shell integration (OSC 133 marks: prompt, command, output, exit code). Made by ned, read by fish.
function __ned_si_prompt --on-event fish_prompt
    printf '\e]133;D;%s\a\e]7;file://%s\a\e]133;A\a' "$__ned_si_status" "$PWD"
end
function __ned_si_pre --on-event fish_preexec
    printf '\e]133;C\a'
end
function __ned_si_post --on-event fish_postexec
    set -g __ned_si_status $status
end
if functions -q fish_prompt; and not functions -q __ned_si_orig_prompt
    functions -c fish_prompt __ned_si_orig_prompt
    function fish_prompt
        __ned_si_orig_prompt
        printf '\e]133;B\a'
    end
end
"""

# (the POSIX shells — sh, dash, ash, ksh, mksh, yash … — have no hook before a command: the prompt marks where each
#  one ends and how; the terminal takes the Enter it sends for where the next one starts. The marks go to the
#  terminal itself, not into the prompt, so a line editor does not count them as columns)
const NedShSI = """# ned: shell integration (OSC 133 marks: the prompt and the exit code). Made by ned, read through $ENV.
if [ -z "$__ned_si" ]; then
  __ned_si=1
  if [ -n "$NED_USER_ENV" ]; then export ENV="$NED_USER_ENV"; else unset ENV; fi
  __ned_si_rc="$NED_SI_RC"
  unset NED_USER_ENV NED_SI_RC
  if [ -n "$__ned_si_rc" ] && [ -r "$__ned_si_rc" ]; then . "$__ned_si_rc"; fi
  __ned_si_mark() { printf '\033]133;D;%s\007\033]7;file://%s\007\033]133;A\007' "$1" "$PWD" > /dev/tty; }
  case "$PS1" in *__ned_si_mark*) ;; *) PS1='$(__ned_si_mark $?)'"${PS1-\$ }" ;; esac
fi
"""

const NedElvishSI = """# ned: shell integration (OSC 133 marks: prompt, command, output, exit code). Made by ned, read by elvish
# in place of your rc.elv, which it reads first.
use os
var __ned_rc = ~/.config/elvish/rc.elv
if (has-env XDG_CONFIG_HOME) { set __ned_rc = $E:XDG_CONFIG_HOME/elvish/rc.elv }
if (not (os:exists $__ned_rc)) { set __ned_rc = ~/.elvish/rc.elv }
if (os:exists $__ned_rc) {
  eval &on-end={|ns| var m = [&]; for k [(keys $ns)] { set m[$k] = $ns[$k] }; edit:add-vars $m } (slurp < $__ned_rc)
}
var __ned_code = 0
set edit:before-readline = [$@edit:before-readline {|| print "\e]133;D;"$__ned_code"\a\e]7;file://"$pwd"\a\e]133;A\a" }]
set edit:after-readline = [$@edit:after-readline {|line| if (not-eq $line '') { print "\e]133;C\a" } }]
set edit:after-command = [$@edit:after-command {|m| if (eq $m[error] $nil) { set __ned_code = 0 } else { set __ned_code = 1 } }]
"""

const NedXonshSI = """# ned: shell integration (OSC 133 marks: prompt, command, output, exit code). Made by ned, read by xonsh in
# place of your rc files, which it reads first.
import os as __ned_os, glob as __ned_glob
__ned_cfg = __ned_os.environ.get("XDG_CONFIG_HOME", __ned_os.path.expanduser("~/.config"))
for __ned_f in ["/etc/xonsh/xonshrc", __ned_os.path.join(__ned_cfg, "xonsh", "rc.xsh")] + \
               sorted(__ned_glob.glob(__ned_os.path.join(__ned_cfg, "xonsh", "rc.d", "*.xsh"))) + \
               [__ned_os.path.expanduser("~/.xonshrc")]:
    if __ned_os.path.isfile(__ned_f):
        source @(__ned_f)
__ned_code = 0
@events.on_postcommand
def __ned_si_post(cmd, rtn, out, ts, **kw):
    global __ned_code
    __ned_code = rtn
@events.on_precommand
def __ned_si_pre(cmd, **kw):
    print("\x1b]133;C\x07", end="", flush=True)
@events.on_pre_prompt
def __ned_si_prompt(**kw):
    print("\x1b]133;D;%s\x07\x1b]7;file://%s\x07\x1b]133;A\x07" % (__ned_code, __ned_os.getcwd()), end="", flush=True)
"""

const NedPwshSI = """# ned: shell integration (OSC 133 marks: prompt, command, output, exit code). Made by ned, read by PowerShell
# after your profile.
if (-not $Global:__NedSI) {
  $Global:__NedSI = $true
  $Global:__NedPrompt = $function:prompt
  function Global:prompt {
    $code = if ($global:?) { 0 } elseif ($global:LASTEXITCODE) { $global:LASTEXITCODE } else { 1 }
    $e = [char]27; $a = [char]7
    "$e]133;D;$code$a$e]133;A$a" + (& $Global:__NedPrompt) + "$e]133;B$a"
  }
  if (Test-Path Function:\PSConsoleHostReadLine) {
    $Global:__NedReadLine = $function:PSConsoleHostReadLine
    function Global:PSConsoleHostReadLine {
      $line = & $Global:__NedReadLine
      [Console]::Write("$([char]27)]133;C$([char]7)")
      $line
    }
  }
}
"""

func shellFamily(shell: string): string =
  ## which kind of shell a program is, by its name: bash, zsh, fish, sh (dash, ash, ksh, mksh, yash …), elvish,
  ## xonsh, pwsh, cmd — or "" (nushell sends the marks itself)
  var name = extractFilename(shell).toLowerAscii
  if name.endsWith(".exe"): name.setLen(name.len - 4)
  if name.startsWith("bash"): return "bash"
  if name.startsWith("zsh"): return "zsh"
  if name.startsWith("fish"): return "fish"
  if name in ["sh", "dash", "ash", "busybox", "ksh", "ksh93", "mksh", "lksh", "oksh", "loksh", "pdksh", "yash"]:
    return "sh"
  if name in ["elvish", "xonsh"]: return name
  if name in ["pwsh", "powershell"]: return "pwsh"
  if name == "cmd": return "cmd"
  ""

proc shellIntegration(shell: string): (seq[string], seq[(string, string)]) =
  ## the arguments and environment that make the shell send OSC 133 marks (its own startup files are still read);
  ## nothing for a shell ned does not know
  if not cfgTermIntegration: return
  let name = extractFilename(shell)
  let fam = shellFamily(shell)
  let dir = privDir() / "shell"
  try:
    createDir(dir)
    case fam
    of "sh":
      # (through $ENV, which they read when interactive; yash reads its rc file, given by name)
      writeFile(dir / "sh.sh", NedShSI)
      let n = name.toLowerAscii
      let home = getHomeDir().strip(leading = false, chars = {'/'})
      let rc = if getEnv("ENV").len > 0: getEnv("ENV")
               elif n.startsWith("ksh"): home / ".kshrc"
               elif n in ["mksh", "lksh"]: home / ".mkshrc"
               elif n == "yash": home / ".yashrc"
               else: ""
      if n == "yash":
        return (@["--rcfile=" & dir / "sh.sh"], @[("NED_SI_RC", rc), ("NED_USER_ENV", getEnv("ENV"))])
      return (@[], @[("ENV", dir / "sh.sh"), ("NED_SI_RC", rc), ("NED_USER_ENV", getEnv("ENV"))])
    of "elvish":
      writeFile(dir / "ned.elv", NedElvishSI)
      return (@["-rc", dir / "ned.elv"], @[])
    of "xonsh":
      writeFile(dir / "ned.xsh", NedXonshSI)
      return (@["--rc", dir / "ned.xsh", "-i"], @[])
    of "pwsh":
      writeFile(dir / "ned.ps1", NedPwshSI)
      return (@["-NoExit", "-Command", "try { . '" & (dir / "ned.ps1").replace("'", "''") & "' } catch {}"], @[])
    of "cmd":
      # (cmd.exe's prompt can carry escapes ($E), not an exit code: the commands are marked, their codes unknown)
      let p = getEnv("PROMPT", "$P$G")
      if "133;" in p: return
      return (@[], @[("PROMPT", "$E]133;D$E\\$E]133;A$E\\" & p & "$E]133;B$E\\")])
    else: discard
    if name.startsWith("bash"):
      writeFile(dir / "bash.sh", NedBashSI)
      return (@["--init-file", dir / "bash.sh"], @[])
    if name.startsWith("zsh"):
      createDir(dir / "zsh")
      writeFile(dir / "zsh" / ".zshenv", NedZshEnv)
      writeFile(dir / "zsh" / ".zshrc", NedZshRc)
      let user = getEnv("ZDOTDIR", getHomeDir().strip(leading = false, chars = {'/'}))
      return (@[], @[("ZDOTDIR", dir / "zsh"), ("NED_USER_ZDOTDIR", user)])
    if name.startsWith("fish"):
      writeFile(dir / "fish.fish", NedFishSI)
      return (@["--init-command", "source " & quoteShell(dir / "fish.fish")], @[])
  except CatchableError: discard

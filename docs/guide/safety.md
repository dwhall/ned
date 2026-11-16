# Safety: how ned protects your work

- **Atomic saves**: ned writes a temporary file next to the original, flushes it to storage (`fsync`) and
  renames it over the original, keeping permissions — a crash or power loss leaves the old or the new file,
  never half of one. Hard-linked files are written in place; symlinks are followed.
- **Recovery files**: unsaved edits are written to a private recovery file about a second after you stop
  typing (files over 20 000 lines at most every 20 s, over 300 000 lines not at all); each ned process has its own, so two sessions never overwrite each other's. If ned crashes, Termux kills the session, the ssh connection drops (SIGHUP/SIGTERM) or the
  battery dies, the next start offers *Restore*. *File › Recover unsaved edits…* lists everything.
- **Local history**: every save keeps the previous version (last 60 per file). *File › Local history…* shows
  each version as a diff against the current text and restores it with one click. Agent edits and
  project-wide replaces are saved the same way, so they can always be undone.
- **No silent overwrites**: if a file changed on disk since you opened it, saving asks whether to overwrite or
  reload; if another running ned has unsaved edits to the same file, you are warned.
- **Binary files** open in the hex editor: what you type changes only the bytes you type over (or insert), saving
  writes the bytes as they are (a new file renamed over the old one, its permissions kept); binary files over
  512 MB are refused.
- **Huge text files** — over `editor.viewerSize` (512 MB): a log, a dump — open in the large-file viewer, read-only,
  with a window of their lines in memory: where every 1024th line starts is indexed in the background, so scrolling,
  Go to line, Ctrl+End, Find and F3 (through the whole file, in the background) reach any line, and Copy copies from
  it; the status bar says *Ln 1 000 000 of 30 000 000*.
- **Libraries open read-only**: files of the Nim toolchain (the standard library, the compiler) and of installed
  nimble packages — where go to definition often lands — cannot be changed by a stray key; *Read-only* in the
  status bar (or *File: allow editing this file*) unlocks one. The project you have open is never locked.
  `files.protectLibraries: false` turns it off.
- **Folder trust**: a folder you open is not trusted until you run *Workspace: trust this folder* (or press
  *Trust* on the notice, or *⛉ Not trusted* in the status bar). Until then ned's own Nim and C engines read and
  check its code, but nothing in it runs — not the Nim compiler (its `config.nims` and macros can run commands),
  nimble, nimsuggest, its tests or the program — and its project settings that run programs (`lsp`, `run`,
  `run.configs`, `formatters`, `languages`, `debug.adapters`, `repl.commands`, `terminal.shell`, `keys`,
  `vim.keys`, `vim.visualKeys`, `helix.keys`, `editor.keymap`, `commands`, `ai.*` including MCP servers, `nim.nimsuggestPath`, `sync.repository`) are ignored, so
  opening a cloned repository cannot start programs or redirect your code (or your settings) somewhere else. A
  project ned creates for you, the Nim toolchain's own files and nimble packages are trusted;
  `security.folderTrust: off` trusts every folder.
- **Secrets stay put**: API keys and MCP server tokens are never put on a command line; *Settings sync* leaves
  them out of what it exports; a remote folder's ssh password or passphrase is asked by ssh itself, in the
  terminal; a settings repository URL with a token in it is refused.
- **Secrets kept from the AI**: what ned sends to an AI provider — the file, the chat, what the agent reads, inline
  suggestions — has its API keys, tokens, private keys and passwords (in `.env` lines, settings, connection strings,
  URLs) replaced with placeholders such as `[REDACTED:api-key#1]`; where the assistant writes a placeholder into a
  file, ned puts the secret back. Files of secrets — `.env`, `*.pem`, `id_ed25519`, `credentials.json`, and what the
  project's `.gitignore` keeps out for its secrets — are not sent at all. `ai.redactSecrets` (on) — see
  [the AI assistant](ai.md#secrets).
- **The assistant's commands in a sandbox** (Linux 5.13 and newer, `ai.sandbox`): a command the assistant runs, and
  one an ACP agent asks ned to run, reads the system, Nim and the project, changes files only in the project, the
  caches and a temporary folder of its own, has no network (`"net"` gives it one) and gets none of the API keys and
  tokens in your environment — so a prompt hidden in a file cannot have it send your code or keys away, or change
  your other files. Where there is no Landlock (Android, macOS, Windows) it runs as you — so there ned asks before
  each command even with `ai.autoApprove` at `all`, and says why (`ai.sandbox` off: it does not).
- **Agents in a sandbox** (Linux 5.13 and newer, `ai.agentSandbox`, off by default): an ACP agent itself — Claude
  Agent, Codex, Gemini CLI, Copilot — runs in it too, with the network and its keys, changing files only in the
  project, the caches, a temporary folder and its own folders in your home ([the AI assistant](ai.md#agents-of-their-own-acp)).
  `ned --sandbox-agent -- claude` runs an agent's own program in it from any terminal.
- **An agent in a worktree** (*AI: agent in a worktree*): the agent works on a branch of its own, and what it asks
  ned to write outside that worktree is refused; its changes reach your files only as you take them, file by file
  ([the AI assistant](ai.md#an-agent-in-a-worktree)).
- **The IDE link for Claude Code and Gemini CLI** (`ai.ideLink`): a server on 127.0.0.1 only; every request must
  carry a random token kept in files only you can read, and one from a web page (an `Origin` header, another `Host`)
  is refused; the files go when ned quits ([the AI assistant](ai.md#claude-code-and-gemini-cli)).
- **Sign-ins to MCP servers** (`ned --mcp-login`): the token is kept in ned's state folder, readable only by you
  (0600), and goes to the server only; the browser's answer comes back on 127.0.0.1, and PKCE makes it useless to
  anyone who sees it.
- **No secrets in a commit** (`git.secretsCheck`): a commit that takes an API key, a token, a password or a file of
  secrets stops first and says where — [Git](git.md#checks-before-a-commit).
- **Plugins in a sandbox** (Linux 5.13 and newer): a plugin's process reads the project and what it needs to run,
  changes files only in its data folder and the project, and has no network, unless you allowed it more — the
  kernel holds it to that (Landlock), whatever its code does. It cannot read your other files (`~/.ssh`, your
  settings) or signal ned, and it does not get the environment's secrets. Nor can it tell ned what to do: ned's
  remote-control socket and the sockets of terminals kept running answer only a program that sends their key, kept
  in a file in ned's private folder, which a plugin in the sandbox cannot read. A plugin you allowed to run
  programs itself runs as before, since those programs could do anything you can — in a process of its own, so the
  other plugins stay in the sandbox; so do all plugins where the kernel has no Landlock (an older Linux, Android,
  macOS). `plugins.sandbox` turns it off. `ned --sandbox CMD…` runs any command
  this way: it may change only the current folder (`--write DIR` adds one, `--net` gives it the network;
  `ned --sandbox --help`).
- **Checked updates**: ned is built from its source with nimble (`ned --update`, `install.sh`), from git over https. A
  release that carries a package — `ned --update` and `install.sh` take a Termux package when there is one — is
  checked before it is installed: its SHA-256 against the release's `SHA256SUMS`, and `SHA256SUMS` against its
  signature (`SHA256SUMS.sig`, made with the release key whose public half is in ned's source,
  `src/ned/app/release-signers`). A package that does not match, or a release without `SHA256SUMS`, is refused and
  nothing is installed. Releases are signed from 6.51 on, and from 6.52 ned has the release key in it: it installs
  only a release signed with it (a ned built before checks only the SHA-256, and says so). Checking a
  signature needs `ssh-keygen` (Termux: `pkg install openssh`). A release you download yourself: `ned --update
  --verify DIR` checks the files in DIR the same way.
- *File › Compare with saved* shows your unsaved changes as a diff.

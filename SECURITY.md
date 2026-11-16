# Security

## Reporting a vulnerability

Please **don't open a public issue** for a security problem. Use the repository's private vulnerability
reporting (the *Security* tab › *Report a vulnerability*) and include what an attacker could do, the steps or a
file that shows it, and ned's version (`ned --version`). You will get an answer within a week; a fix for a real
problem is released as soon as it is ready, and you are credited unless you would rather not be.

Only the newest release gets security fixes — updating is always the remedy.

## What counts

- Opening a file or a folder makes ned run something it should not. Until you trust a folder (*Workspace: trust
  this folder*), none of its Nim code may run — not through the Nim compiler (which runs `config.nims` and macros),
  nimble, nimsuggest or its tests — nor the programs its own settings name (language servers, run commands,
  formatters, MCP servers); only ned's own engines read it.
- A secret leaks: an API key, an SSH password or passphrase, a token in a git link — into a command line other
  programs can read, a log, a temporary file others can read, the settings-sync repository, or a crash report.
- A file is written outside where it should be (a theme, a dictionary, an imported setting, a clone's folder),
  or a save can lose or corrupt your file.
- The terminal panel, the markdown preview or a hover lets text from a file send escape sequences to your terminal.

## How ned protects you (and what to check when you change it)

- **API keys are never put on command lines or logged.** They go to the AI provider in the request only; an MCP
  server's `env` values go to that server's own environment only. Settings sync leaves keys and tokens out.
- **SSH**: passwords and passphrases are typed into ssh in the terminal, never passed on a command line.
- **git clone** refuses a link with a login or token written into it (it would stay in `.git/config`); git asks
  for the login in the terminal instead.
- **Unsaved text that is checked** (`nim check`, C compilers, formatters) goes to private temporary files in a
  folder only you can read (0700), removed afterwards; old ones are swept at start-up.
- **Saves are atomic** (a temporary file renamed over the original, permissions kept), unsaved edits have
  recovery files, and the standard library and installed packages open read-only.
- **Folder trust** (`security.folderTrust`): in a folder not trusted yet, every program ned starts goes through one
  gate (`spawnProc`) that refuses the Nim toolchain — the compiler, nimble, nimsuggest, nimlangserver, testament,
  atlas, nimony — also inside `sh -c`, behind `env`, `nice`, `timeout` and the like, and says why (`--version` and
  `--help` pass). ned's own Nim and C engines still read the code. A folder's own settings that run programs (`.ned/settings.json`: `lsp`, `run`,
  `formatters`, `commands`, `ai.*` with MCP servers, `nim.nimsuggestPath`, `sync.repository` …) are ignored too,
  so opening a cloned repository cannot start programs or send your code elsewhere. A project's plugins
  (`.ned/plugins/`) are not loaded either; yours (`~/.config/ned/plugins/`) run with your rights, like any program
  you install — *Install from git…* refuses a link that starts with `-` and passes it after `--`.
- **git links that start with `-`** are refused wherever ned runs git with a link or a branch (clone, a
  submodule, settings sync, a dependency's tags), and they come after `--`: a link cannot become an option.
- **Tests run on save or before a commit, and the copies check** (`nim.testOnSave`, `git.checksBeforeCommit`,
  `nim.showCopies`) build into private folders (0700), removed afterwards; tests are stopped after two minutes.
- **Signing in to GitHub** never asks for, sees or stores a token: the GitHub CLI signs you in in the browser and
  keeps its token in its own store (git asks it through `gh auth setup-git`), and an SSH key's passphrase is typed
  into `ssh-keygen` in the terminal. Review comments, replies and resolving a thread go through `gh` as well.
- **A second language server** (`lsp.alsoRun`, `lsp.linters`) is started only when it is installed and the folder
  is trusted; a folder's own settings cannot add one (`lsp.alsoRun` is among the settings that need trust).
- **The assistant's plan**: while it plans, it can only read — editing files and running commands are refused,
  not merely asked about. Each step it then takes has a restore point.
- **The assistant's commands** (`ai.sandbox`, Linux): what it runs, and what an ACP agent asks ned to run, goes
  through `ned --sandbox` — files changed only in the project, the caches and its own temporary folder, no
  network, none of the environment's secrets (`sandboxEnv`). Its engine tools (`ai/enginetools`) only read, and
  refuse files of secrets as `read_file` does.
- **MCP servers on the web** (`ai.mcpServers` with a `url`): the headers — a token — come to `ned --mcp-http` in its
  environment and go to curl in a private file (0600), never on a command line; `${NAME}` takes them from the
  environment, so they need not be in the settings. A sign-in (`ned --mcp-login`, `ai/mcpauth`) is OAuth 2.1 with
  PKCE and a state checked: the browser's answer comes to a port on 127.0.0.1 only, the token is kept in the state
  folder (0700, the file 0600) and sent only to that server's address; a refresh token renews it.
- **Where there is no sandbox** (no Landlock): `ai.autoApprove` "all" still asks before each of the assistant's
  commands, unless `ai.sandbox` is off (`aiNoSandbox`).
- **ACP agents in the sandbox** (`ai.agentSandbox`, off by default): the agent's own process under `ned --sandbox
  --net --keep-env` — files changed only in the project, the caches, npm's cache, its temporary folder, its own home
  folder (made when missing) and files, and what its entry adds; it reads the certificates its variables name
  (`agentPolicy`). `ned --sandbox-agent CMD…` is the same policy for an agent run from a terminal.
- **An agent in a worktree** (`ai/worktree`): `fs/write_text_file` outside the conversation's worktree is refused
  (`acpWriteFile`); its changes reach your files only through the review, file by file. The worktree started from
  your uncommitted changes gets them through `git diff HEAD --binary | git apply` and copies of your untracked files
  (those git does not ignore) — nothing of yours is changed.
- **An agent's writes reviewed** (`ai.agentReview`, off): `fs/write_text_file` is answered only after you accept the
  diff (or your edit of it); rejected, the agent gets an error and nothing is written.
- **The IDE link** (`ai.ideLink`, `ai/idelink`): one listening socket on 127.0.0.1, a 128-bit token from the
  system's random source in files only you can read (`~/.claude/ide/PORT.lock`, `$TMPDIR/gemini/ide/…`, 0600; the
  folder 0700 when ned makes it), compared in constant time on every request (WebSocket upgrade:
  `x-claude-code-ide-authorization`; HTTP: `Authorization: Bearer`). A request with an `Origin` header or a `Host`
  other than 127.0.0.1/localhost and its port is refused (a web page, DNS rebinding). Limits: 16 connections, 64 KB
  of headers, 16 MB a body or a message, no chunked bodies, a request not finished in 15 s dropped; masked client
  frames only, control frames of 125 bytes at most. Its tools act as you do in ned: open files, read selections and
  problems, save an open file, show a diff — nothing runs. The files are removed when ned quits; those of neds that
  are gone are swept. The port and token are kept for the next start in ned's private folder (`privDir`: 0700, checked to
  be yours; the file `ide-link` 0600), and used again only while the port is free.
- **GitHub Copilot** (`ai.copilot`): its language server gets the files you edit, not files of secrets
  (`aiSecretFile`); the sign-in is Copilot's own (a code typed on GitHub's page). Its telemetry events are redirected to
  ned (`copilotCapabilities.redirectedTelemetry`) and dropped there, and its telemetry level is "off". The server
  also reaches copilot-telemetry.githubusercontent.com on its own, which no client setting stops, so with
  `ai.copilotNoTelemetry` (on) it is started with `HTTPS_PROXY` set to ned's guard (`ned --net-guard`, `ai/netguard`):
  a process of its own on 127.0.0.1 that answers a CONNECT or a plain request for that host or its subdomains with
  403 and passes the rest on unread — the TLS inside a CONNECT is between the server and GitHub — straight or through
  your proxy (`HTTPS_PROXY`, its user and password sent as Proxy-Authorization). Its limits: 64 KB of request
  headers; it ends when ned does (its standard input closes). Not on Windows.
- **Before a commit** (`git.secretsCheck`): what the commit adds is read for secrets (core/secrets, as for the
  assistant) and for files of secrets; one found stops the commit until you say so.
- **Releases** are signed: `SHA256SUMS.sig` by the key in `src/ned/app/release-signers`
  (`SHA256:YHTcD3V1QUEyI8tpP487NPQ4y0Cap1kZxrGB2S4I/T8`, in ned from 6.52), checked by `ned --update`
  (`releasecheck`) and install.sh. *Git: make a GitHub release…* signs with `git.releaseKey` in the namespace
  `<repository>-release`.
- **A plugin asking the assistant** (`askAi`) needs the "ai" permission: what it sends goes to your provider, with
  your key, its secrets taken out first.
- **AI on this device** talks only to the local server (`ai.localUrl`, 127.0.0.1 by default); a model is
  downloaded only when you pick it, and an install command runs in the terminal where you see it.
- **Termux colours**: ned writes only `~/.termux/colors.properties`, keeping colours of your own beside it
  (`colors.properties.ned-backup`) for *Theme: put Termux's own colours back*.
- **Links** in files (a language server's, or URLs) open only when you ask (F12, Ctrl+click), handed to the
  opener as one argument.
- The fuzzer refuses to run as root unless it is given a user to drop to (`NED_FUZZ_USER`).

#!/usr/bin/env python3
"""The real AI agents in ned's sandbox for agents (ned --sandbox-agent, what ai.agentSandbox uses): each preset —
Claude Agent, Codex, Gemini CLI, GitHub Copilot — started with npx in a home of its own with no keys, as ned starts it,
and asked only what starting needs: initialize and session/new. No prompt is ever sent (no model is asked anything).

  each agent    initialize answered, session/new answered (a session, or the agent's own "sign in first"), not a
                crash; nothing refused by the sandbox (EACCES, EPERM) on its stderr
  its folder    made in the empty home and written there by the agent (its settings or sessions)
  outside       a file the agent was not given (in the home, outside the project) is still as it was

Usage: tagents.py path/to/ned [claude codex gemini copilot]    (needs Node.js with npx, and Linux with Landlock;
skipped with a note otherwise)"""
import json, os, shutil, subprocess, sys, tempfile, threading, time

NED = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else sys.exit(__doc__)
AGENTS = {"claude": (".claude", ["@agentclientprotocol/claude-agent-acp"]),
          "codex": (".codex", ["@agentclientprotocol/codex-acp"]),
          "gemini": (".gemini", ["@google/gemini-cli", "--acp"]),
          "copilot": (".copilot", ["@github/copilot", "--acp"])}
want = sys.argv[2:] or list(AGENTS)
if not shutil.which("npx"):
    print("SKIP tagents: no npx (Node.js)"); sys.exit(0)
probe = subprocess.run([NED, "--sandbox", "--require", "--", "true"], capture_output=True)
if probe.returncode == 126:
    print("SKIP tagents: no Landlock here (" + probe.stderr.decode().strip() + ")"); sys.exit(0)

results = []


def check(name, ok, info=""):
    results.append(bool(ok))
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else "  " + str(info)[:600].replace("\n", " | ")), flush=True)


def sandbox_rules():
    """the sandbox itself, with sh for the agent: the project written, the home not, the agent's own folder made"""
    home = tempfile.mkdtemp(prefix="ned-agent-sh-")
    proj = os.path.join(home, "proj")
    os.makedirs(proj)
    open(os.path.join(home, "outside.txt"), "w").write("as it was\n")
    env = dict(os.environ, HOME=home)
    sh = lambda script, *more: subprocess.run([NED, "--sandbox-agent", "--", "sh", "-c", script] + list(more), cwd=proj,
                                              env=env, capture_output=True, text=True)
    r = sh("echo changed > $HOME/outside.txt")
    check("sandbox: a file in your home it was not given: refused", r.returncode != 0 and
          open(os.path.join(home, "outside.txt")).read() == "as it was\n", r.stderr)
    r = sh("echo made > inproj.txt")
    check("sandbox: … the project: written", r.returncode == 0 and os.path.exists(os.path.join(proj, "inproj.txt")), r.stderr)
    r = sh("echo x > $HOME/.claude/t653", "claude")
    check("sandbox: claude's folder in an empty home: made, only yours, and written",
          r.returncode == 0 and os.path.exists(os.path.join(home, ".claude", "t653")) and
          (os.stat(os.path.join(home, ".claude")).st_mode & 0o077) == 0, r.stderr)
    r = sh("echo x > $HOME/.codex/t653")
    check("sandbox: … another agent's folder, not named: not made", r.returncode != 0 and
          not os.path.exists(os.path.join(home, ".codex")), r.stderr)
    r = subprocess.run([NED, "--sandbox-agent", "--explain", "--", "true"], cwd=proj, env=env, capture_output=True, text=True)
    check("sandbox: --explain says what it may do", "network: allowed" in r.stderr and proj in r.stderr, r.stderr)
    r = subprocess.run([NED, "--sandbox-agent"], capture_output=True, text=True)
    check("sandbox: no command: how to use it, status 2", r.returncode == 2 and "ned --sandbox-agent" in r.stderr, r.stderr)
    shutil.rmtree(home, ignore_errors=True)


def run(name):
    """one agent: started in the sandbox, initialize and session/new; what it said and what it wrote"""
    own, pkg = AGENTS[name]
    home = tempfile.mkdtemp(prefix="ned-agent-%s-" % name)
    proj = os.path.join(home, "proj")
    os.makedirs(proj)
    open(os.path.join(home, "outside.txt"), "w").write("as it was\n")
    # (no key of yours, no token: the agent starts signed out; npm's cache stays where npm keeps it, as for you)
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("GH_", "GITHUB_", "ANTHROPIC", "OPENAI", "GEMINI", "GOOGLE", "CLAUDE", "CODEX", "COPILOT"))}
    cache = subprocess.run(["npm", "config", "get", "cache"], capture_output=True, text=True).stdout.strip()
    env["HOME"] = home
    if cache: env["npm_config_cache"] = cache
    for v in ["XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"]: env.pop(v, None)
    err = open(os.path.join(home, "stderr.txt"), "w")
    p = subprocess.Popen([NED, "--sandbox-agent", "--", "npx", "-y"] + pkg, cwd=proj, env=env, stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=err)
    got = []

    def reader():
        for line in p.stdout:
            try: got.append(json.loads(line))
            except ValueError: pass

    threading.Thread(target=reader, daemon=True).start()

    def ask(i, method, params, secs):
        p.stdin.write((json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}) + "\n").encode())
        p.stdin.flush()
        end = time.time() + secs
        while time.time() < end:
            for m in got:
                if m.get("id") == i and "method" not in m: return m
            if p.poll() is not None: return {"exited": p.returncode}
            time.sleep(0.2)
        return {"timeout": secs}

    init = ask(1, "initialize", {"protocolVersion": 1, "clientInfo": {"name": "ned", "version": "test"},
                                 "clientCapabilities": {"fs": {"readTextFile": True, "writeTextFile": True},
                                                        "terminal": True}}, 300)
    new = ask(2, "session/new", {"cwd": proj, "mcpServers": []}, 90) if "result" in init else {}
    try:
        p.kill()
        p.wait(5)
    except Exception:
        pass
    err.close()
    stderr = open(os.path.join(home, "stderr.txt"), errors="replace").read()
    check("%s: initialize answered in the sandbox" % name, "result" in init, json.dumps(init)[:300] + stderr[-800:])
    ok_new = "result" in new and new["result"].get("sessionId") or "error" in new
    check("%s: session/new answered (a session, or sign in first)" % name, ok_new, json.dumps(new)[:300] + stderr[-800:])
    refused = [l for l in stderr.splitlines() if any(w in l for w in ["EACCES", "EPERM", "Permission denied", "os error 13"])]
    check("%s: nothing refused by the sandbox" % name, not refused, "\n".join(refused[:5]))
    d = os.path.join(home, own)
    check("%s: its folder made, and used" % name, os.path.isdir(d) and len(os.listdir(d)) > 0,
          str(os.listdir(home)))
    check("%s: a file it was not given, as it was" % name, open(os.path.join(home, "outside.txt")).read() == "as it was\n")
    shutil.rmtree(home, ignore_errors=True)


sandbox_rules()
for a in want:
    if a in AGENTS: run(a)
print("%d/%d passed" % (sum(results), len(results)))
sys.exit(0 if all(results) else 1)

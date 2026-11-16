# An agent in a worktree of its own (6.53): AI: agent in a worktree starts a conversation with the ACP agent in a
# git worktree on a new branch (from your last commit), so that it works in the background while you edit — your
# files are not touched. When it is done its changes are committed on that branch, to review file by file (each a
# diff to accept or reject into your files), merge whole, or throw away with the worktree.

var
  wtPath = ""                     # the worktree's folder ("" none)
  wtBranch = ""                   # its branch (ned-agent/…)
  wtBase = ""                     # the commit it started from
  wtTop = ""                      # your repository's top folder

proc wtGit(dir, args: string): (bool, string) =
  ## git in a folder: whether it worked, and what it printed (its errors too)
  let (ok, o, e) = runFilter("git " & args, "", dir, 30_000)
  (ok, (o & e).strip)

proc cmdWorktreeChat() =
  ## AI: agent in a worktree — a new conversation with the agent, in a new worktree of the project's repository
  if not acpOn():
    info("Choose an agent first (AI: choose agent…): the worktree is for an ACP agent")
    return
  let (okTop, top) = wtGit(rootDir, "rev-parse --show-toplevel")
  let (okCommon, common0) = wtGit(rootDir, "rev-parse --git-common-dir")
  let (okHead, head) = wtGit(rootDir, "rev-parse HEAD")
  if not okTop or not okCommon or not okHead:
    info("The agent's worktree needs a git repository with a commit (Git: init, then a first commit)")
    return
  let common = absolutePath(common0, rootDir).normalizedPath
  let name = "agent-" & now().format("yyyyMMdd-HHmmss")
  let path = common / "ned-worktrees" / name
  let branch = "ned-agent/" & name
  let (ok, said) = wtGit(top, "worktree add -q -b " & quoteShell(branch) & " " & quoteShell(path) & " HEAD")
  if not ok:
    error("git worktree add: " & said)
    return
  (wtPath, wtBranch, wtBase, wtTop) = (path, branch, head, top)
  acpNewChat()
  acpWorkDir = path / relativePath(rootDir, top)        # (the project's own folder in it, when it is a part of the repository)
  if relativePath(rootDir, top) in [".", ""]: acpWorkDir = path
  showSide(svAssistant)
  acpNotice("This conversation works in a worktree of its own, on the branch " & branch & ", from your last " &
            "commit: your files are not touched while it works. When it is done: AI: review the agent's branch.")
  needRender = true

proc wtTurnEnded() =
  ## the agent's answer is complete: when it changed something in its worktree, a toast to review it
  if wtPath.len == 0 or not dirExists(wtPath): return
  let (ok, st) = wtGit(wtPath, "status --porcelain")
  if ok and st.len > 0:
    toast("The agent is done in its worktree (" & wtBranch & ")", 3, "Review", proc() = runCmd("AI: review the agent's branch"),
          ttl = 60_000)

proc wtCommit(): bool =
  ## what the agent changed, committed on its branch (with ned's name when git has none of yours); true when the
  ## branch has it
  let (_, st) = wtGit(wtPath, "status --porcelain")
  if st.len == 0: return true
  discard wtGit(wtPath, "add -A")
  var (ok, said) = wtGit(wtPath, "commit -q --no-verify -m " & quoteShell("The agent's changes (ned)"))
  if not ok and ("identity" in said or "user.email" in said or "user.name" in said):
    (ok, said) = wtGit(wtPath, "-c user.name=ned -c user.email=ned@localhost commit -q --no-verify -m " &
                       quoteShell("The agent's changes (ned)"))
  if not ok: error("git commit in the agent's worktree: " & said)
  ok

proc wtFile(rel, status: string) =
  ## one file the agent changed: its version beside yours, to take (a) or leave (d); the list again after
  let mine = wtTop / rel
  var theirs = ""
  if status != "D":
    let (ok, t, _) = runFilter("git show " & quoteShell(wtBranch & ":" & rel), "", wtTop, 30_000)
    if not ok:
      error("git show " & wtBranch & ":" & rel & " failed")
      return
    theirs = t
  proposeDiff("the agent (" & wtBranch & ")" & (if status == "D": " — it deleted this file" else: ""), mine, theirs,
    proc(accept: bool) =
      if accept:
        if status == "D":
          let b = ideBufOf(mine)
          if b != nil:
            let i = bufs.find(b)
            if i >= 0: closeBufferAt(i)
          try: removeFile(mine)
          except CatchableError as e: error("Could not delete " & rel & ": " & e.msg)
          info("Deleted " & rel & ", as the agent did")
        else:
          if not dirExists(parentDir(mine)):
            try: createDir(parentDir(mine))
            except CatchableError: discard
          let (msg, isErr) = toolWriteFile(%*{"path": mine, "content": theirs})
          if isErr: error(msg) else: info("Took the agent's " & rel & " (AI: undo gives yours back)")
      cmdWorktreeReview())

proc cmdWorktreeReview() =
  ## AI: review the agent's branch — its changes committed, then each file it changed (± changed, + new, − deleted)
  ## to review, the whole branch to merge, or the worktree and its branch to remove
  if wtPath.len == 0:
    info("No agent's worktree here (AI: agent in a worktree)")
    return
  if dirExists(wtPath) and not wtCommit(): return
  let (ok, list) = wtGit(wtTop, "diff --name-status --no-renames " & quoteShell(wtBase) & " " & quoteShell(wtBranch))
  if not ok:
    error("git diff: " & list)
    return
  var items: seq[(string, string, Action)]
  var n = 0
  for l in list.splitLines:
    let parts = l.split('\t')
    if parts.len < 2: continue
    let (st, rel) = (parts[0][0 .. 0], parts[1])
    let (mark, what) = case st
                       of "A": ("+ ", "new")
                       of "D": ("− ", "deleted")
                       else: ("± ", "changed")
    inc n
    capture st, rel:
      items.add act(mark & rel, what & " by the agent", proc() = wtFile(rel, st))
  items.add act("Merge the whole branch", "git merge " & wtBranch, proc() =
    let (ok, said) = wtGit(wtTop, "merge --no-ff --no-edit " & quoteShell(wtBranch))
    if ok:
      info("Merged " & wtBranch)
      checkDiskChanges()
    else: error("git merge " & wtBranch & ": " & said))
  items.add act("Remove the worktree and the branch", "what is not taken or merged is lost", proc() =
    if dirExists(wtPath):
      let (ok, said) = wtGit(wtTop, "worktree remove --force " & quoteShell(wtPath))
      if not ok:
        error("git worktree remove: " & said)
        return
    discard wtGit(wtTop, "branch -D " & quoteShell(wtBranch))
    info("Removed the agent's worktree and " & wtBranch)
    if acpWorkDir.len > 0 and acpWorkDir.startsWith(wtPath): acpNewChat()
    (wtPath, wtBranch, wtBase) = ("", "", ""))
  openActions("The agent's branch " & wtBranch & ": " & $n & " file" & (if n == 1: "" else: "s") & " changed", items)

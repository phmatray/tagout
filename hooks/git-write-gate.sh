#!/usr/bin/env bash
# Git write-gate (Claude Code PreToolUse, matcher: Bash).
#
# The kit knows exactly which git writes hurt in a shared checkout, and until now it said so only in
# prose. #26 (2026-08-10): four agents in one checkout, a concurrent `git checkout` moved HEAD
# between branch creation and commit, the commit landed on the OTHER agent's branch, `git push`
# carried it into that agent's PR, and every command exited 0. The fix was three guards —
# `guarded-commit.sh`, `guarded-push.sh`, `guarded-merge.sh` (plus `guarded-pr-merge.sh` in
# `merge-pr`) — that assert the branch before and after, and a rule that the raw commands are never
# used. #280 is that rule failing again: a worker hand-rolled its own check and committed to the
# user's branch in the main checkout. A rule living in prose cannot go red. This hook is where it
# goes red — the one place in Claude Code that sees the command before it runs.
#
# It judges one `gh` command too: `gh pr merge` (#512). #326 put `gh` out of scope because "`gh pr
# merge` is already guarded by `guarded-pr-merge.sh` and reads back state" — true only for an agent
# that can FIND the guard. Session 62c8dcf7 measured one that could not: it ran the raw command,
# whose one exit code covers both the merge and gh's local cleanup, and this hook's `*git*`
# pre-filter let it through unread. So a raw `gh pr merge` in a profiled repository is denied like a
# bare `git merge`, and every denial names its guard by absolute path from ${CLAUDE_PLUGIN_ROOT}
# (`guard_hint`), so the refusal also says where the replacement is.
#
# It fails OPEN, always — the decision recorded in docs/adr/0002-the-roseline-gate-fails-open-always.md
# for `hooks/roseline-gate.sh`, which this hook is modelled on line for line and which applies here
# verbatim: the plugin installs globally, so a Bash gate that failed CLOSED would deadlock every
# repository it was never meant to touch. Every internal failure — no `jq`, no `awk`, no `git`, an
# unparseable payload, a command whose quoting cannot be trusted — exits 0 with no output.
# `GIT_GATE=off` (also `0|false|no|disabled`) is the master switch and is checked FIRST;
# `GIT_GATE=on` forces enforcement past the probe below, and `off` still wins.
#
# Two things the switch cannot do from inside a session, and what the gate does instead (#372):
#   * an `export GIT_GATE=off` typed into a Bash call never reaches this hook — it is spawned by the
#     Claude Code process and inherits THAT environment, not the tool's shell. Disabling it for a
#     session means launching Claude with the variable set. The deny text says exactly that.
#   * a `GIT_GATE=off git commit …` PREFIX used to be stepped over by the same walk that skips
#     `TZ=UTC git …`, so the one-command escape the deny text advertised did nothing. The walk now
#     reads the assignment it steps over: a segment prefixed with the off value is allowed whole.
#     The prefix is honoured only for the main thread; a sub-agent's (a payload carrying `agent_id`)
#     is judged like the bare command, since it has nobody to ask before using the escape (#643).
# And the probe follows `cd` (#372): `cd /tmp/shop && git commit` is that repository's commit, not
# the cwd's — a literal, resolvable `cd` in an earlier segment moves the directory the profile is
# looked up in, exactly as `-C <path>` already does; anything the hook cannot resolve (a variable,
# `~`, a quoted span, `cd -`, `pushd`, a `cd` inside `( … )`) leaves it where it was.
#
# ------------------------------------------------------------------------- prior art, not a port
# Matt Pocock ships `git-guardrails-claude-code/scripts/block-dangerous-git.sh` (mattpocock/skills,
# MIT) for the same reason. It is deliberately NOT copied, for four measured reasons:
#   1. it fails CLOSED — `exit 2` on a match, no off-switch, no probe (see the paragraph above);
#   2. it blocks `git push` outright, and this kit's lifecycle pushes on every task THROUGH
#      `guarded-push.sh` — so the gate has to recognise the guard rather than the verb;
#   3. it blocks `git branch -D`, which `merge-pr`'s teardown and `make-worktree.sh`'s cleanup run
#      legitimately on branches whose PR just merged (reflog-recoverable; a branch is not a tree);
#   4. its patterns are substring greps — `"git push"` also fires on `echo "git push"` and on a
#      commit message quoting it, and `push --force` also fires on `--force-with-lease`.
# The idea is worth porting; the script is not. This one tokenises, probes, and routes to the guards.

case "${GIT_GATE:-}" in off|0|false|no|disabled) exit 0 ;; esac

# `on` is checked SECOND, on purpose: `off` stays the master switch, so a stale `on` in a shell rc
# can never override the `off` a user just typed. It forces enforcement past the profile probe below
# — the user's testimony that the lifecycle guards DO apply here — and nothing else. Any other
# value, `maybe` included, is neither switch and falls through to the probe exactly as unset does.
FORCE=0
case "${GIT_GATE:-}" in on|1|true|yes|enabled) FORCE=1 ;; esac

# Word splitting below (`set -- $seg`) is how a segment becomes tokens, and it must not also glob:
# an unquoted `*` in a command would otherwise expand against the hook's own working directory and
# the subcommand could land anywhere in the result.
set -f

payload=$(cat) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v awk >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

# Re-checked even though hooks.json matches "Bash": the matcher is a regex, so it also catches
# BashOutput, and would catch any future tool whose name contains "Bash".
tool=$(jq -r '.tool_name // empty' <<<"$payload" 2>/dev/null) || exit 0
[ "$tool" = "Bash" ] || exit 0

cmd=$(jq -r '.tool_input.command // empty' <<<"$payload" 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# A command this long is not one of the shapes below; parsing it would cost more than the hook's
# 5s timeout allows and a timed-out hook is an unpredictable one. Fail open, explicitly.
[ "${#cmd}" -le 65536 ] || exit 0

# The cheap reject, before any parsing: nothing here can matter to a command with no `git` in it and
# no `gh` followed somewhere by `merge` — the one `gh` shape judged below (#512). `*gh*merge*`, not a
# bare `*gh*`, so `github`, `high` and `though` stay on this fast path. A literal backslash anywhere
# also stays on the slow path (#533): the awk pass below now unwraps a backslash INSIDE a launcher
# word too (`g\it commit`, not just `\git commit`), which breaks the contiguous `git`/`gh` substring
# this cheap check looks for on the raw, unprocessed command — so a command carrying any backslash
# can't be cheaply ruled out here and has to go through the real scan instead.
case "$cmd" in *git*|*gh*merge*|*'\'*) ;; *) exit 0 ;; esac

# A heredoc body is FILE CONTENT, not commands, and this parser cannot tell the two apart: newlines
# are folded to `;` below, so `cat > x.sh <<'SH'` … `git commit -m x` … `SH` would be judged as a
# real commit and denied — blocking the writing of any script, doc or test whose text contains one
# of these lines, which this repository's own suites do. So everything from an unquoted `<<` onward
# is discarded — but the line that OPENS the heredoc is not the body, it is ordinary, parseable shell
# sitting before the `<<`, and it is exactly where a destructive git write lives when the message or
# ref list is spelled as a heredoc (`git commit -F - <<'MSG'`, the natural long-message form).
# Discarding the whole command, opener included, let that write launder straight past the gate
# (#440): two real commits landed unguarded in the session that found it.
#
# This has to be QUOTE-AWARE, not a blind `${cmd%%<<*}` on the raw string: `<<` is common, unremarkable
# TEXT inside a real argument — a commit message quoting a diff marker, a doc string — and truncating
# on the first occurrence wherever it sits can cut a quote in half, leaving the KEPT prefix with an
# unterminated quote; the awk stripper below then exits 3 on that and `|| exit 0` fails the whole hook
# open, laundering a real trailing `git push --force` exactly like #440 did. So the cut is folded into
# the SAME character-by-character scan that already tracks quote state for the stripper below (`q`):
# an unquoted `<<` breaks the scan right there and everything after it is simply never appended to
# `out`, while `<<` seen with `q != ""` is ordinary quoted content and changes nothing. `<<<`
# (here-string) is a prefix of `<<` and is truncated the same way. A command that is only a heredoc
# opener (`cat <<X`) truncates to `cat `, which carries no `git` token and exits at the cheap reject
# above. Two residual gaps this does not close, both strictly no worse than before #440's fix: a
# SECOND command sharing the line after the heredoc's terminator is still never judged, and `<<` as
# bash's arithmetic left-shift (`$((1<<2))`) is indistinguishable from a heredoc to this scan and cuts
# there too — a real shell tokenizer is the fix for either, and not worth it for a gate whose declared
# direction is fail-open (ADR 0002).
cwd=$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null) || exit 0
# Claude Code stamps `agent_id` on a sub-agent's tool call; empty means the main thread (#643).
agent_id=$(jq -r '.agent_id // empty | strings' <<<"$payload" 2>/dev/null) || agent_id=""

# ---------------------------------------------------------------- #533: recognise past disguises
# Three shapes let a real write slip past the walk below unrecognised: a backslash or quoting that
# defeats a literal `gh`/`git` match (`\gh`, `"gh"`), a wrapper launcher not on the recognised list
# (`timeout`), and a command hidden inside `$(...)`/backtick substitution. The first two are fixed
# inside the same character scan that already strips quotes/comments (below); the third needs its
# own recursive check, since the substituted command runs regardless of where it sits on the line.
# A fourth (#658): a shell launcher's `-c` string (`bash -c '…'`, `sh -ec "…"`) or `eval`'s argument
# is also a command that runs regardless of where it sits — recognised the same recursive way.

# ------------------------------------------------------------------- strip quotes and comments
# `echo "git push --force"` is not a push, and `git log # git reset --hard` is not a reset. Matt's
# script denies both (reason 4 above). So the command is stripped of quoted spans and comments
# BEFORE anything is matched, and a string whose quoting does not close is a parse this hook cannot
# trust — awk exits 3 and the `||` fails open.
#
# Newlines are folded to `;` first: they are a segment separator like `;` anyway, and doing it here
# means a quoted string that spans lines is still seen as ONE quoted span rather than two broken
# ones. The awk program is fed a single line, so a `#` comment runs only to the next separator,
# never to the end of a multi-line script.
#
# Three details, each of which was a hole before it was one:
#
#   * a stripped quoted span leaves a PLACEHOLDER token (`@Q@`), not a space. Deleting it outright
#     removed the word, and `git -C "$WORKTREE" commit -m "x"` then cleaned to `git -C   commit …` —
#     the `-C` walk below ate `commit` as its path argument, the subcommand became `-m`, and the
#     dominant idiom in this whole kit (`git -C "$WORKTREE" …`, which its own references prescribe
#     over `cd … &&`) sailed straight through the gate it was written for.
#   * `#` starts a comment only at a WORD BOUNDARY, as in real shell. Anywhere-`#` meant
#     `git log --grep=a#b && git reset --hard` hid its second command from the walk entirely. The
#     comment then runs to the next `;`, `|`, `&` — the same separators the segment walk splits on,
#     so a comment can never swallow a command that really would run.
#   * `{`, `}` become spaces and `(`, `)` become a `@P@` marker token, so `(git commit …)`,
#     `{ git commit …; }` and the bodies of `if`/`for`/`while` are tokenised as the commands they
#     are rather than as one opaque word — and a `cd` that sits after a `@P@` in its own segment is
#     known to be inside a subshell, whose directory change never reaches the segments after it.
#
# `sq`/`dq`/`bs` are built with sprintf because the program itself is single-quoted in shell and so
# cannot contain a literal `'`.
awkout=$(printf '%s' "$cmd" | tr '\n' ';' | awk '
BEGIN { sq = sprintf("%c", 39); dq = sprintf("%c", 34); bs = sprintf("%c", 92) }
function endsw(s, suf,    ls, lu) { ls = length(s); lu = length(suf); return (ls >= lu && substr(s, ls-lu+1) == suf) }
# The emitted text of the current segment: `out` after its last `;`, `|` or `&` — a plain backward
# scan, since POSIX awk has no rindex-of-a-set. Used only to test what PRECEDES a quote that is
# about to close, never what is inside it (#658). No apostrophes in this comment block: it sits
# inside the awk program, which the outer shell still reads as ONE single-quoted string.
function segtail(s,    p, cch) {
  for (p = length(s); p > 0; p--) {
    cch = substr(s, p, 1)
    if (cch == ";" || cch == "|" || cch == "&") return substr(s, p + 1)
  }
  return s
}
{
  out = ""; q = ""; qbuf = ""; n = length($0); i = 1; prev = " "; nsubs = 0
  while (i <= n) {
    c = substr($0, i, 1)
    if (q == "") {
      if (c == "<" && substr($0, i+1, 1) == "<") { break }
      # An unquoted backslash escapes exactly the next character: real shell keeps that character
      # as literal content of the word (`\gh` is the word `gh`) rather than dropping it — dropping
      # it (the previous behaviour) is what let `\gh pr merge 12` slip the gate unrecognised (#533).
      # EXCEPT when the escaped character is itself one of the segment separators (semicolon,
      # ampersand, pipe — what a real newline becomes via the earlier tr step): a genuine shell
      # line continuation reaches this scan as a backslash directly followed by a semicolon, and
      # literal-keeping that separator would hand the segment walk below a real split where none
      # exists, splitting one write into two unrecognisable halves (an UNDER-deny) and, the mirror
      # case, turning an escaped separator that was never meant to end anything (one call, its
      # separator merely quoted) into two segments and a false deny on text that never runs as git.
      # Falling back to the old space-substitution for exactly these three characters keeps both.
      if (c == bs) {
        gate_esc = substr($0, i+1, 1)
        if (gate_esc == ";" || gate_esc == "&" || gate_esc == "|") { out = out " " }
        else { out = out gate_esc }
        prev = "x"; i += 2; continue
      }
      # `$(` opens a command substitution: find its matching close (a bare depth-count, not itself
      # quote-aware inside — ponytail: good enough for the reported bypass shape; a real shell
      # parser is out of scope for this hook) and record the inner text for a recursive check below
      # (#533) — the shell runs it regardless of where it sits in the outer command. Skipped over
      # (not left for the generic "(" handling below) so the outer command is judged exactly as it
      # would be without the substitution.
      if (c == "$" && substr($0, i+1, 1) == "(") {
        depth = 1; j = i + 2; start = j
        while (j <= n && depth > 0) {
          cc = substr($0, j, 1)
          if (cc == "(") depth++
          else if (cc == ")") depth--
          if (depth > 0) j++
        }
        subs[nsubs++] = substr($0, start, j - start)
        out = out " @P@ "; prev = " "; i = j + 1; continue
      }
      # Backtick command substitution: first matching backtick (no nesting without escaping).
      if (c == "`") {
        j = i + 1
        while (j <= n && substr($0, j, 1) != "`") j++
        subs[nsubs++] = substr($0, i + 1, j - i - 1)
        out = out " @P@ "; prev = " "; i = j + 1; continue
      }
      if (c == sq || c == dq) { q = c; qbuf = ""; prev = "Q"; i++; continue }
      if (c == "#" && (prev == " " || prev == ";" || prev == "|" || prev == "&")) {
        while (i <= n) {
          c = substr($0, i, 1)
          if (c == ";" || c == "|" || c == "&") break
          i++
        }
        continue
      }
      if (c == "(" || c == ")") { out = out " @P@ "; prev = " "; i++; continue }
      if (c == "{" || c == "}") { out = out " "; prev = " "; i++; continue }
      out = out c; prev = c; i++
    } else {
      if (q == dq && c == bs) { qbuf = qbuf substr($0, i+1, 1); i += 2; continue }
      # #559: real shell still expands `$(...)`/backticks INSIDE a double-quoted argument (only
      # single quotes suppress that) — so a substitution hidden there is extracted for the same
      # recursive subs[] relay the unquoted branch above already feeds, instead of being silently
      # absorbed into qbuf and collapsing to an opaque, never-checked @Q@ placeholder. Verbatim
      # copies of the two extraction blocks above; only `sq` never gets this (real shell agrees).
      if (q == dq && c == "$" && substr($0, i+1, 1) == "(") {
        depth = 1; j = i + 2; start = j
        while (j <= n && depth > 0) {
          cc = substr($0, j, 1)
          if (cc == "(") depth++
          else if (cc == ")") depth--
          if (depth > 0) j++
        }
        subs[nsubs++] = substr($0, start, j - start)
        # Never drop the extracted span with nothing in its place (see the code comment two blocks
        # up on the unquoted @P@ append): a stray `"gh` + trailing `"` either side of a silently
        # dropped span could otherwise reassemble into a literal `gh`/`git` by accident.
        qbuf = qbuf "@P@"; i = j + 1; continue
      }
      if (q == dq && c == "`") {
        j = i + 1
        while (j <= n && substr($0, j, 1) != "`") j++
        subs[nsubs++] = substr($0, i + 1, j - i - 1)
        qbuf = qbuf "@P@"; i = j + 1; continue
      }
      if (c == q) {
        # #658: the -c string of a shell launcher, or the argument eval will run, is a command the
        # shell WILL run — judged the same as if it had been typed bare, by feeding it into the same
        # subs[] relay #533 built for $(...)/backticks. The trigger reads the text already emitted
        # for THIS segment (segtail(out)), not qbuf — the question is what precedes the quote, not
        # what is inside it. Checked with macOS /usr/bin/awk against bash -c, bash -lc, /bin/bash -c,
        # sh -ec, bash --norc -c and eval (match), and echo, bash, sh -x script.sh, ssh -c aes,
        # foosh -c and sh -c @Q@ (no match). No apostrophes anywhere in this block (see above).
        tail = segtail(out)
        if (tail ~ /(^| |@P@)([^ ]*\/)?(bash|sh|zsh|dash|ksh)( +-[-A-Za-z]+)* +-[A-Za-z]*c[A-Za-z]* *$/ || tail ~ /(^| |@P@)eval *$/) {
          rec = qbuf
          # The off-switch carries in: an already-open GIT_GATE=off|0|false|no|disabled assignment
          # prefixes the relayed string too, so the recursive judge() applies the rule from #643
          # (honoured for the main thread, stepped over for a sub-agent) to it exactly as to a bare
          # command.
          if (match(tail, /GIT_GATE=(off|0|false|no|disabled)/)) rec = substr(tail, RSTART, RLENGTH) " " rec
          subs[nsubs++] = rec
        }
        q = ""
        # A quoted span collapses to a placeholder so its content can never be substring-matched
        # (the reason it is opaque at all) — but a quoted `gh`/`git`, or a quoted path ending in one
        # of the three guarded-*.sh names, is exactly the shape #533 needs recognised, so those get
        # their OWN placeholder instead of the generic one; judge() below matches them the same as
        # the bare word/path. Anything else stays @Q@, unrecognisable, same as before.
        if (qbuf == "gh") out = out "@GH_WORD@"
        else if (qbuf == "git") out = out "@GIT_WORD@"
        else if (endsw(qbuf, "guarded-commit.sh")) out = out "@GUARDED_COMMIT@"
        else if (endsw(qbuf, "guarded-push.sh")) out = out "@GUARDED_PUSH@"
        else if (endsw(qbuf, "guarded-merge.sh")) out = out "@GUARDED_MERGE@"
        else out = out "@Q@"
      } else {
        qbuf = qbuf c
      }
      i++
    }
  }
  if (q != "") { exit 3 }
  print "C\t" out
  for (k = 0; k < nsubs; k++) print "S\t" subs[k]
}' 2>/dev/null) || exit 0

# Split the awk output back into the clean command text (one "C" line) and zero or more extracted
# substitution bodies (one "S" line each) — two channels carried over the one stdout stream rather
# than a temp file, consistent with the rest of this hook's no-side-effects design.
tab=$(printf '\t')
clean=""
gate_subs=""
while IFS= read -r gate_ln; do
  case "$gate_ln" in
    "C$tab"*) clean="${gate_ln#C"$tab"}" ;;
    "S$tab"*) gate_subs="$gate_subs${gate_ln#S"$tab"}
" ;;
  esac
done <<EOF
$awkout
EOF

# Each extracted substitution is a real command the shell will run, so it is checked the same way
# any top-level command would be: recursively, through this exact script, from the same cwd (so
# GIT_GATE/CLAUDE_PLUGIN_ROOT/the profile probe all see what the outer invocation would have seen).
# A deny from any one of them denies the whole line — relayed verbatim, so the reason still names
# the guard the SUBSTITUTED command needed.
if [ -n "$gate_subs" ]; then
  while IFS= read -r gate_subcmd; do
    [ -n "$gate_subcmd" ] || continue
    gate_subpay=$(jq -nc --arg d "$cwd" --arg c "$gate_subcmd" --arg a "$agent_id" \
      '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}} + (if $a == "" then {} else {agent_id:$a} end)' \
      2>/dev/null) || continue
    gate_subout=$(printf '%s' "$gate_subpay" | bash "$0" 2>/dev/null)
    if [ -n "$gate_subout" ]; then
      printf '%s\n' "$gate_subout"
      exit 0
    fi
  done <<EOF
$gate_subs
EOF
fi

# ------------------------------------------------------------------------- the guard recognition
# A line that calls one of the kit's guards is the thing this hook exists to encourage, so that
# SEGMENT is allowed. Recognised in judge() below as a whole path segment at the START of a command
# position — never a raw substring search over the whole line (#533's own fix): the old whole-line
# check matched `guarded-commit.sh` anywhere on the line, which let `if …; then
# "$G/guarded-commit.sh" …; else git commit -m x; fi` whitelist the else-branch's raw commit purely
# because the guard was MENTIONED earlier on the same line. Per-segment recognition instead: the
# quote-collapsing pass above hands back one of the @GUARDED_*@ placeholders in place of the generic
# @Q@ specifically when a quoted span's content ends in one of the three guard filenames, and an
# unquoted spelling matches the same filenames directly — either way judge() only looks at $1, the
# first token of the SPECIFIC segment being judged, so a mention elsewhere on the line (a different
# segment, a comment, a commit message) never allows a segment it doesn't belong to.
#
# `guarded-pr-merge.sh` is deliberately NOT recognised here (#512). Its own call never trips the `gh`
# arm — that segment's command word is the guard, not `gh` — so recognising it bought nothing, and
# the whole-line version of this check let through the very incident the arm exists for: session
# 62c8dcf7's "look for the guard, else merge raw" line (`if [ ! -d "$SKILLS_DIR" ]; then … gh pr
# merge 1340 …; else "$SKILLS_DIR/guarded-pr-merge.sh" …; fi`) named the guard, so the old whole-line
# allow never judged the raw merge in the `if` branch either.

# ------------------------------------------------------------------------------- the deny output
deny() { # $1 the offending segment  $2 the replacement sentence
         # $3 why it is gated (default: the git writes of #26/#280)  $4 its command word (default: git)
  local reason why="${3:-is one of the writes that produced #26 and #280 in a shared checkout}"
  reason="Blocked by the git write-gate: \`$1\` $why.
$2
"
  # A sub-agent's prefix is not honoured (#643), so its denial offers the guard fallback instead.
  if [ -n "$agent_id" ]; then
    reason="${reason}You are a sub-agent — nobody is here to approve a bypass, and a \`GIT_GATE=off\` prefix is not honoured for you. If the guard's path is refused, follow \`$(guard_hint skills/_shared/guard-invocation.md)\`; otherwise stop and report this denial."
  else
    reason="${reason}To run this one command anyway, prefix it: \`GIT_GATE=off ${4:-git} …\`. To disable the gate for a whole session, launch Claude with GIT_GATE=off in its environment — an \`export\` inside a Bash call never reaches this hook."
  fi
  jq -n --arg r "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null
  exit 0
}

# How a denial spells the guard it routes to (#512). Kit-relative `skills/…` resolves only when the
# cwd IS the kit's own checkout; in a consumer repository it names nothing, and agents guessed the
# kit's path five times in four sessions — the last miss ending in a raw `gh pr merge`. The deny
# text is the one channel shown to reach a dispatched sub-agent (#414's worker quoted it), so it
# carries the absolute path under ${CLAUDE_PLUGIN_ROOT} — the root hooks.json runs this very file
# from — whenever the guard exists there. A stale root (a cache an upgrade emptied) or none at all
# keeps the kit-relative spelling: never an absolute path that does not exist.
guard_hint() { # $1 a kit-relative path
  local root="${CLAUDE_PLUGIN_ROOT:-}" p
  if [ -n "$root" ] && [ -f "${root%/}/$1" ]; then
    p="${root%/}/$1"
    # Double-quoted when it holds whitespace, so the command it sits in still pastes as one word.
    case "$p" in *[[:space:]]*) printf '"%s"' "$p" ;; *) printf '%s' "$p" ;; esac
  else
    printf '%s' "$1"
  fi
}

# --------------------------------------------------------------------------------- the probe
# A denial names a `guarded-*.sh` replacement, so the gate must not deny where that replacement
# cannot exist. A repository carrying a `.claude/skills/repo-profile.md` has opted into
# `create-issue`/`implement-issue`/`merge-pr` and therefore HAS those guards to route to; a
# repository without one gets no denial, ever. This is exactly the role the `dnx` probe plays for
# `roseline-gate.sh` (#112): never deny in favour of a replacement that cannot apply here.
#
# The file is read with `[ -f ]`, not `git ls-files`: the profile IS committed by convention (which
# is why it is present in a linked worktree at all, #157 — precisely when the guards matter most),
# but proving that would put a second `git` spawn on the path of every Bash call, and an untracked
# profile is a repository mid-adoption rather than one to stop enforcing in. `GIT_GATE=on` short-circuits it, the same way `ROSELINE_GATE=on`
# does: the user is the only authority this hook can consult about a repo it cannot recognise.
is_profiled() { # $1 a directory
  local dir="$1" top
  [ -n "$dir" ] || return 1
  [ -d "$dir" ] || return 1
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] || return 1
  [ -f "$top/.claude/skills/repo-profile.md" ]
}

# The directory the probe answers about, for the segment being judged. It starts as the payload's
# cwd and moves with every `cd <literal path>` the walk meets (#372): `cd /tmp/shop && git commit`
# is /tmp/shop's commit, and a deny there would name guards that do not exist there. Only a cd the
# hook can resolve by itself moves it — an absolute or cwd-relative literal that IS a directory.
# `cd` alone, `cd -`, any flag, a variable, a backtick, `~`, a quoted span (`@Q@`) and `pushd`
# leave it unchanged, and so does a `cd` inside `( … )` (the `@P@` marker): that change of
# directory dies with the subshell, so it must not follow the segments after it.
eff_dir=""
follow_cd() { # $@ the tokens of a `cd` segment, `cd` first
  shift
  [ $# -eq 1 ] || return 0
  local target="$1" resolved
  case "$target" in -*|*'$'*|*'`'*|*'~'*|*@Q@*) return 0 ;; esac
  case "$target" in /*) resolved="$target" ;; *) resolved="${eff_dir:-.}/$target" ;; esac
  [ -d "$resolved" ] || return 0
  resolved=$(cd "$resolved" 2>/dev/null && pwd -P) || return 0
  [ -n "$resolved" ] && eff_dir="$resolved"
  return 0
}

# A pathspec that names the whole tree, in every spelling git accepts for it (#373): `.`, `./`,
# the top-level magic `:/`. Reading only the literal `.` let `git checkout HEAD -- ./` — the exact
# shape of #26's originating incident — through the gate written for it.
whole_tree() { # $@ pathspecs
  local p
  for p in "$@"; do
    case "$p" in .|./|.//|./.|:/|:/.) return 0 ;; esac
  done
  return 1
}

# ------------------------------------------------------------------- judge one command segment
judge() { # $1 one segment of the stripped command
  local seg="$1" seg_dir="" sub="" grouped=0 gh_repo_seen=0
  # Word splitting is the tokeniser; `set -f` above is what makes it safe.
  set -- $seg
  [ $# -gt 0 ] || return 0

  # Prefixes that carry a command rather than being one: `env FOO=1 git …`, `sudo git …`,
  # `TZ=UTC git …` — and the shell keywords a segment inherits once `(`/`)`/`{`/`}` have become
  # spaces, so that `if true; then git commit …; fi` and `for f in a b; do git push; done` are
  # judged on their bodies rather than skipped as "the segment starts with `then`". Anything else
  # stops the walk — the segment simply is not a git invocation.
  #
  # `timeout`/`nice`/`stdbuf` join the launcher list (#533). Each of the three also recognises its
  # OWN GNU coreutils option flags before the launcher word is fully consumed (#562 — #533 only
  # unwrapped their BARE form, so `nice -n 10 git …`/`timeout -k 5 60 …` broke the walk on `-n`/`-k`
  # before it ever reached git/gh): a short flag that takes a value, attached (`-k5`) or separated
  # (`-k 5`); a long flag only in `--name=value` form (GNU getopt's separated `--name value` long
  # form is NOT recognised — out of scope, same as any BSD spelling of these three launchers, which
  # fall through unrecognised exactly as before). `timeout` alone also takes a mandatory duration
  # argument after its own options (`timeout 60 …`) — `nice`/`stdbuf` have no such positional.
  while [ $# -gt 0 ]; do
    case "$1" in
      env|sudo|command|nohup|time|exec|builtin) shift ;;
      nice)
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            -n) shift; [ $# -gt 0 ] && shift ;;
            -n?*) shift ;;
            --adjustment=*) shift ;;
            *) break ;;
          esac
        done
        ;;
      stdbuf)
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            -i|-o|-e) shift; [ $# -gt 0 ] && shift ;;
            -i?*|-o?*|-e?*) shift ;;
            --input=*|--output=*|--error=*) shift ;;
            *) break ;;
          esac
        done
        ;;
      timeout)
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            -k|-s) shift; [ $# -gt 0 ] && shift ;;
            -k?*|-s?*) shift ;;
            --kill-after=*|--signal=*) shift ;;
            -v|--verbose|--foreground|--preserve-status) shift ;;
            *) break ;;
          esac
        done
        [ $# -gt 0 ] && shift
        ;;
      then|do|else|elif|'!') shift ;;
      @P@) grouped=1; shift ;;
      # The one assignment the walk READS instead of stepping over: the per-command off-switch the
      # deny text advertises. It has to be honoured here, because the environment check at the top
      # of this file sees the hook's own environment, never a prefix typed into the command (#372).
      # Honoured for the main thread only: a sub-agent has nobody to ask before it reaches for the
      # escape its deny text names, so its prefixed segment is stepped over and judged (#643).
      GIT_GATE=off|GIT_GATE=0|GIT_GATE=false|GIT_GATE=no|GIT_GATE=disabled)
        [ -z "$agent_id" ] && return 0
        shift ;;
      # `GH_REPO=` retargets a later `gh pr merge` at another repo the same way `-R`/`--repo` does
      # (#533) — recorded here, since by the time `judge_gh` sees the segment this prefix is
      # already consumed and gone from "$@".
      GH_REPO=*) gh_repo_seen=1; shift ;;
      [A-Za-z_]*=*) shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 0

  # The three guarded-*.sh scripts this hook exists to route writes through are always allowed,
  # recognised as a whole path segment at the START of a command position — never a raw substring
  # search over the whole line (#533; see "the guard recognition" below for why). `@GUARDED_*@` is
  # what the quote-collapsing pass above hands back for a QUOTED invocation; the bare `*/…sh` forms
  # cover an unquoted one.
  case "$1" in
    @GUARDED_COMMIT@|@GUARDED_PUSH@|@GUARDED_MERGE@|guarded-commit.sh|*/guarded-commit.sh| \
    guarded-push.sh|*/guarded-push.sh|guarded-merge.sh|*/guarded-merge.sh) return 0 ;;
  esac

  # A `cd` segment is never a git write, but it decides which repository the NEXT segments act
  # in — unless it ran inside `( … )`, where it died with the subshell.
  if [ "$1" = cd ]; then
    [ "$grouped" -eq 1 ] || follow_cd "$@"
    return 0
  fi

  # `gh` is judged for exactly one subcommand, by `judge_gh` below (#512). `@GH_WORD@` is a quoted
  # `"gh"`/`'gh'` (#533) — the quote-collapsing pass above hands it back in place of the generic
  # @Q@ specifically for that exact content.
  case "$1" in gh|*/gh|@GH_WORD@) judge_gh "$seg" "$gh_repo_seen" "$@"; return 0 ;; esac

  # `@GIT_WORD@` is the same trick for a quoted `"git"`/`'git'` (#533).
  case "$1" in git|*/git|@GIT_WORD@) shift ;; *) return 0 ;; esac

  # git's OWN options, before the subcommand — including the `git -c user.email=… -c user.name=… commit`
  # shape the kit's own guards emit, which a naive "second word is the subcommand" reader would miss
  # entirely. `-C <path>` is captured, because it names the repository this segment acts on and it
  # OUTRANKS the payload's cwd (a `git -C <profiled-repo> push` run from anywhere is still that
  # repo's push).
  while [ $# -gt 0 ]; do
    case "$1" in
      -C) [ $# -ge 2 ] || return 0; seg_dir="$2"; shift 2 ;;
      -c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix)
        [ $# -ge 2 ] || return 0; shift 2 ;;
      --*=*) shift ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 0

  sub="$1"; shift

  # `git init` makes the directory the walk is standing in a BRAND-NEW repository — one that cannot
  # carry a profile, so the guards a denial would name do not exist there. The segments after it
  # (`git init && git add -A && git commit -m legacy`, the demo walkthrough's own line) are that
  # repository's writes, even when the `cd` before it named a directory that only comes into being
  # at run time and so could not be followed. Re-initialising an existing profiled repository is
  # the one shape this over-allows, and over-allowing is the direction this gate errs in (ADR 0002).
  if [ "$sub" = init ]; then fresh_init=1; return 0; fi

  # Nothing below is worth a probe, so the probe runs only once a git subcommand is in hand.
  case "$sub" in
    checkout|switch|restore|reset|clean|push|commit|merge) ;;
    *) return 0 ;;
  esac

  # Resolved unconditionally — not only under FORCE!=1 — because the named-path dirty-checkout
  # probe below (#560) needs the real target directory even under `GIT_GATE=on`; leaving `dir`
  # declared only inside the `is_profiled` arm left it unset there, so that probe silently checked
  # the hook's own cwd instead of the repo `-C` named (#560 follow-up).
  local dir="$eff_dir"
  if [ -n "$seg_dir" ]; then
    local cdir="$seg_dir"
    case "$cdir" in /*) ;; *) cdir="${eff_dir:-.}/$cdir" ;; esac
    # The `-C` path is used ONLY when it resolves to a real repository. A path that does not —
    # `git -C $WORKTREE commit`, where the hook sees the variable unexpanded, or `-C @Q@` where
    # it was quoted — is no evidence at all, and treating "cannot resolve" as "not profiled"
    # made every `-C` carrying a variable a silent off-switch for that segment. Falling back to
    # the payload's cwd is the honest reading: this is still a command the session is running
    # from somewhere, and that somewhere is what the probe can actually answer about.
    if git -C "$cdir" rev-parse --show-toplevel >/dev/null 2>&1; then dir="$cdir"; fi
  fi
  if [ "$FORCE" != 1 ]; then
    [ "$fresh_init" -eq 0 ] || return 0
    is_profiled "$dir" || return 0
  fi

  # ---------------------------------------------------------- normalise argv once (#373)
  # The arms below read MEANING, not spelling. Everything after `--` is a pathspec, however it is
  # spelled (`git clean -fd -- -note` deletes a file called -note; the `-n` in it is not a dry run);
  # everything before it that starts with `-` is an option, and a bundled short cluster (`-fq`,
  # `-fc`, `-ndf`) is split into one token per letter so `-f` is found wherever it was typed. The
  # split cannot fail, so the arms' inputs are never left half-normalised.
  local a opts="" paths="" seen_dd=0 letters
  for a in "$@"; do
    if [ "$seen_dd" -eq 1 ]; then paths="$paths $a"; continue; fi
    case "$a" in
      --) seen_dd=1 ;;
      --*) opts="$opts $a" ;;
      -?*)
        letters="${a#-}"
        while [ -n "$letters" ]; do
          opts="$opts -${letters%"${letters#?}"}"
          letters="${letters#?}"
        done ;;
      *) paths="$paths $a" ;;
    esac
  done
  opts=" $opts "

  case "$sub" in
    checkout|switch)
      # Two shapes of the same whole-tree discard: a whole-tree pathspec (with or without a ref,
      # with or without `--`), and the force flags, which throw the tree away while changing
      # branch — `git checkout -f main`, `git checkout -fq main`, `git switch -fc newb` and
      # `git switch --discard-changes main` are the #26 scenario spelled without a pathspec.
      # `git checkout <branch>`, `git switch -c <branch>` and `git checkout -- <named path>` are
      # scoped and stay allowed.
      case "$opts" in
        *" -f "*|*" --force "*|*" --discard-changes "*) deny "$seg" \
          "That discards every uncommitted change in the tree, including another agent's in a shared checkout. Use \`git checkout -- <path>\` for the one file you mean, or switch branches without the force flag." ;;
      esac
      whole_tree $paths && deny "$seg" \
        "That discards every uncommitted change in the tree, including another agent's in a shared checkout. Use \`git checkout -- <path>\` for the one file you mean, or switch branches without the force flag."

      # A NAMED-path checkout/switch is just as capable of silently overwriting one file's
      # uncommitted edit as the whole-tree form is of overwriting all of them — smaller blast
      # radius, not a different risk (#560). Only the pathspec strictly after `--` is probed: a
      # bare arg before it is a REF (a branch/commit name), and `paths` above already mixes those
      # in for the whole_tree() check — probing a ref against the working tree would false-deny an
      # ordinary branch switch that merely shares a name with an unrelated dirty file elsewhere.
      if [ "$seen_dd" -eq 1 ]; then
        local dd_paths="" dd_seen=0 has_ref=0 dirty names
        for a in "$@"; do
          if [ "$dd_seen" -eq 1 ]; then dd_paths="$dd_paths $a"; continue; fi
          case "$a" in
            --) dd_seen=1 ;;
            -*) ;;
            *) has_ref=1 ;;
          esac
        done
        if [ -n "$dd_paths" ]; then
          dirty=$(git -C "$dir" status --porcelain -- $dd_paths 2>/dev/null) || dirty=""
          # No ref before `--` means `git checkout -- <path>` restores index -> worktree only, so
          # a path that is dirty ONLY in the index (staged, worktree already matches — porcelain's
          # own 2nd/worktree column reads " ") is a no-op for that exact command, not a discard.
          # A ref before `--` replaces the worktree from the REF instead, so any difference from
          # it — staged or not, even an untracked path the ref would create — is real (review of
          # #560, caught empirically: the unfiltered form denied a harmless staged-only checkout).
          [ "$has_ref" -eq 1 ] || dirty=$(printf '%s\n' "$dirty" | awk 'substr($0,2,1) != " "')
          if [ -n "$dirty" ]; then
            names=$(printf '%s\n' "$dirty" | cut -c4- | tr '\n' ' ')
            deny "$seg" \
              "That would silently overwrite an uncommitted edit at ${names% } — the same discard #26 fixed for the whole tree, just scoped to one path. Commit or stash it first, then \`git checkout -- <path>\` once it's clean."
          fi
        fi
      fi
      ;;
    restore)
      # `--staged` without `--worktree` unstages and touches nothing in the tree — it is less
      # destructive than the per-path replacement the deny would name, so it is allowed whole.
      case "$opts" in
        *" --staged "*|*" -S "*)
          case "$opts" in *" --worktree "*|*" -W "*) ;; *) return 0 ;; esac ;;
      esac
      whole_tree $paths && deny "$seg" \
        "That discards every uncommitted change in the tree. Use \`git restore <path>\` for the one file you mean."
      ;;
    reset)
      case "$opts" in
        *" --hard "*) deny "$seg" \
          "That throws away the working tree, including another agent's uncommitted work in a shared checkout. Use \`git reset --keep\`, or give each branch its own worktree with \`$(guard_hint skills/implement-issue/scripts/make-worktree.sh)\`." ;;
      esac
      ;;
    clean)
      # `-n`/`--dry-run` wins over `-f`, whichever order they appear in and whether or not `-n` is
      # bundled: `git clean -ndf` deletes nothing. It is precisely the command the deny reason
      # recommends, so denying it would send the reader in a circle. Only an OPTION counts — a
      # `-n` after `--` is a file name.
      case "$opts" in *" -n "*|*" --dry-run "*) return 0 ;; esac
      case "$opts" in
        *" -f "*|*" --force "*) deny "$seg" \
          "That deletes untracked files irreversibly. Use \`git clean -n\` to look first, or \`git stash -u\` to keep them." ;;
      esac
      ;;
    push)
      # A dry run pushes nothing, so there is nothing for a guard to assert about it.
      case "$opts" in *" -n "*|*" --dry-run "*) return 0 ;; esac
      # `--force-with-lease` is NOT `--force`, so it skips the deny right below — but it still
      # falls through to the unconditional "bare push" deny two lines down, same as any other push
      # that isn't itself a call to the guard. Before #533 this segment was allowed whenever the
      # *line* also mentioned guarded-push.sh anywhere, guard call or not; per-segment judging means
      # that free ride is gone — only an actual `guarded-push.sh -- --force-with-lease` call (caught
      # earlier, by "the guard recognition" below) is allowed. A raw `--force-with-lease` push is
      # still exactly as unsafe in a shared checkout as `--force`; only the guard's own read-back
      # after the branch assertion makes it safe.
      case "$opts" in
        *" -f "*|*" --force "*) deny "$seg" \
          "A forced push overwrites whatever the remote holds, which in a shared checkout is another agent's branch. Use \`$(guard_hint skills/implement-issue/scripts/guarded-push.sh) -C <worktree> <branch> -- --force-with-lease\`." ;;
      esac
      deny "$seg" \
        "A bare push does not check which branch it is pushing — that is how #26 landed a commit in another agent's PR with exit 0. Use \`$(guard_hint skills/implement-issue/scripts/guarded-push.sh) -C <worktree> <branch>\`, which reads the remote back afterwards."
      ;;
    commit)
      deny "$seg" \
        "A bare commit does not check which branch HEAD is on — that is how #26 and #280 landed work on someone else's branch with exit 0. Use \`$(guard_hint skills/implement-issue/scripts/guarded-commit.sh) -C <worktree> <branch> -- <git commit args>\`."
      ;;
    merge)
      # `--abort`/`--continue`/`--quit` finish or unwind a merge that is already in progress; they
      # are not the write the guard exists for.
      case "$opts" in *" --abort "*|*" --continue "*|*" --quit "*) return 0 ;; esac
      deny "$seg" \
        "A merge is the largest single write in the lifecycle and the one with the widest window (#41). Use \`$(guard_hint skills/implement-issue/scripts/guarded-merge.sh) -C <worktree> <branch> -- <ref>\`."
      ;;
  esac
  return 0
}

# ------------------------------------------------------------------- judge one `gh` segment
# The one `gh` write the kit has a guard for (#512): `gh … pr … merge`. Everything else `gh` does —
# `pr view`, `pr checks`, `issue …`, `api …`, the REST merge endpoint included (no incident has used
# it) — returns without a verdict, and so does any word this walk cannot place.
judge_gh() { # $1 the segment  $2 gh_repo_seen (1 if GH_REPO= prefixed this segment, #533)
             # $3… its tokens, the `gh` command word first
  local seg="$1" gh_repo_seen="$2" want retarget=0 a
  shift 3
  # gh's options may sit before `pr` and again before `merge`: `-R`/`--repo`/`--hostname` take a
  # value, every other `-x` and `--x=y` stands alone. Any of `-R`/`--repo`/`--hostname`,
  # `GH_REPO=` (consumed by judge()'s prefix walk, reported in $gh_repo_seen), or a github.com pull
  # URL as the target names a repo this probe cannot see — #533's own assumption is that these deny
  # outright rather than resolving that repo's own profile, so `retarget` records the sighting and
  # skips the probe below entirely once set, regardless of what the flag/URL actually names.
  for want in pr merge; do
    while [ $# -gt 0 ]; do
      case "$1" in
        -R|--repo|--hostname) [ $# -ge 2 ] || return 0; retarget=1; shift 2 ;;
        # `-R<value>` glued (no space, no `=`) is the same short-flag shape `gh`'s own flag parser
        # (pflag) accepts for `-R owner/repo` — the value lives in THIS token, so only shift 1.
        -R?*) retarget=1; shift ;;
        --repo=*|--hostname=*) retarget=1; shift ;;
        --*=*|-*) shift ;;
        *) break ;;
      esac
    done
    [ "${1:-}" = "$want" ] || return 0
    shift
  done
  # `--disable-auto` cancels an auto-merge and merges nothing — this arm's `git merge --abort`.
  # Routed to the guard, it would read back as a merge queued for a landing that never comes.
  case " $* " in *" --disable-auto "*) return 0 ;; esac
  # `-R`/`--repo`/`--hostname` most commonly sit AFTER `merge` (`gh pr merge -R o/r 12 --squash`),
  # past where the per-want loop above already stopped (it only scans options standing before each
  # of `pr`/`merge`) — so the remaining args get their own retarget scan here, alongside the URL
  # form, rather than only catching the two positions the loop above happens to look at.
  for a in "$@"; do
    case "$a" in
      -R|--repo|--hostname|-R?*|--repo=*|--hostname=*) retarget=1 ;;
      # A URL naming a pull request, on github.com or any other host (GHES) that shapes one the
      # same way — the profiled repo it points at is never THIS command's own cwd either way.
      */pull/[0-9]*) retarget=1 ;;
    esac
  done
  [ "$gh_repo_seen" = 1 ] && retarget=1
  if [ "$retarget" != 1 ]; then
    # The git arms' probe, minus `fresh_init`: gh has no `-C`, so the repository is the one the walk
    # is standing in (a followed `cd` moves it), and a `git init` earlier on the line — even
    # `git init /tmp/x`, which moves nothing — makes no PR mergeable and no raw merge safe.
    [ "$FORCE" = 1 ] || is_profiled "$eff_dir" || return 0
  fi
  deny "$seg" \
    "A raw \`gh pr merge\` decides nothing: its one exit code covers both the merge on GitHub and gh's local cleanup, so a merge that landed reads as a failure (#178, #184). Use \`$(guard_hint skills/merge-pr/scripts/guarded-pr-merge.sh) [-R <owner/repo>] <PR> -- --squash --delete-branch\`, which reads the PR's state back and exits once per outcome." \
    "is the one \`gh\` write the kit routes through a guard (#512)" gh
}

# ------------------------------------------------------------------------------ the segment walk
# `;`, `&&`, `||`, `|`, `&` and newline all separate commands; `&&`/`||` simply yield an extra empty
# segment, which the walk skips. A here-string, not a pipe: the loop has to run in THIS shell so
# `deny`'s `exit 0` ends the hook rather than a subshell.
segments=$(printf '%s' "$clean" | tr ';|&' '\n\n\n')
eff_dir="$cwd"
fresh_init=0
while IFS= read -r segment; do
  case "$segment" in *[!\ ]*) ;; *) continue ;; esac
  judge "$segment"
done <<EOF
$segments
EOF

exit 0

#!/usr/bin/env bash
# repo-profile.sh — deterministic helper for the profile-repo skill.
#
# Two subcommands cover the skill's two paths so the model spends tokens on
# synthesis, not on issuing a dozen probe commands and reasoning over each:
#
#   show [dir]     Fast path (the common case). Print the committed profile if
#                  it exists; otherwise print "NO_PROFILE" and exit 3. One call,
#                  no ceremony — this is what the lifecycle skills want 95% of
#                  the time.
#
#   detect [dir]   Generation path (rare: first run or --refresh). Run every
#                  git/gh/marker/CI/label/template probe in one pass and emit a
#                  compact, labelled facts block for the model to turn into the
#                  filled template. Best-effort: any probe that can't answer
#                  prints "TODO" for that field rather than aborting. The one
#                  refusal (exit 2) is a kit missing its host helper,
#                  skills/_shared/scripts/_gh-host.sh: without it every read of a
#                  GitHub Enterprise repository would reach github.com (#514).
#
# All output is plain text designed to be read straight into context.

set -uo pipefail

PROFILE_REL=".claude/skills/repo-profile.md"
# Resolved BEFORE the cd below: $0 can be relative, and cd-ing into the target repo would break it.
# Kit root = three levels up from skills/profile-repo/scripts. $0 through any symlinks first — a
# plugin install reaches this file by link, and `pwd -P` alone canonicalizes the directory, not the
# link. No `readlink -f`: macOS's readlink has no -f. Same loop base-run-verdict.sh carries (#514,
# #531).
SELF="$0"
while [ -L "$SELF" ]; do
  _link=$(readlink -- "$SELF") || break
  case "$_link" in
    /*) SELF="$_link" ;;
    *)  SELF="$(dirname -- "$SELF")/$_link" ;;
  esac
done
KIT_ROOT=$(CDPATH= cd -- "$(dirname -- "$SELF")/../../.." && pwd -P) \
  || KIT_ROOT="$(dirname -- "$SELF")/../../.."
CMD="${1:-show}"
# Anchor to the repo root so the profile path resolves from any subdir/worktree.
# An explicit [dir] arg wins; otherwise use the git top-level, falling back to cwd.
DIR="${2:-}"
[ -z "$DIR" ] && DIR="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$DIR" 2>/dev/null || { echo "ERR: cannot cd to '$DIR'" >&2; exit 2; }

# Single convention for every probe: capture the output, print it if non-empty,
# else print "TODO: <hint>". The pipeline's exit status is irrelevant (head/sed/sort
# exit 0 on empty input, so `pipeline || echo TODO` is a dead fallback — never do that).
emit_or_todo() {
  local hint="$1" out
  out="$(cat)"
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  else
    printf 'TODO: %s\n' "$hint"
  fi
}

section() { printf '\n## %s\n' "$1"; }

# The self-managed-GitLab positive probe (Tracker section, below): `glab repo view` talks to that
# host live, so an unreachable/slow/misconfigured one can hang this call indefinitely — exactly
# what this command's best-effort contract forbids (same risk, same fix, as the ADR `claude mcp
# list` probe below: bound it where `timeout`(1) exists, GNU coreutils, not on a stock macOS;
# elsewhere fall back to the unbounded call rather than fail the whole probe over a missing tool).
glab_repo_view_ok() {
  command -v glab >/dev/null 2>&1 || return 1
  if command -v timeout >/dev/null 2>&1; then
    timeout 5s glab repo view >/dev/null 2>&1
  else
    glab repo view >/dev/null 2>&1
  fi
}

case "$CMD" in
  show)
    if [ -f "$PROFILE_REL" ]; then
      cat "$PROFILE_REL"
    else
      echo "NO_PROFILE"
      exit 3
    fi
    ;;

  tracker)
    # Reads the committed profile's Tracker line back as `<name> <detail>` (`github github.com`,
    # `azure-devops dev.azure.com/acme/Shop`, `other bitbucket.org`) — preflight's one consumer,
    # so its prerequisites can skip a CLI the profile's own tracker doesn't need.
    out=""
    [ -f "$PROFILE_REL" ] && out="$(sed -n \
      's/^- \*\*Tracker:\*\* \([a-z-]*\):\{0,1\} (\{0,1\}\([^) ]*\).*/\1 \2/p' "$PROFILE_REL")"
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
    else
      exit 3
    fi
    ;;

  detect)
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo "ERR: not inside a git repository — nothing to profile." >&2
      exit 4
    fi

    # The repository's own host (#514). `gh api` never infers a host, so on a GitHub Enterprise
    # checkout the branch-protection read below reached github.com. The helper is LOADED here,
    # before the first gh call, so a kit missing it refuses having called nothing. It RESOLVES once
    # `gh repo view` — which does infer the host from origin — has named the repository, and then
    # exports origin's host as GH_HOST for every call after it. Decided in ONE place, the helper;
    # `show` never loads it. KIT_ROOT was resolved before the cd, so the helper is the kit's; its
    # origin read is this repository's.
    GH_HOST_LIB="$KIT_ROOT/skills/_shared/scripts/_gh-host.sh"
    # CALLABLE, not merely readable: an empty or truncated helper sources cleanly and defines nothing.
    if [ -r "$GH_HOST_LIB" ]; then . "$GH_HOST_LIB" || true; fi
    command -v gh_host_resolve >/dev/null 2>&1 \
      || { echo "repo-profile: REFUSED — cannot load $GH_HOST_LIB; reinstall the kit" >&2; exit 2; }

    # Prefer the host `gh repo view --json url` has ALREADY resolved (#530) over the origin-remote
    # probe _gh-host.sh falls back to when handed a bare owner/repo: a GHE fork checkout (origin
    # still on github.com), a `gh repo set-default` pointed at a different remote, or a renamed
    # repository all reach the wrong host under that probe, and `gh repo view` already knows the
    # real one. Two separate reads, not one TSV split: `.url` can come back empty, and
    # `IFS=$'\t' read` treats a LEADING empty field as whitespace to trim rather than a field
    # boundary — silently misassigning the values after it. Both calls use gh's own --jq, matching
    # this script's existing style (no separate jq dependency here).
    SLUG="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
    VIEW_HOST=""
    if [ -n "$SLUG" ]; then
      VIEW_URL="$(gh repo view --json url --jq '.url // empty' 2>/dev/null || true)"
      [ -n "$VIEW_URL" ] && VIEW_HOST="$(printf '%s' "$VIEW_URL" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://##; s#/.*$##' | tr '[:upper:]' '[:lower:]')"
    fi
    if [ -n "$SLUG" ]; then
      # A HOST prefix makes gh_host_resolve take rule 1 outright — no origin match, no credential
      # probe needed — falling back to the pre-#530 origin-probe order only when the url field was
      # unreadable (a rare gh output surprise, not "no host": VIEW_HOST would then be empty too).
      if [ -n "$VIEW_HOST" ]; then
        gh_host_resolve "$VIEW_HOST/$SLUG" || exit 2
      else
        gh_host_resolve "$SLUG" || exit 2
      fi
      SLUG="$KIT_REPO_SLUG"
    fi

    echo "# Detected facts for $(pwd)"
    echo "# (TODO lines = the model must determine these by hand and leave a <!-- TODO --> marker)"

    section "Identity"
    printf 'slug: %s\n' "${SLUG:-TODO: gh repo view failed — auth? run: gh auth login}"
    emit_or_todo "default branch (gh repo view defaultBranchRef)" <<<"$(
      gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null | sed 's/^/default_branch: /')"

    section "Commit identity"
    echo "# A CLAUDE.md commit-identity rule WINS over git config if present:"
    emit_or_todo "no CLAUDE.md commit rule found — fall back to git config / log" <<<"$(
      grep -rIn --include=CLAUDE.md -e 'user\.email=' -e 'commit with' -e 'GitHub identity' . 2>/dev/null | head -5)"
    printf 'git config user.email: %s\n' "$(git config user.email 2>/dev/null || echo TODO)"
    printf 'git config user.name:  %s\n' "$(git config user.name 2>/dev/null || echo TODO)"
    echo "recent log authors (cross-check):"
    emit_or_todo "no commits yet — no authors to cross-check" <<<"$(
      git log -8 --format='  %an <%ae>' 2>/dev/null | sort -u)"

    section "Build system (marker files present)"
    emit_or_todo "no marker file at the repo root — identify the build system by hand" <<<"$(
      for m in *.slnx *.sln *.csproj package.json Cargo.toml go.mod pyproject.toml setup.py pom.xml build.gradle build.gradle.kts; do
        for f in $m; do [ -e "$f" ] && echo "  found: $f"; done
      done 2>/dev/null)"
    # surface node scripts verbatim — these ARE the real build/test/lint commands
    if [ -f package.json ]; then
      echo "package.json scripts:"
      grep -A30 '"scripts"' package.json 2>/dev/null | grep -E '^\s*"' | head -25 | sed 's/^/  /'
      for lf in package-lock.json yarn.lock pnpm-lock.yaml; do [ -e "$lf" ] && echo "  lockfile: $lf"; done
    fi

    section "CI gates (commands CI runs and fails on)"
    if [ -d .github/workflows ]; then
      emit_or_todo "workflows present but no recognizable gate command — read them by hand" <<<"$(
        grep -rhE 'run:|dotnet |npm |pnpm |yarn |cargo |go (build|test|vet)|mvn |gradle |pytest|ruff|black|gofmt|--verify-no-changes|--check' \
          .github/workflows/ 2>/dev/null | grep -vE '^\s*#' | sed -E 's/^\s+//' | sort -u | head -40 | sed 's/^/  /')"
    else
      echo "  TODO: no .github/workflows/ — CI gates unknown"
    fi

    section "Integration style (infer squash/merge/rebase)"
    echo "branch protection (required_* hints merge policy):"
    if [ -n "${SLUG:-}" ]; then
      emit_or_todo "branch protection unreadable (auth/permissions)" <<<"$(
        gh api "repos/$SLUG/branches/$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null)" \
          --jq '.protection' 2>/dev/null | head -20 | sed 's/^/  /')"
    else
      echo "  TODO: no slug — cannot read branch protection"
    fi
    echo "recent subjects (… (#N) on linear main ⇒ squash; merge commits ⇒ merge):"
    emit_or_todo "no commits yet — cannot infer the merge style" <<<"$(
      git log -12 --format='  %s' 2>/dev/null)"

    section "Labels (record exact strings — skills apply them verbatim)"
    emit_or_todo "gh label list failed or empty (auth?) — classify into type / priority / effort / scope by hand" <<<"$(
      gh label list --limit 200 --json name,description \
        --jq '.[] | "  " + .name + (if .description != "" then " — " + .description else "" end)' 2>/dev/null)"

    section "Issue templates"
    # GitHub's YAML forms and GitLab's markdown templates (#508) are two different mappings — see
    # skills/create-issue/references/issue-template.md — so each lists under its own directory
    # rather than one merged "found some templates" line a GitLab-only repo would otherwise get
    # for free with no GitHub directory to have earned it.
    found_templates=0
    if [ -d .github/ISSUE_TEMPLATE ]; then
      for t in .github/ISSUE_TEMPLATE/*; do [ -e "$t" ] && echo "  $(basename "$t")" && found_templates=1; done
    fi
    if [ -d .gitlab/issue_templates ]; then
      for t in .gitlab/issue_templates/*; do [ -e "$t" ] && echo "  $(basename "$t") (GitLab markdown template)" && found_templates=1; done
    fi
    if [ "$found_templates" -eq 0 ]; then
      echo "  TODO: no .github/ISSUE_TEMPLATE/ or .gitlab/issue_templates/ directory"
    fi

    section "Tracker"
    # Every lifecycle skill drives GitHub semantics through `gh`; this is the one probe that can
    # genuinely fail to reach a verdict (no origin remote at all) rather than answer "none".
    origin_url="$(git remote get-url origin 2>/dev/null || true)"
    if [ -z "$origin_url" ]; then
      echo "TODO: no origin remote — cannot name the tracker"
    else
      # Three remote-URL shapes, tried in order: `ssh://[user@]host[:port]/…`,
      # `http(s)://[user[:token]@]host[:port]/…` (a CI checkout token embeds credentials right
      # here — `x-access-token:ghp_…@github.com`), and the scp-like `git@host:owner/repo`. The
      # original single-pattern version only matched the last two, so an `ssh://` remote or one
      # carrying embedded credentials fell through unparsed and got misread as a non-GitHub host.
      tracker_host="$(printf '%s\n' "$origin_url" | sed -E \
        -e 's#^ssh://([^@/]+@)?([^/:]+)(:[0-9]+)?/.*#\2#' \
        -e 's#^(https?)://([^@/]+@)?([^/:]+)(:[0-9]+)?/.*#\3#' \
        -e 's#^git@([^:]+):.*#\1#')"
      # $SLUG (above) is `gh repo view` succeeding against THIS remote — true for github.com and
      # for a GHES host `gh` is configured to talk to, so it is the positive signal, not just a
      # literal "github.com" string match.
      if [ "$tracker_host" = "github.com" ] || [ -n "${SLUG:-}" ]; then
        printf 'tracker: github (%s)\n' "$tracker_host"
      elif [ "$tracker_host" = "gitlab.com" ] || glab_repo_view_ok; then
        printf 'tracker: gitlab (%s)\n' "$tracker_host"
      else
        # Azure DevOps: three remote shapes, each carrying <org>/<project> in a different spot.
        # The legacy `<org>.visualstudio.com` host serves the same organisation as
        # dev.azure.com/<org>, so it's normalised to the same canonical form.
        case "$tracker_host" in
          dev.azure.com|ssh.dev.azure.com)
            org_project="$(printf '%s\n' "$origin_url" | sed -E \
              -e 's#^https?://([^@/]+@)?dev\.azure\.com/([^/]+)/([^/]+)/_git/.*#\2/\3#' \
              -e 's#^git@ssh\.dev\.azure\.com:v3/([^/]+)/([^/]+)/.*#\1/\2#')" ;;
          *.visualstudio.com)
            org_project="$(printf '%s\n' "$origin_url" | sed -E \
              's#^https?://([^.]+)\.visualstudio\.com/([^/]+)/_git/.*#\1/\2#')" ;;
          *) org_project="$origin_url" ;;
        esac
        if [ "$org_project" != "$origin_url" ]; then
          printf 'tracker: azure-devops (dev.azure.com/%s)\n' "$org_project"
        else
          printf 'tracker: other: %s\n' "$tracker_host"
        fi
      fi
    fi

    section "Domain language"
    domain_lang="none"
    for f in CONTEXT.md CONTEXT-MAP.md docs/CONTEXT.md; do
      if [ -f "$f" ]; then domain_lang="$f"; break; fi
    done
    printf '  %s\n' "$domain_lang"

    section "ADRs"
    adr_root="none"
    adr_dir=""
    for d in docs/adr doc/adr adr .agents/adr; do
      if [ -d "$d" ]; then
        adr_n="$(find "$d" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
        adr_root="$d/ ($adr_n files)"
        adr_dir="$d"
        break
      fi
    done
    printf '  root: %s\n' "$adr_root"
    # The MCP half is a fact about THIS MACHINE'S session, never a fact about the repo (same rule
    # as the Worktree home probe's `note:` line above) — the "via AdrMcp" branch says so inline.
    if ! command -v claude >/dev/null 2>&1; then
      echo "  server: files only (claude CLI not found)"
    else
      # `claude mcp list` probes each configured server live, so an unreachable/slow one can hang
      # this call indefinitely — exactly what `detect`'s own contract ("best-effort... never
      # abort") forbids. Bound it where `timeout`(1) exists (GNU coreutils; not on a stock macOS);
      # elsewhere fall back to the unbounded call rather than fail the whole probe over a missing
      # tool.
      if command -v timeout >/dev/null 2>&1; then
        adr_mcp="$(timeout 5s claude mcp list 2>/dev/null || true)"
      else
        adr_mcp="$(claude mcp list 2>/dev/null || true)"
      fi
      if printf '%s\n' "$adr_mcp" | grep -iqE '(^|[^a-z])adr(mcp)?([^a-z]|$)'; then
        echo "  server: via AdrMcp (claude mcp list names 'adr') — on this machine only, not a fact about the repo"
      else
        echo "  server: files only (no 'adr' MCP server in \`claude mcp list\`)"
      fi
    fi

    section "Out-of-scope records"
    # The ADR root is probed FIRST, because that is where this kit puts prior rejections
    # (skills/_shared/prior-rejections.md): a rejection IS a decision, so it is an ADR with
    # `status: rejected` rather than a second folder with a second search path. A repo that also
    # keeps Matt Pocock's `.out-of-scope/`-shaped folder still gets reported — the two are not
    # exclusive — but reporting `none` over a root holding three rejected ADRs is the failure that
    # matters here: `create-issue` Step 3 and `triage-backlog` Step 4 read THIS section to decide
    # whether the lookup has anywhere to look, so a false `none` silently disables it in the one
    # repository that has records.
    oos_found=0
    if [ -n "$adr_dir" ]; then
      # `^status: rejected` at the start of a line, which is where the rendered frontmatter puts
      # it. Body prose quoting the phrase mid-line does not count, and `grep -l` stops at the first
      # hit per file so the count is files, not occurrences.
      rej_n="$(grep -l '^status: rejected' "$adr_dir"/*.md 2>/dev/null | wc -l | tr -d ' ')"
      if [ "${rej_n:-0}" -gt 0 ]; then
        printf '  %s/ `status: rejected` (%s records)\n' "$adr_dir" "$rej_n"
        oos_found=1
      fi
    fi
    if [ -d docs/out-of-scope ]; then
      oos_n="$(find docs/out-of-scope -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
      printf '  docs/out-of-scope/ (%s files)\n' "$oos_n"
      oos_found=1
    fi
    [ "$oos_found" -eq 1 ] || echo "  none"

    section "Coding standards"
    cs_found=0
    for f in CONTRIBUTING.md CODING_STANDARDS.md .editorconfig .globalconfig; do
      if [ -f "$f" ]; then printf '  %s\n' "$f"; cs_found=1; fi
    done
    if [ -f Directory.Build.props ]; then
      dbp_markers=""
      grep -qF 'EnforceCodeStyleInBuild' Directory.Build.props 2>/dev/null \
        && dbp_markers="EnforceCodeStyleInBuild"
      grep -qF 'AnalysisLevel' Directory.Build.props 2>/dev/null \
        && dbp_markers="${dbp_markers:+$dbp_markers, }AnalysisLevel"
      # Report exactly which marker(s) matched — printing a fixed string regardless of which of
      # the two actually fired would record a coding standard the repo never stated.
      [ -n "$dbp_markers" ] && { printf '  Directory.Build.props: %s\n' "$dbp_markers"; cs_found=1; }
    fi
    for m in .eslintrc* eslint.config.*; do
      for f in $m; do
        if [ -e "$f" ]; then printf '  %s\n' "$f"; cs_found=1; fi
      done
    done
    if [ -f pyproject.toml ] && grep -qF '[tool.ruff]' pyproject.toml 2>/dev/null; then
      echo "  pyproject.toml: [tool.ruff]"
      cs_found=1
    fi
    [ "$cs_found" -eq 0 ] && echo "  none"

    section "Conflict hot-spot candidates (derive resolutions in the template)"
    for c in Directory.Build.props CHANGELOG.md ./*.lock package-lock.json yarn.lock pnpm-lock.yaml Cargo.lock go.sum; do
      [ -e "$c" ] && echo "  ${c#./}"
    done
    echo "  (also: version files, generated/snapshot dirs, the solution/project files)"

    section "Architecture grain (scan CLAUDE.md / README for invariants)"
    emit_or_todo "no obvious invariants — leave blank-with-TODO" <<<"$(
      grep -rIn --include=CLAUDE.md --include=README.md \
        -iE 'never|always|in order|target-agnostic|do not|must not|keep .* (agnostic|isolated)' . 2>/dev/null | head -8 | sed 's/^/  /')"

    section "Worktree home"
    # MEASURED, never asserted (#71). This probe used to report only whether the directory EXISTS,
    # while the template wrote "(git-ignored)" beside it — a different question, and the wrong one:
    # an unignored worktree home is precisely the repo where a stray `git add -A` stages a worktree
    # as a single `160000` gitlink pointing at a commit no clone can fetch (#43).
    #
    # It runs the SAME guard implement-issue Step 4 and merge-pr Step 2 use as their precondition,
    # rather than re-deriving `check-ignore` here — the trailing-slash and `-q`-not-`-v` subtleties
    # have exactly one home — so the profile can never promise what those skills will then refuse.
    # Which home this repo actually has is a separate fact from whether it is ignored, and the
    # profile needs both: "record the one this repo uses" is unanswerable from ignore status alone,
    # since a rule can be in place for a directory that does not exist.
    found_home=0
    for h in .claude/worktrees .worktrees; do
      if [ -d "$h" ]; then echo "  present on disk: $h/"; found_home=1; fi
    done
    if [ "$found_home" -eq 0 ]; then
      echo "  present on disk: neither — no worktree made here yet; use the skills' default"
    fi

    if [ -x "$KIT_ROOT/scripts/worktrees-ignored.sh" ]; then
      if [ -x "$KIT_ROOT/scripts/main-worktree.sh" ]; then
        # `.` because the top of this script already cd'd into the explicit [dir] argument (or the
        # git top-level) — main-worktree.sh resolves the MAIN checkout's root from here regardless
        # of whether "here" is that main checkout, a linked worktree, or a subdirectory of either.
        #
        # This replaces `git rev-parse --show-toplevel`, which — asked from inside a LINKED
        # worktree, the normal state during implement-issue/merge-pr — answered with the linked
        # worktree itself, not the main checkout. worktrees-ignored.sh then judged the wrong
        # directory's .gitignore, and a MEASURED false pass got written into the profile as a
        # durable fact about the repo (#125). The `2>/dev/null` tolerance carries over unchanged.
        #
        # The exit code is checked explicitly, not just the string: main-worktree.sh's own contract
        # is "0 with empty stdout" for bare and "3" for no verdict, but empty stdout alone cannot
        # tell those apart. Trusting `[ -z "$wt_root" ]` on its own would read a real failure (exit 3
        # — a `git worktree list` error, not bareness) as "verified bare, nothing to check" and skip
        # the #43 ignore-hazard check silently instead of surfacing a TODO.
        wt_root="$("$KIT_ROOT/scripts/main-worktree.sh" -C . 2>/dev/null)"; wt_root_rc=$?
        if [ "$wt_root_rc" -ne 0 ]; then
          echo "  TODO: scripts/main-worktree.sh could not reach a verdict (exit $wt_root_rc) —" \
               "not a pass; verify BOTH homes by hand from the MAIN checkout"
        elif [ -z "$wt_root" ]; then
          # Empty output AND exit 0 means main-worktree.sh reached a verdict of "no main working
          # tree" — this DIR sits under a bare repository's worktree set. A bare repo has no working
          # tree for a stray `git add -A` to run in, so there is no #43 hazard to check — skip the
          # guard rather than feed it a bare path, which check-ignore refuses ("must be run in a
          # work tree") and this branch would otherwise misreport as "NOT ignored". Never "-> ignore
          # status verified": no verdict was reached, so nothing here is a pass.
          echo "  no main working tree here (bare repository) — nothing for the ignore guard to check"
        else
          wt_out="$("$KIT_ROOT/scripts/worktrees-ignored.sh" -C "$wt_root" 2>&1)"; wt_rc=$?
          printf '%s\n' "$wt_out" | sed 's/^/  /'
          case "$wt_rc" in
            0) echo "  -> ignore status verified; record it with the home above" ;;
            1) echo "  -> TODO: a worktree home is NOT ignored — say so in the profile, and do not" \
                    "write \"(git-ignored)\"; the lifecycle skills refuse to create a worktree here" ;;
            2) echo "  -> both homes ARE ignored (no worktree hazard), but the rule also hides" \
                    "$PROFILE_REL — TODO: narrow it, or this repo cannot carry a committed profile" ;;
            *) echo "  -> TODO: the guard could not reach a verdict (exit $wt_rc) — not a pass" ;;
          esac
          # A `note:` line above means the rule is machine-local or untracked: true here, false for
          # everyone else. It must not be written down as a property of the repo.
          case "$wt_out" in
            *"note:"*) echo "  -> TODO: the rule is not committed (see note above) — record it as" \
                            "\"ignored on this machine only\", not as a fact about the repo" ;;
          esac
        fi
      else
        # A missing tool, not a refusal (mirrors skills/_shared/worktree-ignore-check.md's own
        # fallback for a kit whose scripts/ was adopted incompletely): the guard itself is present,
        # but nothing here can safely resolve the main checkout's root from a directory that might
        # be a linked worktree. Rather than fall back to the derivation that produced #125, say so
        # and hand the reader the manual recipe, judged from the MAIN checkout.
        echo "  TODO: scripts/main-worktree.sh not found — cannot safely resolve the main working"
        echo "        tree from here (this may be a linked worktree). Verify BOTH homes by hand,"
        echo "        from the MAIN checkout, never a linked worktree:"
        echo "        git check-ignore -q .claude/worktrees/ && git check-ignore -q .worktrees/"
        echo "        (the trailing slash is load-bearing; -q, never -v)"
      fi
    else
      echo "  TODO: guard not found at <kit>/scripts/worktrees-ignored.sh — verify BOTH homes by hand:"
      echo "        git check-ignore -q .claude/worktrees/ && git check-ignore -q .worktrees/"
      echo "        (the trailing slash is load-bearing; -q, never -v)"
    fi

    echo ""
    echo "# End of facts. Fill references/profile-template.md from the above, then write $PROFILE_REL"
    ;;

  *)
    echo "usage: repo-profile.sh {show|detect} [dir]" >&2
    exit 2
    ;;
esac

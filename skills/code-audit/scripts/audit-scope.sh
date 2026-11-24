#!/usr/bin/env bash
# Measures and builds the SCOPE...TOP branch the code-audit skill reviews in place of a diff.
# Usage: bash audit-scope.sh measure <repo> <path>...
#        bash audit-scope.sh path <repo> <worktree> <path>...
#        bash audit-scope.sh snippet <dir> <name> <src-file>
# measure reports the size <repo>'s <path>... would audit and writes nothing to it: no object, ref, index, or
# worktree. path measures again (the tree may grow between the confirm and the build), then builds SCOPE
# (HEAD's tree minus the paths, the rule files kept) and TOP (HEAD's tree with the paths' working-tree content
# folded in) as two commits on top of HEAD, and checks TOP out detached into <worktree>, left in place for the
# report; it also prints clean: true when TOP's tree exactly matches HEAD's (the target had no uncommitted edits
# or untracked content), clean: false otherwise. snippet builds the same shape as a fresh scratch repo: an
# empty root commit (SCOPE) and a commit holding <src-file>'s bytes as <name> (TOP), with branch `audit` at TOP.
# Every path argument (<repo>, <worktree>, <path>, <dir>, <src-file>) must be absolute; a relative one exits 2.
# Nested repos, worktrees (gitlinks and untracked nested .git dirs) and anything under .claude/worktrees/ never
# enter TOP: they are dropped and reported rather than refused. The rule files (REVIEW.md, AGENTS.md, CLAUDE.md,
# and CONTRIBUTING / CONTRIBUTING.* in the root, .github/, and docs/) stay at HEAD's copy in both commits and
# are never part of the audited target, but only the ones that are real files there (measure and path report
# the ones actually dropped); a same-named directory, or any other CONTRIBUTING* name (CONTRIBUTING_hooks.py,
# CONTRIBUTING-bot.yml), is audited as ordinary content instead.
# Exit 0 on success. 1 when a git command fails outright (an ERR trap prints the failing command). 2 on a usage
# error or a refusal (not a git repo, a relative path, a missing path, a path outside the repo or inside a nested
# one, nothing to audit, a worktree or dir that already exists, a bad snippet name, a missing or empty source
# file, no commits yet, or a sparse checkout). 3 when the scope is over a cap (files, lines, or bytes); nothing is
# written on exit 2 or 3.
set -Eeuo pipefail
export LC_ALL=C
# The audited repo's environment can hand us GIT_DIR and friends (git exports them to hooks, and to every child of
# `rebase -x`): left alone, they'd override every -C flag below and point every git call at some other repo's
# HEAD, index, or worktree registration instead of <repo>'s own.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
# A partial clone missing an object it needs (is_blob's cat-file -t, a write-tree, or the rev-list/pack-objects
# pack build) lazily fetches it, which runs the audited repo's own core.sshCommand, credential.helper,
# core.gitProxy, or remote.*.uploadpack - the same "the audited repo's own config must never reach outside
# itself" concern g() neutralizes for hooks and filters, for a call this script makes against REPO_TOP itself.
export GIT_NO_LAZY_FETCH=1

# The scope stays within a review lens's reach: a constant here is easy to tune later
# without an interface change.
CAP_FILES=100
CAP_LINES=10000
CAP_BYTES=$((512 * 1024))

# The audit's commits never carry a real name or email.
IDENT_NAME=audit
IDENT_EMAIL=audit@localhost

self=$(realpath -- "${BASH_SOURCE[0]}")
prog=$(basename -- "$self")

SCRATCH=()
# SNIPPET_DIR: set once cmd_snippet has created its dir, cleared once it has finished without error; cleanup
# removes it on any failure in between, so a snippet that dies partway through (the user's global git config
# acting on `add`, say) doesn't leave a half-built dir that makes a retry fail with "already exists".
SNIPPET_DIR=
# WORKTREE_DIR: the same, for cmd_path's own claim: set once it has created the worktree dir, cleared once
# cmd_path's own build has finished (right before it prints the report). A failure in between (a required
# clean filter failing on the SCOPE-removal step, say) would otherwise leave an empty dir behind that makes
# a retry fail with "already exists" too.
WORKTREE_DIR=
# REAL_MODE: path -> the real index's own recorded mode (100644, 100755, or 120000), set by measure_scope's
# own real-index scan and read back by cmd_path's content-staging loop. Declared here, as an associative
# array, so a plain reset inside measure_scope (REAL_MODE=()) keeps that type across calls.
declare -A REAL_MODE=()
cleanup() { rm -f "${SCRATCH[@]}"; [[ -z $SNIPPET_DIR ]] || rm -rf -- "$SNIPPET_DIR"; [[ -z $WORKTREE_DIR ]] || rm -rf -- "$WORKTREE_DIR"; }
trap cleanup EXIT
# LAST_G: g()'s own invocation while it runs, cleared right after a successful one. $BASH_COMMAND inside this trap
# would be g()'s function body on every call (always the same line), never the git subcommand actually invoked, so
# the trap reports LAST_G instead and only falls back to $BASH_COMMAND for a failure outside g() (mktemp, wc, ...).
LAST_G=
trap 'echo "$prog: git failed: ${LAST_G:-$BASH_COMMAND}" >&2; exit 1' ERR

usage() {
  echo "usage: bash $prog measure <repo> <path>..." >&2
  echo "       bash $prog path <repo> <worktree> <path>..." >&2
  echo "       bash $prog snippet <dir> <name> <src-file>" >&2
  exit 2
}

# g ARGS...: git with no embedded-repo advice, no quote-mangled paths, no GPG signing (an audit's commits are
# plumbing, never meant to be signed), no hooks - neither a core.hooksPath/.git/hooks script nor a config-based
# hook.<name>.command/.event entry (hook.post-index-change is the one event this script's own index-mutating
# calls against REPO_TOP, such as read-tree, rm --cached, and update-index, can themselves raise) - no
# fsmonitor, and no pager (a repo-local pager.<cmd> can run an arbitrary command too, whenever a call's stdout
# reaches a tty), scoped to this script's own git calls: each of these can run an arbitrary command from the
# repo's own config, and every call here writes to a scratch index or ref, not only the worktree's own
# materialization. This hardens only what this script itself does; it does not make the rest of the audit
# flow safe against a hostile repo, since the phases that run afterward (domains.sh and
# audit.js's lenses) use ordinary git against the resulting worktree - see the skill's Safety section for the
# full picture. Keeps its own exit code (a caller's `|| ...` still works), but records the real command in
# LAST_G first, so a failure the caller doesn't handle is reported accurately.
g() {
  LAST_G="git -c advice.addEmbeddedRepo=false -c core.quotePath=false -c commit.gpgsign=false -c core.hooksPath=/dev/null -c core.fsmonitor=false -c hook.post-index-change.enabled=false --no-pager $*"
  local rc=0
  git -c advice.addEmbeddedRepo=false -c core.quotePath=false -c commit.gpgsign=false -c core.hooksPath=/dev/null -c core.fsmonitor=false -c hook.post-index-change.enabled=false --no-pager "$@" || rc=$?
  ((rc == 0)) && LAST_G=
  return $rc
}

refuse() { echo "$prog: $1" >&2; exit 2; }

require_abs() { [[ $1 == /* ]] || refuse "$2 must be absolute: $1"; }

# resolve_repo REPO: sets REPO_TOP to REPO's realpath'd toplevel (its own, for a linked worktree), refuses a
# relative path, a missing repo, one that isn't a git repo, a sparse checkout (files not on disk would read
# as deletions), or an unborn HEAD (no commits yet).
resolve_repo() {
  require_abs "$1" repo
  [[ -d $1 ]] || refuse "no such repo: $1"
  REPO_TOP=$(g -C "$1" rev-parse --show-toplevel 2> /dev/null) || refuse "not a git repo: $1"
  local sparse
  sparse=$(g -C "$REPO_TOP" config --type=bool core.sparseCheckout 2> /dev/null || echo false)
  [[ $sparse == false ]] || refuse "a sparse checkout can't be audited: $1"
  g -C "$REPO_TOP" rev-parse --verify -q HEAD > /dev/null 2>&1 || refuse "no commits yet: $1"
}

# check_tmpdir: with REPO_TOP set (by resolve_repo, called just before this in every command that builds
# anything), refuses when ${TMPDIR:-/tmp} resolves at or under REPO_TOP: every mktemp call below (the
# scratch index, the ls-files listings, the unreadable-dir scan's own output, and the batched stat/cat
# calls) would otherwise land inside the audited repo itself and get swept back up by the very untracked
# scan it exists to measure.
check_tmpdir() {
  local rt
  rt=$(realpath -m -- "${TMPDIR:-/tmp}")
  if [[ $rt == "$REPO_TOP" || $rt == "$REPO_TOP"/* ]]; then
    refuse "TMPDIR must not be inside the audited repo: ${TMPDIR:-/tmp}"
  fi
}

# in_repo PATH: sets RP to PATH's realpath, refusing one outside REPO_TOP, missing on disk, or inside a repo
# nested under it (a submodule or another checkout). A missing path is refused on its own, never silently dropped
# from the target list by a later M_FILES == 0 check (that check is for a path that exists but holds nothing
# auditable). Called directly, never through $(...): refuse's exit must end the script, not a subshell running
# this function.
in_repo() {
  local nd t
  # Sentinel capture, not a plain $(...): realpath's own stdout always ends in a newline that isn't part of
  # the resolved path, and a plain command substitution strips every trailing newline it finds, not only
  # that one - silently resolving a target literally named f\n to f instead. Appending a non-newline byte and
  # stripping exactly "<newline><sentinel>" off the end removes only realpath's own and keeps the real path's
  # bytes exactly as they are.
  RP=$(realpath -m -- "$1"; printf .)
  RP=${RP%$'\n.'}
  if [[ $RP != "$REPO_TOP" && $RP != "$REPO_TOP"/* ]]; then
    refuse "path outside the repo: $1"
  fi
  [[ -e $RP ]] || refuse "missing path: $1"
  nd=$RP
  while [[ ! -d $nd ]]; do nd=$(dirname -- "$nd"); done
  t=$(g -C "$nd" rev-parse --show-toplevel 2> /dev/null) || t=
  [[ $t == "$REPO_TOP" ]] || refuse "path inside a nested repo: $1"
}

# is_blob RELPATH: true when HEAD_SHA:RELPATH is a real file (a blob) rather than a directory, a gitlink, or
# nothing at all. HEAD_SHA is the caller's own local (cmd_measure's or cmd_path's), resolved once there rather
# than re-read as the literal string "HEAD" here.
is_blob() {
  local t
  t=$(g -C "$REPO_TOP" cat-file -t "$HEAD_SHA:$1" 2> /dev/null) || return 1
  [[ $t == blob ]]
}

# under_target REL: true when REL (a rule file's path relative to REPO_TOP) falls inside one of the current
# build_specs call's own target paths in TARGETS - equal to a targeted file, under a targeted directory, or
# the target is the repo root ('') - so the positive specs alone would have swept it into TOP, and excluding
# it from SPECS actually drops it from the target.
under_target() {
  local rel=$1 t
  for t in "${TARGETS[@]}"; do
    if [[ -z $t || $rel == "$t" || $rel == "$t"/* ]]; then
      return 0
    fi
  done
  return 1
}

# exclude_rule_file NAME: adds a literal exclude for NAME to SPECS, but only when it's a real blob at HEAD_SHA: a
# literal pathspec otherwise also matches a same-named directory and everything beneath it. Records it in
# RULE_EXCLUDED only when it also falls under one of TARGETS (under_target): a rule file outside every
# target was never going to be swept in, so excluding it drops nothing and isn't reported as if it did.
exclude_rule_file() {
  is_blob "$1" || return 0
  SPECS+=(":(top,exclude,literal)$1")
  under_target "$1" && RULE_EXCLUDED+=("$1")
  return 0
}

# exclude_contributing LOC: excludes LOC/CONTRIBUTING (the bare name, no extension) and every CONTRIBUTING.*
# entry in HEAD_SHA's own listing of LOC (the root's listing when LOC is empty), each only when it's a real blob:
# the glob requires a literal dot right after the name, so CONTRIBUTING_hooks.py or CONTRIBUTING-bot.yml are
# never swept in.
exclude_contributing() {
  local loc=$1 e base entries
  local -a args=()
  [[ -z $loc ]] || args=(-- "$loc")
  exclude_rule_file "${loc}CONTRIBUTING"
  entries=$(g -C "$REPO_TOP" ls-tree --name-only "$HEAD_SHA" "${args[@]}" 2> /dev/null) || entries=
  while IFS= read -r e; do
    [[ -n $e ]] || continue
    base=${e##*/}
    [[ $base == CONTRIBUTING.* ]] || continue
    exclude_rule_file "$e"
  done <<< "$entries"
}

# build_specs PATH...: sets SPECS to one :(top,literal)<rel> pathspec per PATH (or :(top) for the repo root, since
# :(top,literal). matches nothing), plus the standing excludes: anything under .claude/worktrees/, and the rule
# files, which stay at HEAD's copy in both commits and are never the audited target. Also sets TARGETS to each
# PATH's own relative path ('' for the repo root), for under_target to check a rule-file exclude against, and
# RULE_EXCLUDED to the rule-file paths actually dropped from one of those targets, for cmd_measure/cmd_path to
# report: each is checked against HEAD_SHA first (exclude_rule_file/exclude_contributing) and then against TARGETS
# (under_target), so a same-named directory, a CONTRIBUTING* name with no dot right after it, or a rule file
# outside every target, is never swept in and is never reported as excluded.
build_specs() {
  SPECS=()
  RULE_EXCLUDED=()
  TARGETS=()
  local p
  for p in "$@"; do
    require_abs "$p" path
    in_repo "$p"
    if [[ $RP == "$REPO_TOP" ]]; then
      SPECS+=(':(top)')
      TARGETS+=('')
    else
      SPECS+=(":(top,literal)${RP#"$REPO_TOP"/}")
      TARGETS+=("${RP#"$REPO_TOP"/}")
    fi
  done
  SPECS+=(':(top,exclude).claude/worktrees/')
  exclude_rule_file REVIEW.md
  exclude_rule_file CLAUDE.md
  exclude_rule_file AGENTS.md
  exclude_contributing ''
  exclude_contributing '.github/'
  exclude_contributing 'docs/'
}

# quote_name NAME: NAME, double-quoted and C-escaped if it holds a double quote, a backslash, or a control byte
# (git's own quoting, which fires on those bytes even with core.quotePath=false); as is otherwise.
quote_name() {
  local s=$1 out='' c i len
  if [[ $s == *[\"\\]* || $s =~ [[:cntrl:]] ]]; then
    len=${#s}
    for ((i = 0; i < len; i++)); do
      c=${s:i:1}
      case $c in
        '"') out+='\"' ;;
        "\\") out+="\\\\" ;;
        $'\a') out+='\a' ;;
        $'\b') out+='\b' ;;
        $'\t') out+='\t' ;;
        $'\n') out+='\n' ;;
        $'\v') out+='\v' ;;
        $'\f') out+='\f' ;;
        $'\r') out+='\r' ;;
        *)
          if [[ $c =~ [[:cntrl:]] ]]; then
            printf -v c '\\%03o' "'$c"
          fi
          out+=$c
          ;;
      esac
    done
    printf '"%s"\n' "$out"
  else
    printf '%s\n' "$s"
  fi
}

# escape_find_glob NAME: NAME with every fnmatch wildcard byte (\, *, ?, [) backslash-escaped, for building a
# literal `find -path` pattern out of a real path component: -path matches its argument as a glob, so an
# unescaped M_SKIPPED entry that happens to itself hold one of these bytes (a nested repo literally named
# `n*`, say) would prune every sibling its glob also matches, not just itself.
escape_find_glob() {
  local s=$1 out='' c i len
  len=${#s}
  for ((i = 0; i < len; i++)); do
    c=${s:i:1}
    case $c in
      [\\*?[]) out+="\\$c" ;;
      *) out+=$c ;;
    esac
  done
  printf '%s\n' "$out"
}

# measure_scope: with REPO_TOP, HEAD_SHA, and SPECS set, loads a scratch index (mktemp outside the checkout,
# trap-removed) with HEAD_SHA's tree and lists what TOP would hold: every cached and untracked file ls-files
# matches, plus any path the real index already tracks under SPECS that HEAD_SHA's own tree doesn't (staged but
# not yet committed, and gitignored, so the untracked scan below would miss it too), minus entries missing on
# disk and nested repos (a trailing-/ others entry, a 160000 cached one, or one found by walking up an
# already-tracked file's own directory for a .git entry), which are skipped and counted instead. The cached,
# untracked, and real-index entries are each read from a temp file rather than a process substitution, so a
# git call that fails outright is caught by the ERR trap directly instead of the while loop just seeing its
# input end early. Writes nothing to the audited repo. Sets M_FILES, M_LINES, M_BYTES, M_UNTRACKED (the others
# entries that counted, which excludes a path the real index tracks (staged, not yet committed) and one later
# routed to M_SKIPPED or M_SKIPPED_ANCESTOR instead), M_SKIPPED
# (the nested repos' names: a tracked gitlink, an untracked nested repo, or one created inside an
# already-tracked directory), M_SKIPPED_ANCESTOR (a path whose own ancestor directory does not resolve to
# exactly where it should, through a symlink, whether that lands inside REPO_TOP or outside it - a different
# kind of drop than a nested repo, reported under its own label), M_GITLINKS (the narrower subset of
# M_SKIPPED that are tracked gitlinks, for cmd_path's clean comparison), and M_UNREADABLE (a directory under the
# target this process couldn't read into, or a regular file it couldn't read, best effort, never a refusal). M_UNREADABLE is filled
# only when no cap is exceeded, the one case where a caller prints it.
# Also sets links, regs, and REAL_MODE (a path -> the real index's own recorded mode, for every tracked entry
# this function's own real-index scan sees), not local: cmd_path stages them into TOP the same way this
# function already enumerated them, the same kind of script-level output as M_FILES and the rest.
measure_scope() {
  local idx rec mode path cached_out untracked_out real_out t tdir rel
  idx=$(mktemp)
  SCRATCH+=("$idx")
  GIT_INDEX_FILE=$idx g -C "$REPO_TOP" read-tree "$HEAD_SHA"
  M_FILES=0 M_LINES=0 M_BYTES=0
  M_UNTRACKED=() M_SKIPPED=() M_SKIPPED_ANCESTOR=() M_GITLINKS=() M_UNREADABLE=()
  REAL_MODE=()
  local -a real=()

  cached_out=$(mktemp)
  SCRATCH+=("$cached_out")
  GIT_INDEX_FILE=$idx g -C "$REPO_TOP" ls-files -z --cached -s -- "${SPECS[@]}" > "$cached_out"
  while IFS= read -r -d '' rec; do
    mode=${rec%% *}
    path=${rec#*$'\t'}
    if [[ $mode == 160000 ]]; then
      M_SKIPPED+=("$path")
      M_GITLINKS+=("$path")
    else
      real+=("$path")
    fi
  done < "$cached_out"

  untracked_out=$(mktemp)
  SCRATCH+=("$untracked_out")
  GIT_INDEX_FILE=$idx g -C "$REPO_TOP" ls-files -z --others --exclude-standard -- "${SPECS[@]}" > "$untracked_out"
  while IFS= read -r -d '' rec; do
    if [[ $rec == */ ]]; then
      M_SKIPPED+=("${rec%/}")
    else
      real+=("$rec")
      M_UNTRACKED+=("$rec")
    fi
  done < "$untracked_out"

  # The real index's own tracked entries, not the scratch one above: a path staged but not yet committed, and
  # gitignored, is in neither HEAD_SHA's tree nor the untracked scan (which correctly excludes it as ignored), so
  # without this it would silently vanish from the target. Almost every normal entry here duplicates one already
  # in `real` from the HEAD-based scan above (an unmodified tracked file is in both); seen dedupes on path.
  real_out=$(mktemp)
  SCRATCH+=("$real_out")
  g -C "$REPO_TOP" ls-files --cached -s -z -- "${SPECS[@]}" > "$real_out"
  local -A seen=()
  local already
  for already in "${real[@]}"; do seen[$already]=1; done
  while IFS= read -r -d '' rec; do
    mode=${rec%% *}
    path=${rec#*$'\t'}
    [[ $mode == 160000 ]] && continue
    REAL_MODE[$path]=$mode
    [[ -n ${seen[$path]+x} ]] && continue
    real+=("$path")
    seen[$path]=1
  done < "$real_out"

  # Split real into existing symlinks and existing regular files with bash's own -L/-f tests (a stat(2) each,
  # never a forked process); a path missing on disk is silently dropped here (neither counted, skipped, nor
  # reported unreadable), consistent with measure_scope's own best-effort contract for content that no longer
  # matches what the index or the untracked scan expected to find. Something still on disk but neither a
  # symlink nor a regular file (a FIFO, socket, or device node) is reported unreadable instead, below, not
  # silently dropped the same way: only a path genuinely missing on disk stays a silent skip. This already
  # gives the exact file count, so a target far over CAP_FILES stops right here, before stat or wc is ever
  # forked for a single file's content.
  # First, a path whose own directory does not resolve to exactly where it should (a tracked directory replaced
  # on disk by a symlink - to outside REPO_TOP, or to another directory inside it - say) is routed to
  # M_SKIPPED_ANCESTOR instead: a symlink is never what it points to, and that rule has to hold for a symlinked ancestor of f too,
  # not only for f itself being a symlink (the links/regs split right below already handles that case). An
  # exact match against the one path the directory should resolve to, not merely "still somewhere under
  # REPO_TOP": a symlinked ancestor can land inside REPO_TOP just as wrongly as outside it (another tracked
  # directory's own content, say), and realpath -m on the dirname resolves every level in between, so f itself
  # is never followed by realpath, only the directory holding it. resolved_cache runs that realpath once per
  # distinct dirname, not once per file: a directory holding many files would otherwise fork one realpath per
  # file, growing linearly with the target's size well before the CAP_FILES check below ever gets a chance to
  # turn away an oversized one. Second, and cached the same way, a nested repo created inside an already-tracked
  # directory (ls-files recurses right into one, unlike the untracked scan's own trailing-/ case above, since the
  # directory already holds tracked content) is caught by walking f's own directory up to REPO_TOP for a .git
  # entry at or above it; every file under that root is routed to M_SKIPPED too, named once by the nested root's
  # own path, the same way a gitlink or an untracked nested repo is named above. A regular file that fails -r is
  # routed to M_UNREADABLE rather than regs: the batched stat/cat/hash-object calls below have no per-file error
  # handling and would otherwise abort the whole script on one unreadable file.
  local f dir resolved expected
  local -A resolved_cache=() nested_cache=() nested_reported=()
  links=() regs=()
  # nested_root_of DIR: sets NESTED_ROOT to the relative path of the outermost directory, at or above DIR
  # (DIR itself included) and below REPO_TOP, that holds its own .git entry, or '' when none of DIR's path
  # components do. Recurses upward one directory level at a time, but nested_cache (dynamically scoped to this
  # measure_scope call, the same way with_filter_overrides below reaches cmd_path's own locals) makes every
  # distinct directory's answer cost one check at most, however many files or sibling directories share it.
  nested_root_of() {
    local d=$1 parent
    if [[ -z $d || $d == . ]]; then
      NESTED_ROOT=
      return
    fi
    if [[ -n ${nested_cache[$d]+x} ]]; then
      NESTED_ROOT=${nested_cache[$d]}
      return
    fi
    parent=${d%/*}
    [[ $parent == "$d" ]] && parent=.
    nested_root_of "$parent"
    [[ -n $NESTED_ROOT || ! -e $REPO_TOP/$d/.git ]] || NESTED_ROOT=$d
    nested_cache[$d]=$NESTED_ROOT
  }
  for f in "${real[@]}"; do
    dir=${f%/*}
    [[ $dir == "$f" ]] && dir=.
    if [[ -z ${resolved_cache[$dir]+x} ]]; then
      # Sentinel capture, the same technique the readlink call below already uses: realpath's own stdout
      # always ends in a newline that isn't part of the resolved path, and a plain command substitution
      # would strip every trailing newline it finds, not only that one - misreading a directory whose own
      # name ends in a literal newline as resolving to something shorter than it actually does.
      resolved=$(realpath -m -- "$REPO_TOP/$dir"; printf .)
      resolved_cache[$dir]=${resolved%$'\n.'}
    fi
    resolved=${resolved_cache[$dir]}
    expected=$REPO_TOP
    [[ $dir == . ]] || expected=$REPO_TOP/$dir
    if [[ $resolved != "$expected" ]]; then
      M_SKIPPED_ANCESTOR+=("$f")
      continue
    fi
    nested_root_of "$dir"
    if [[ -n $NESTED_ROOT ]]; then
      if [[ -z ${nested_reported[$NESTED_ROOT]+x} ]]; then
        M_SKIPPED+=("$NESTED_ROOT")
        nested_reported[$NESTED_ROOT]=1
      fi
      continue
    fi
    if [[ -L "$REPO_TOP/$f" ]]; then
      links+=("$f")
    elif [[ -f "$REPO_TOP/$f" ]]; then
      if [[ -r "$REPO_TOP/$f" ]]; then
        regs+=("$f")
      else
        M_UNREADABLE+=("$f")
      fi
    elif [[ -e "$REPO_TOP/$f" && ! -d "$REPO_TOP/$f" ]]; then
      # Neither a symlink nor a regular file but still something on disk (a FIFO, socket, or device node,
      # typically a tracked regular file typechanged into one of these without a matching commit): named
      # under unreadable rather than silently dropped, the same "never silently clean" treatment an actually
      # unreadable file or directory already gets. Only a path genuinely missing on disk stays a silent skip.
      # A directory is excluded here on purpose: a tracked file typechanged into a plain directory is readable,
      # and its own content is already folded into TOP by the untracked scan above as ordinary new files, so f
      # itself is silently dropped here, the same as a path missing on disk. A tracked file typechanged into a
      # directory that's itself a nested repo is caught by that same untracked scan instead (its trailing-/
      # entry routes it to M_SKIPPED); without the ! -d guard, f would wrongly land under both skipped and
      # unreadable.
      M_UNREADABLE+=("$f")
    fi
  done

  # M_UNTRACKED is filtered down to the untracked paths that actually landed in links or regs: one under a
  # nested root found inside an already-tracked directory just above, or past a symlinked ancestor, was routed
  # to M_SKIPPED or M_SKIPPED_ANCESTOR instead and must not still be reported as an untracked file folded into
  # TOP. A path the real index tracks (staged but not yet committed: the HEAD-based scratch index doesn't have it, so
  # the untracked scan listed it) is not untracked either, and is filtered out the same way.
  local -A folded=()
  local lf
  for lf in "${links[@]}" "${regs[@]}"; do folded[$lf]=1; done
  local -a m_untracked_folded=()
  for lf in "${M_UNTRACKED[@]}"; do
    [[ -n ${folded[$lf]+x} && -z ${REAL_MODE[$lf]+x} ]] && m_untracked_folded+=("$lf")
  done
  M_UNTRACKED=("${m_untracked_folded[@]}")

  # Unreadable directories under the target (scan_unreadable_dirs below): best-effort only (find's own permission
  # errors are swallowed, never a refusal), so a target this process can't fully see at least gets named rather
  # than silently clean. Pruned at .claude/worktrees/, .git (neither is ever part of the audited target), and every path already in
  # M_SKIPPED (the nested repos and gitlinks above: their own internal unreadable subdirectories were never
  # going to be audited in the first place, so neither descending into any of these nor reporting what's inside
  # them would name a real gap) and filtered against the repo's own ignore rules: a gitignored directory was
  # never going to be swept into the untracked scan above, readable or not, so reporting it the same way would
  # flag a gap that isn't really there. This runs only now, after the real-split loop just above has had its
  # own chance to add a nested root found inside an already-tracked directory to M_SKIPPED: built any earlier,
  # prune_expr would miss that entry and let find descend into it, reporting its own unreadable subdirectories
  # as a gap that was never really there either. find's own output goes to a temp file, not a < <(...) process
  # substitution: find exits non-zero routinely, the moment it meets the very unreadable directory this scan
  # exists to detect, and under set -E that would otherwise fire the ERR trap inside the process substitution's
  # own subshell, printing a misleading "git failed: find ..." even though nothing here actually failed; the
  # `|| true` on the redirect tolerates that expected exit the same way 2> /dev/null already tolerates the
  # permission-denied message itself.
  # REPO_TOP itself goes through escape_find_glob too, not only each M_SKIPPED entry below: it's just as much a
  # real path component prepended onto every -path pattern here, and left unescaped, a REPO_TOP that itself
  # holds a glob byte (an fnmatch bracket expression, say) would keep every one of these patterns from matching
  # anything at all, pruning nothing and letting find descend into .git, .claude/worktrees, and every skipped
  # nested repo's own unreadable subdirectories - exactly what this prune exists to keep out.
  # Called only on a path that goes on to print its lists (never before an exit-3 over-cap), since find and one
  # check-ignore fork per hit are wasted work whose result over_cap would discard.
  scan_unreadable_dirs() {
    local t tdir path rel skip unreadable_out ignore_rc repo_top_glob
    repo_top_glob=$(escape_find_glob "$REPO_TOP")
    local -a prune_expr=(-path "$repo_top_glob/.claude/worktrees" -o -path "$repo_top_glob/.git")
    for skip in "${M_SKIPPED[@]}"; do prune_expr+=(-o -path "$repo_top_glob/$(escape_find_glob "$skip")"); done
    # ! -readable alone misses a directory that's readable but not searchable (0400, say): its own entries can
    # still be listed, but nothing inside it can be stat'd or opened, which is just as fatal to auditing its
    # content as a missing read bit is - a tracked file under one would otherwise vanish from TOP with no report.
    for t in "${TARGETS[@]}"; do
      tdir=$REPO_TOP
      [[ -z $t ]] || tdir=$REPO_TOP/$t
      [[ -d $tdir ]] || continue
      unreadable_out=$(mktemp)
      SCRATCH+=("$unreadable_out")
      find "$tdir" \( \( "${prune_expr[@]}" \) -prune \) -o \( -type d \( ! -readable -o ! -executable \) -print0 \) \
        > "$unreadable_out" 2> /dev/null || true
      while IFS= read -r -d '' path; do
        rel=${path#"$REPO_TOP"/}
        # Cleared right after, whichever way it goes: check-ignore's rc=1 (not ignored) is an ordinary, expected
        # outcome here, not a git failure, but g() itself has no way to know that and leaves LAST_G set on any
        # non-zero rc - stale, for the ERR trap to wrongly blame on this call if some later, unrelated command
        # fails before any other g() call clears it first.
        ignore_rc=0
        g -C "$REPO_TOP" check-ignore -q --no-index -- "$rel" 2> /dev/null || ignore_rc=$?
        LAST_G=
        ((ignore_rc == 0)) && continue
        M_UNREADABLE+=("$rel")
      done < "$unreadable_out"
    done
    # Targets that overlap (a directory and one beneath it) walk the same unreadable directory twice.
    local -A unreadable_seen=()
    local -a unreadable_once=()
    for rel in "${M_UNREADABLE[@]}"; do
      [[ -n ${unreadable_seen[$rel]+x} ]] && continue
      unreadable_seen[$rel]=1
      unreadable_once+=("$rel")
    done
    M_UNREADABLE=("${unreadable_once[@]}")
  }

  M_FILES=$((${#links[@]} + ${#regs[@]}))
  ((M_FILES <= CAP_FILES)) || return 0

  # Symlinks: counted directly from readlink's own output (the link itself, never what it points to, tracked
  # or not, in or out of the repo), one at a time, never batched with the regular files below.
  local target nl
  for f in "${links[@]}"; do
    # Sentinel capture, not a plain $(readlink ...): readlink's own stdout always ends in a newline that
    # isn't part of the link's own target, and a plain command substitution strips every trailing newline
    # it finds, not only that one - losing a real trailing newline the target itself has. Appending a
    # non-newline byte and then stripping exactly "<newline><sentinel>" off the end removes only readlink's
    # own and leaves every byte of the real target, newlines included, intact.
    target=$(readlink -- "$REPO_TOP/$f"; printf .)
    target=${target%$'\n.'}
    nl=${target//[^$'\n']/}
    M_LINES=$((M_LINES + ${#nl}))
    M_BYTES=$((M_BYTES + ${#target}))
  done
  if ((${#regs[@]} > 0)); then
    # Every regular file's byte size in one batched stat (the replacement is quoted: an unquoted $REPO_TOP would
    # have any `&` in it read by patsub_replacement, on by default since bash 5.2, as the matched text). A temp
    # file, not a < <(...) process substitution: stat exiting non-zero on one file (gone, or turned unreadable,
    # between the -r check above and here) would otherwise fire the ERR trap inside the process substitution's
    # own subshell, the same misleading "git failed: xargs ..." the unreadable-directory scan above is fixed
    # for; `|| true` tolerates it the same way, since M_BYTES is already a best-effort total.
    local sz stat_out
    stat_out=$(mktemp)
    SCRATCH+=("$stat_out")
    printf '%s\0' "${regs[@]/#/"$REPO_TOP"/}" | xargs -0 stat -c%s -- > "$stat_out" || true
    while IFS= read -r sz; do M_BYTES=$((M_BYTES + sz)); done < "$stat_out"

    # Lines, in one batched pass rather than one wc -l fork per file. Always run, even once the byte cap above
    # is already exceeded: over_cap needs the full exact M_LINES too, to report the first cap in its
    # files-then-lines-then-bytes order rather than whichever of lines or bytes happened to be counted first.
    # `|| true` for the same race the stat pass above is already fixed for: a file removed or turned unreadable
    # between the -r check and here makes cat fail, and under pipefail that would abort the whole script with a
    # misleading "git failed" line even though M_LINES is already a best-effort total.
    M_LINES=$((M_LINES + $(printf '%s\0' "${regs[@]/#/"$REPO_TOP"/}" | xargs -0 cat -- | wc -l || true)))
  fi
  # The same lines-then-bytes test over_cap applies, so the scan runs exactly when the caller goes on to print.
  ((M_LINES > CAP_LINES || M_BYTES > CAP_BYTES)) || scan_unreadable_dirs
}

print_size() { echo "size: $M_FILES files, $M_LINES lines, $M_BYTES bytes"; }

print_names() {
  local label=$1 suffix=$2 cap=$3 n i=0
  shift 3
  n=$#
  echo "$label: $n$suffix"
  for n in "$@"; do
    ((i < cap)) || break
    printf '  %s\n' "$(quote_name "$n")"
    i=$((i + 1))
  done
}

# over_cap: with M_FILES set, and M_LINES/M_BYTES set exactly whenever M_FILES is within its own cap, prints
# size: and over the cap: ... and exits 3 if any cap is exceeded, in that order (files, then lines, then
# bytes). The files-over-cap size line names only the file count: measure_scope never counts lines or bytes
# once files alone are over cap, and a 0 for each would read as an exact (and wrong) total rather than as
# nothing counted.
over_cap() {
  local what=
  if ((M_FILES > CAP_FILES)); then
    echo "size: $M_FILES files"
    what="files (max $CAP_FILES)"
  elif ((M_LINES > CAP_LINES)); then
    print_size
    what="lines (max $CAP_LINES)"
  elif ((M_BYTES > CAP_BYTES)); then
    print_size
    what="bytes (max $CAP_BYTES)"
  fi
  [[ -z $what ]] || {
    echo "over the cap: $what"
    exit 3
  }
}

# commit_tree TREE PARENT DATE MSG: a commit-tree call under the audit identity, PARENT omitted for a root commit.
commit_tree() {
  local tree=$1 parent=$2 date=$3 msg=$4
  local -a p=()
  [[ -z $parent ]] || p=(-p "$parent")
  GIT_AUTHOR_NAME=$IDENT_NAME GIT_AUTHOR_EMAIL=$IDENT_EMAIL GIT_COMMITTER_NAME=$IDENT_NAME GIT_COMMITTER_EMAIL=$IDENT_EMAIL \
    GIT_AUTHOR_DATE=$date GIT_COMMITTER_DATE=$date \
    g -C "$REPO_TOP" commit-tree "$tree" "${p[@]}" -m "$msg"
}

cmd_measure() {
  (($# >= 2)) || usage
  resolve_repo "$1"
  check_tmpdir
  local HEAD_SHA
  HEAD_SHA=$(g -C "$REPO_TOP" rev-parse --verify 'HEAD^{commit}')
  shift
  build_specs "$@"
  measure_scope
  ((M_FILES > 0)) || refuse "nothing to audit: $*"
  over_cap
  echo "repo: $REPO_TOP"
  echo "head: $HEAD_SHA"
  print_size
  print_names untracked '' "$CAP_FILES" "${M_UNTRACKED[@]}"
  # Capped at the same flat 10 as rule files excluded and unreadable just below, not at the full count: a
  # large nested repo or symlinked ancestor would otherwise make this listing, which the skill's confirm
  # question copies verbatim, grow unbounded.
  print_names skipped ' nested repos' 10 "${M_SKIPPED[@]}"
  print_names 'skipped (symlinked ancestor)' '' 10 "${M_SKIPPED_ANCESTOR[@]}"
  print_names 'rule files excluded' '' 10 "${RULE_EXCLUDED[@]}"
  print_names unreadable '' 10 "${M_UNREADABLE[@]}"
}

cmd_path() {
  (($# >= 3)) || usage
  resolve_repo "$1"
  check_tmpdir
  local HEAD_SHA
  HEAD_SHA=$(g -C "$REPO_TOP" rev-parse --verify 'HEAD^{commit}')
  local worktree=$2
  require_abs "$worktree" worktree
  shift 2
  build_specs "$@"
  measure_scope
  ((M_FILES > 0)) || refuse "nothing to audit: $*"
  over_cap

  # Claim the path with the real act of creating it, not a check that's stale by the time the build below
  # finishes much later: a concurrent path build racing for the same slug fails here, cleanly, with nothing
  # built, rather than partway through init/pack/checkout with a half-built worktree left behind. git init
  # itself accepts a pre-existing empty directory as its target. mkdir -p the parent first, never the worktree
  # itself: a first-ever audit has no parent directory yet, and a missing parent must never read as "already
  # exists"; the worktree path itself still gets a plain mkdir, so an actually-existing one is still refused.
  # Its own failure (a parent path component that's a regular file, say) is captured and refused here, exit 2,
  # rather than left for the ERR trap: that trap's exit 1 and "git failed" wording are reserved for an actual
  # git command failing, never a plain mkdir.
  local mkdir_p_err
  if ! mkdir_p_err=$(mkdir -p -- "$(dirname -- "$worktree")" 2>&1); then
    refuse "can't create $(dirname -- "$worktree"): $mkdir_p_err"
  fi
  # "already exists" names the one failure the skill actually retries the next suffix on: a genuine
  # EEXIST race, or a stale leftover. Any other mkdir failure (permissions, a read-only filesystem, a missing
  # grandparent that isn't there even after -p above, ...) gets its own real message instead, so that retry
  # logic - which matches on the literal text, not on mkdir's exit code - never loops silently on a cause a
  # retry can't fix.
  local mkdir_err
  if ! mkdir_err=$(mkdir -- "$worktree" 2>&1); then
    if [[ -e $worktree ]]; then
      refuse "already exists: $worktree"
    else
      refuse "can't create $worktree: $mkdir_err"
    fi
  fi
  WORKTREE_DIR=$worktree

  local date idx_scope idx_top scope_tree scope top_tree top
  date=$(g -C "$REPO_TOP" log -1 --no-show-signature --format='@%ct +0000' "$HEAD_SHA")

  # Neutralize this repo's own configured filter drivers (clean, smudge, and process) for every git call below
  # that could run one: idx_scope's own rm --cached just below still runs a repo-local required filter.<name>.clean
  # (and .process) despite -f and --cached, and the hash-object calls further down run clean too. Only this
  # repo's own local and worktree-scoped config, never the user's global or system one: a global filter
  # (git-lfs, say) is the user's own trusted setup and must keep working, not get overridden for every audit.
  # Read with `--local --includes` and, separately, `--worktree --includes` (same as `--local`, reading
  # .git/config, when there is only one worktree and extensions.worktreeConfig isn't set, so filter_seen's dedup
  # already covers that case; it errors, swallowed the same way, only once a second worktree exists without that
  # extension), never a plain `config`: `--local` alone skips both a driver reached through the repo's own
  # include.path/includeIf and one set only in .git/config.worktree (a linked worktree's own
  # .git/worktrees/<id>/config.worktree), and a plain `config` also reads the global and system files. Each
  # matched key is overridden to an empty value, never `cat`: `cat` can't answer the long-running
  # filter.<name>.process handshake, so a working, required filter would fail the build closed instead of just
  # going unneutralized, and `filter.<name>.required=false` alongside it lets a repo-local required filter build
  # cleanly once its own command is empty, rather than erroring that the driver isn't available. The regex's
  # greedy `(.+)` lets a driver name that itself holds a dot (`filter.a.b.smudge`) still resolve to the right
  # name and key, and filter_seen dedupes the two reads so a key set in both scopes gets overridden once, not
  # twice. Collected as parallel key/value arrays, not `-c key=value` strings: git's `-c` splits at the FIRST
  # '=', so a driver name holding its own '=' (`filter.x=y.clean`) would, as a `-c` string, resolve to key
  # `filter.x` instead of `filter.x=y.clean`, leaving that driver unneutralized. with_filter_overrides, below,
  # instead passes these through GIT_CONFIG_COUNT/GIT_CONFIG_KEY_<n>/GIT_CONFIG_VALUE_<n>, which take the key and
  # value as fully separate strings with no '='-splitting step at all.
  local -a filter_cfg_keys=() filter_cfg_vals=()
  local -A filter_seen=()
  local fline key
  while IFS= read -r fline; do
    [[ -n $fline ]] || continue
    key=${fline%% *}
    if [[ $key =~ ^filter\.(.+)\.(clean|smudge|process)$ ]] && [[ -z ${filter_seen[$key]+x} ]]; then
      filter_seen[$key]=1
      filter_cfg_keys+=("filter.${BASH_REMATCH[1]}.${BASH_REMATCH[2]}" "filter.${BASH_REMATCH[1]}.required")
      filter_cfg_vals+=('' false)
    fi
  done < <(
    g -C "$REPO_TOP" config --local --includes --get-regexp '^filter\.' 2> /dev/null || true
    g -C "$REPO_TOP" config --worktree --includes --get-regexp '^filter\.' 2> /dev/null || true
  )

  # with_filter_overrides ARGS...: runs g ARGS..., with filter_cfg_keys/filter_cfg_vals (built above) exported
  # for that one call only, as one GIT_CONFIG_KEY_<n>/GIT_CONFIG_VALUE_<n> pair per entry, appended after
  # whatever GIT_CONFIG_COUNT this process already had on entry (0 when it had none) rather than always
  # starting at index 0: a caller that already set its own GIT_CONFIG_COUNT/KEY_*/VALUE_* overrides before
  # invoking this script (safe.directory, say, to audit a repo owned by a different user) keeps them visible
  # to g, not hidden for the one call and then discarded. GIT_CONFIG_COUNT is restored to that original value
  # afterward (unset again only when it was unset on entry), regardless of g's own exit status (rc, captured
  # the same way g() captures its own), and only this call's own added KEY_*/VALUE_* indices are unset, never
  # one below the original count.
  with_filter_overrides() {
    local i rc=0 base=${GIT_CONFIG_COUNT:-0} had_count=${GIT_CONFIG_COUNT+x}
    export GIT_CONFIG_COUNT=$((base + ${#filter_cfg_keys[@]}))
    for i in "${!filter_cfg_keys[@]}"; do
      export "GIT_CONFIG_KEY_$((base + i))=${filter_cfg_keys[$i]}" "GIT_CONFIG_VALUE_$((base + i))=${filter_cfg_vals[$i]}"
    done
    g "$@" || rc=$?
    for i in "${!filter_cfg_keys[@]}"; do unset "GIT_CONFIG_KEY_$((base + i))" "GIT_CONFIG_VALUE_$((base + i))"; done
    if [[ -n $had_count ]]; then
      export GIT_CONFIG_COUNT=$base
    else
      unset GIT_CONFIG_COUNT
    fi
    return $rc
  }

  idx_scope=$(mktemp)
  SCRATCH+=("$idx_scope")
  GIT_INDEX_FILE=$idx_scope g -C "$REPO_TOP" read-tree "$HEAD_SHA"
  # -f: this removal is never "are you sure", since the real index and working tree are untouched either way.
  GIT_INDEX_FILE=$idx_scope with_filter_overrides -C "$REPO_TOP" rm --cached -r -q -f --ignore-unmatch -- "${SPECS[@]}"
  scope_tree=$(GIT_INDEX_FILE=$idx_scope g -C "$REPO_TOP" write-tree)
  scope=$(commit_tree "$scope_tree" "$HEAD_SHA" "$date" "audit scope")

  idx_top=$(mktemp)
  SCRATCH+=("$idx_top")
  # idx_scope's own tree, not a fresh read-tree HEAD_SHA plus its own rm --cached: scope_tree already has the
  # target's content removed (a tracked gitlink or a tracked file deleted on disk included, neither ever in
  # links/regs, and everything SPECS excludes - the rule files, .claude/worktrees/ - left alone), and a second
  # rm --cached here would, like idx_scope's own, run a repo-local required clean filter a second time for no
  # reason: content goes back in below through hash-object --path, which still runs git's own built-in
  # conversions (text/eol, autocrlf, ident, working-tree-encoding) and any filter configured outside this
  # repo's own local/worktree scope; with_filter_overrides there neutralizes only that repo-local/worktree-scoped
  # clean/smudge/process set, not every filter driver.
  GIT_INDEX_FILE=$idx_top g -C "$REPO_TOP" read-tree "$scope_tree"
  # hash-object --path=<rel> plus update-index --add --index-info, never `add -A`: --path keeps git's own
  # built-in conversions (text/eol, core.autocrlf, ident, working-tree-encoding) running, so an unmodified
  # target's blob still matches HEAD's own (a --no-filters hash would diverge from it instead, the same kind
  # of false-dirty mismatch the clean comparison below avoids for a gitlink), while with_filter_overrides on
  # this same call still neutralizes a repo-local clean filter (filter.<name>.clean) on the way into the object
  # (a trusted global one still runs, same as it does on checkout). The standing .claude/worktrees/ exclude can't collide
  # with a gitignored path elsewhere under the target (add's own "paths are ignored" refusal), and links/regs
  # is exactly what measure_scope already enumerated and cap-checked.
  # NUL-terminated records (-z), never comma-joined --cacheinfo triples: a path can itself hold a comma, a tab,
  # or a newline, and -z's NUL record separator is the only format that round-trips all of those raw, with no
  # quoting step of our own to get wrong.
  local -a cacheinfo=()
  local f mode blob target
  for f in "${links[@]}"; do
    # Sentinel capture, not a direct pipe from readlink and not a plain $(readlink ...): readlink's own
    # stdout always ends in a newline that isn't part of the link's actual target, and piping that straight
    # into hash-object --stdin would hash the link target plus a spurious trailing byte it never had, while a
    # plain command substitution would just as wrongly drop a real trailing newline the target itself has.
    # Appending a non-newline byte and stripping exactly "<newline><sentinel>" off the end removes only
    # readlink's own and keeps the real target's bytes exactly as they are.
    target=$(readlink -- "$REPO_TOP/$f"; printf .)
    target=${target%$'\n.'}
    blob=$(printf '%s' "$target" | g -C "$REPO_TOP" hash-object -w --stdin)
    cacheinfo+=("120000 $blob"$'\t'"$f")
  done
  # core.fileMode=false: git itself ignores a permission-bit-only change on an already-tracked file (and so
  # does a filesystem that always reports every file executable), so a file already in the real index must
  # keep ITS OWN recorded mode (REAL_MODE, set by measure_scope's own real-index scan), not the filesystem's
  # current -x bit - the real index, never HEAD, is authoritative: a pending `update-index --chmod` can
  # already differ from HEAD's own committed mode. core.symlinks=false: the real index can also hold a
  # genuine symlink entry (120000) for a path whose checkout materializes as a plain file (the symlink's
  # target text, written as-is); f is already known to land in regs by disk type alone, but the real index -
  # never the filesystem's rendering of it - still says whether it's actually a symlink, so that case is
  # checked first, independent of core.fileMode. Only when there's no real-index entry at all (a genuinely new
  # untracked file) does mode fall back to a stat-based guess, and under core.fileMode=false that guess is
  # always 100644, never the filesystem's -x bit, matching git's own ce_mode_from_stat convention of
  # distrusting the exec bit when there's no existing regular-mode index entry to inherit it from. Both
  # config values are read once here rather than per file.
  local filemode_false=false symlinks_false=false real_mode
  [[ $(g -C "$REPO_TOP" config --type=bool core.fileMode 2> /dev/null || echo true) == false ]] && filemode_false=true
  [[ $(g -C "$REPO_TOP" config --type=bool core.symlinks 2> /dev/null || echo true) == false ]] && symlinks_false=true
  for f in "${regs[@]}"; do
    real_mode=${REAL_MODE[$f]-}
    if $symlinks_false && [[ $real_mode == 120000 ]]; then
      mode=120000
    elif $filemode_false && [[ $real_mode == 100644 || $real_mode == 100755 ]]; then
      mode=$real_mode
    elif $filemode_false; then
      mode=100644
    else
      mode=100644
      [[ -x "$REPO_TOP/$f" ]] && mode=100755
    fi
    # Known limitation, not fixed here: hash-object runs the text/eol conversion with no safe-crlf safeguard
    # (confirmed empirically: pointing GIT_INDEX_FILE at an index already holding the path's committed blob
    # doesn't change its behavior, unlike `git add`), so a file committed with CRLF before .gitattributes
    # added text=auto can be renormalized to LF going into TOP even though git status reports it clean. See
    # the Not covered note in SKILL.md.
    blob=$(with_filter_overrides -C "$REPO_TOP" hash-object -w --path="$f" -- "$REPO_TOP/$f")
    cacheinfo+=("$mode $blob"$'\t'"$f")
  done
  if ((${#cacheinfo[@]} > 0)); then
    printf '%s\0' "${cacheinfo[@]}" | GIT_INDEX_FILE=$idx_top g -C "$REPO_TOP" update-index --add -z --index-info
  fi
  top_tree=$(GIT_INDEX_FILE=$idx_top g -C "$REPO_TOP" write-tree)
  top=$(commit_tree "$top_tree" "$scope" "$date" "audit target")

  # clean: true only when the target's working-tree content exactly matched HEAD_SHA when this worktree was
  # built (no uncommitted edits, no untracked content anywhere in the target), reported below for the user's
  # own judgment. Compared against a tree with the same tracked gitlinks removed as TOP's own, never HEAD_SHA's
  # raw tree: a gitlink the target holds, untouched, is absent from TOP (it's never added) but still present at
  # HEAD_SHA, and that asymmetry alone must never read as dirty.
  local idx_clean clean_tree clean
  idx_clean=$(mktemp)
  SCRATCH+=("$idx_clean")
  GIT_INDEX_FILE=$idx_clean g -C "$REPO_TOP" read-tree "$HEAD_SHA"
  ((${#M_GITLINKS[@]} == 0)) || GIT_INDEX_FILE=$idx_clean g -C "$REPO_TOP" update-index --force-remove -- "${M_GITLINKS[@]}"
  clean_tree=$(GIT_INDEX_FILE=$idx_clean g -C "$REPO_TOP" write-tree)
  if [[ $top_tree == "$clean_tree" ]]; then clean=true; else clean=false; fi

  # The worktree is a fresh, standalone repo with no local git config of its own at all - not a real
  # `git worktree add`, which would share REPO_TOP's own .git/config (and, for a linked REPO_TOP, its common
  # dir too): a filter driver reached only through an includeIf keyed on a worktree's own gitdir
  # (`gitdir:.../.claude/worktrees/**`) never matched when the filter overrides were read above (that condition is
  # evaluated against REPO_TOP's own gitdir, which this one never is), and a config-based hook
  # (`hook.<name>.command`/`.event`, which ignores core.hooksPath entirely) needs that same kind of local
  # config to be defined in the first place. Neither reaches anything inside a repo with no local config
  # section of its own to read either from.
  #
  # Its objects are a real, packed copy of HEAD_SHA's, SCOPE's, and TOP's own trees and blobs, plus just those
  # three commits (rev-list --objects --no-walk lists exactly the given commits, never their ancestors, with
  # each one's own tree still walked in full; pack-objects serializes the result; index-pack stores that pack
  # in the new repo) - never REPO_TOP's whole history: `rev-list --objects "$scope" "$top"` with no --no-walk
  # would walk every ancestor all the way back to the root commit, duplicating the audited repo's entire
  # object store into every single audit - and never an .git/objects/info/alternates pointer into REPO_TOP's
  # own store either: an alternates-based worktree would be at the mercy of REPO_TOP's own next
  # `git gc --prune=now`, which has nothing of its own left to keep SCOPE and TOP reachable once
  # they're not also the target of a registered worktree - and this build adds no ref to REPO_TOP for that
  # either (cmd_path never does). The .git/shallow line marks HEAD_SHA as the boundary, so git treats it as
  # having no parents instead of trying, and failing, to read ones this pack never included - the same
  # mechanism `git clone --depth` uses, and the only way `git log`, `rev-list --count`, and
  # `diff main...HEAD` stay usable against a commit
  # whose real parents were deliberately left out; it also means a REPO_TOP that is itself a shallow clone
  # needs nothing extra done for it. rev-list and pack-objects only ever read already-committed objects and
  # index-pack only ever writes to the new repo's own store, so none of the three touches a working tree, a
  # hook, or a filter driver; index-pack's one line of progress output on success is redirected away, since
  # cmd_path's own stdout is the line-oriented report printed below. main and master both point at SCOPE (HEAD
  # stays detached at TOP) so a reviewer that starts from the default branch finds
  # exactly SCOPE and resolves its diff to SCOPE...TOP; absent that (no remote exists here either), HEAD~1 also
  # lands on SCOPE, since SCOPE is TOP's direct parent.
  # --object-format: REPO_TOP's own (sha1 or sha256), never git's own default, which is always sha1 regardless of
  # REPO_TOP's: left to that default, index-pack below would reject the pack it's handed (built from REPO_TOP's
  # own sha256 objects) as corrupted the moment REPO_TOP itself is a sha256 repo.
  g -C "$worktree" init -q -b audit --object-format="$(g -C "$REPO_TOP" rev-parse --show-object-format)" -- .
  g -C "$REPO_TOP" rev-list --objects --no-walk "$HEAD_SHA" "$scope" "$top" | g -C "$REPO_TOP" pack-objects --stdout -q \
    | g -C "$worktree" index-pack --stdin > /dev/null
  printf '%s\n' "$HEAD_SHA" > "$worktree/.git/shallow"
  # Known limitation, not fixed here: this checkout still runs a GLOBAL filter (git-lfs, say), left alone above
  # on purpose (the "must keep working" comment there), but the fresh worktree has none of REPO_TOP's own
  # .git/lfs/objects or remote to smudge an LFS pointer from, so a required one fails the checkout - and this
  # build - outright. See the Not covered note in SKILL.md.
  g -C "$worktree" checkout -q --detach "$top"
  g -C "$worktree" branch -q main "$scope"
  g -C "$worktree" branch -q master "$scope"
  WORKTREE_DIR=

  echo "repo: $REPO_TOP"
  echo "head: $HEAD_SHA"
  echo "scope: $scope"
  echo "top: $top"
  echo "worktree: $worktree"
  echo "clean: $clean"
  print_size
  print_names untracked '' "$CAP_FILES" "${M_UNTRACKED[@]}"
  # Capped at the same flat 10 as rule files excluded and unreadable just below, not at the full count: a
  # large nested repo or symlinked ancestor would otherwise make this listing, which the skill's confirm
  # question copies verbatim, grow unbounded.
  print_names skipped ' nested repos' 10 "${M_SKIPPED[@]}"
  print_names 'skipped (symlinked ancestor)' '' 10 "${M_SKIPPED_ANCESTOR[@]}"
  print_names 'rule files excluded' '' 10 "${RULE_EXCLUDED[@]}"
  print_names unreadable '' 10 "${M_UNREADABLE[@]}"
}

cmd_snippet() {
  (($# == 3)) || usage
  local dir=$1 name=$2 src=$3
  require_abs "$dir" dir
  require_abs "$src" "source file"
  # Refused only for the exact names git itself treats specially inside a worktree, compared case-
  # insensitively (.git, .gitattributes, .gitignore, .gitmodules) - the only names that could collide with or
  # corrupt the scratch repo's own git machinery, or be silently reinterpreted by it. Never a prefix match on
  # .git*: that would also wrongly refuse a legitimate target like .gitlab-ci.yml or ~/.gitconfig, which are
  # audited under their own name like any other dotfile (.bashrc, .envrc, ...), same as the skill documents for
  # a file outside any repo. Only the four exact names above fall back to a name like snippet.<ext> instead
  # (see the skill).
  local name_lc=${name,,}
  case $name_lc in
    '' | */* | . | .. | -* | .git | .gitattributes | .gitignore | .gitmodules) refuse "bad name: $name" ;;
  esac
  [[ -f $src && -s $src ]] || refuse "missing or empty source file: $src"

  # -L: $src can itself be a symlink, and the cap must measure what cp below actually copies (the target's
  # real size), not the symlink's own tiny size. The -f/-s tests above and `wc -l` already follow it via
  # normal file-open semantics; only this one stat call needs the flag.
  M_FILES=1 M_LINES=$(wc -l < "$src") M_BYTES=$(stat -c%s -L -- "$src")
  over_cap

  # Claim dir with the real act of creating it, not a check-then-mkdir -p: a concurrent snippet build racing for
  # the same dir fails here, cleanly, with nothing written. No -p: <dir> is always an immediate child of an
  # already-existing notes folder. "already exists" names the one failure the skill actually retries
  # the next suffix on; any other mkdir failure gets its own real message instead (see cmd_path's own claim).
  local mkdir_err
  if ! mkdir_err=$(mkdir -- "$dir" 2>&1); then
    if [[ -e $dir ]]; then
      refuse "already exists: $dir"
    else
      refuse "can't create $dir: $mkdir_err"
    fi
  fi
  SNIPPET_DIR=$dir
  REPO_TOP=$(realpath -- "$dir")
  g -C "$REPO_TOP" init -q -b audit -- .
  local empty_tree scope top_tree top blob mode=100644
  empty_tree=$(g -C "$REPO_TOP" hash-object -w -t tree --stdin < /dev/null)
  scope=$(commit_tree "$empty_tree" '' '@0 +0000' 'audit scope')
  cp -- "$src" "$REPO_TOP/$name"
  # hash-object --no-filters plus update-index --cacheinfo, never `add`: the user's global gitignore
  # (excludesFile) can make `add` refuse a name it matches, and global attributes (core.autocrlf, say) can
  # filter the bytes on the way into the object, so TOP would no longer hold the source file's own bytes.
  [[ -x $REPO_TOP/$name ]] && mode=100755
  blob=$(g -C "$REPO_TOP" hash-object -w --no-filters -- "$REPO_TOP/$name")
  g -C "$REPO_TOP" update-index --add --cacheinfo "$mode,$blob,$name"
  top_tree=$(g -C "$REPO_TOP" write-tree)
  top=$(commit_tree "$top_tree" "$scope" '@0 +0000' 'audit target')
  g -C "$REPO_TOP" update-ref refs/heads/audit "$top"

  # M_FILES/M_LINES/M_BYTES are already the exact, already-cap-checked totals computed above (a snippet is
  # always exactly one file); a diff_size call here would overwrite them with diff --numstat's own line count,
  # which disagrees with wc -l's by one on a file whose last line has no trailing newline.
  echo "repo: $REPO_TOP"
  echo "scope: $scope"
  echo "top: $top"
  print_size
  print_names untracked '' 10
  print_names skipped ' nested repos' 0
  SNIPPET_DIR=
}

case ${1:-} in
  measure)
    shift
    cmd_measure "$@"
    ;;
  path)
    shift
    cmd_path "$@"
    ;;
  snippet)
    shift
    cmd_snippet "$@"
    ;;
  *) usage ;;
esac

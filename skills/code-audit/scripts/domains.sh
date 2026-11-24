#!/usr/bin/env bash
# Pick the domain lenses for an audit (rust, kubernetes, kernel, supply-chain), with the evidence for each.
# Usage: bash domains.sh <repo> <base>
# Compares the working tree (untracked files included) with merge-base(<base>, HEAD).
set -euo pipefail
# Byte-wise matching: in a UTF-8 locale, grep drops lines (or whole files) with bytes that aren't UTF-8.
export LC_ALL=C

if [[ $# -ne 2 ]]; then
  echo "usage: bash domains.sh <repo> <base>" >&2
  exit 2
fi

if [[ ! -d $1 ]]; then
  echo "domains.sh: not a directory: $1" >&2
  exit 2
fi
cd "$1"
if ! ref=$(git merge-base "$2" HEAD 2> /dev/null); then
  echo "domains.sh: unknown ref: $2" >&2
  exit 2
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
g() { git -c core.quotePath=false -c diff.mnemonicPrefix=false -c diff.noprefix=false "$@"; }

# Generated, vendored, and lock files never select a domain.
skip='(^|/)(vendor|third_party|node_modules)/|\.lock$|(^|/)(go\.sum|package-lock\.json|pnpm-lock\.yaml)$'
# Docs can name kernel or Kubernetes APIs without changing behavior, so they never select a domain either.
docs='\.(md|mdx|rst|txt|adoc)$'
# Test paths, used with the JS/TS filter below to keep a component helper's free mount() out of the kernel scan. A
# dependency or build path is never a test, even under tests/.
tests='(^|/)(tests?|__tests__|spec)/|(^|/)test_[^/]+$|(^|/)[^/]+_test\.[^/.]+$|(^|/)[^/]+\.(test|spec)\.[^/]+$'
# A free mount() in a JS or TS test is a component helper (enzyme, @vue/test-utils), not the syscall; libc.mount() still is.
js='\.(jsx?|tsx?|[cm][jt]s|vue|svelte)$'
# CI, release, and dependency paths, which the supply-chain domain reads.
ci='^\.github/(workflows|actions)/|(^|/)\.gitlab-ci\.yml$|^\.gitlab/|^\.tekton/|(^|/)Jenkinsfile$|^\.circleci/'
ci+='|(^|/)\.travis\.yml$|(^|/)azure-pipelines\.ya?ml$|^\.azure-pipelines/|^\.buildkite/|(^|/)\.drone\.yml$'
ci+='|(^|/)cloudbuild\.ya?ml$|(^|/)\.?zuul\.ya?ml$|^\.?zuul\.d/'
release='(^|/)(release|publish)[^/]*(/|$)|(^|/)\.goreleaser'
deps="$ci|$release"
deps+='|(^|/)(uv\.lock|poetry\.lock|Pipfile(\.lock)?|Cargo\.lock|go\.sum|package-lock\.json|npm-shrinkwrap\.json'
deps+='|pnpm-lock\.yaml|yarn\.lock|Gemfile(\.lock)?)$|(^|/)requirements[^/]*\.(txt|in)$|(^|/)constraints[^/]*\.txt$'
deps+='|(^|/)(pyproject\.toml|package\.json|go\.mod|Cargo\.toml|[^/]+\.gemspec)$'
deps+='|(^|/)(setup\.(py|cfg)|MANIFEST\.in|build\.rs|\.gitmodules)$|(^|/)([^/]*\.)?(Containerfile|Dockerfile)(\.[^/]*)?$'
deps+='|(^|/)dependabot\.ya?ml$|(^|/)(renovate\.json5?|\.renovaterc(\.json5?)?)$'
deps+='|(^|/)(vendor|third_party|node_modules)/|\.lock$|(^|/)(uv\.toml|poetry\.toml|pdm\.toml|pip\.conf|\.pypirc'
deps+='|\.npmrc|\.yarnrc(\.yml)?|bunfig\.toml|go\.work(\.sum)?)$|(^|/)\.yarn/|(^|/)\.cargo/config(\.toml)?$'
deps+='|(^|/)(gradlew|mvnw)$|(^|/)gradle/wrapper/|(^|/)\.mvn/'
deps+='|(^|/)(WORKSPACE(\.bazel)?|MODULE\.bazel|conanfile\.(py|txt))$|^action\.ya?ml$'
deps+='|(^|/)(Makefile|GNUmakefile|[^/]+\.mk|CMakeLists\.txt|[^/]+\.cmake|meson\.build|BUILD(\.bazel)?|[^/]+\.bzl'
deps+='|pom\.xml|(build|settings)\.gradle(\.kts)?|tox\.ini|noxfile\.py)$'

g ls-files --others --exclude-standard | { grep -Ev "$skip|$docs" || true; } > "$tmp/untracked"
{ g diff --name-only "$ref" --; cat "$tmp/untracked"; } | sort -u | { grep -Ev "$skip|$docs" || true; } > "$tmp/files"
# Every path the audit touches, unfiltered: deletions, and both sides of a rename.
{ g diff --name-only --no-renames "$ref" --; g ls-files --others --exclude-standard; } | sort -u > "$tmp/all"
# Submodules (gitlinks, mode 160000 on either side): a bump changes no file but moves a dependency.
g diff --raw --no-renames "$ref" -- | awk -F'\t' '{ split($1, m, " ") } m[1] == ":160000" || m[2] == "160000" { print $2 }' \
  > "$tmp/gitlinks"

# One "<sign><TAB><file><TAB><text>" record per changed line; untracked files count as fully added.
# --text keeps a .gitattributes -diff or binary mark (or a NUL byte) from hiding a file's lines; the explicit prefixes
# win over diff.srcPrefix and diff.dstPrefix. git ends a ---/+++ name that has a space with a tab.
g diff -U0 --text --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ "$ref" -- | awk '
  /^diff --git / { hdr = 1; old = ""; file = ""; next }
  hdr && /^--- / { old = substr($0, 5); sub(/\t$/, "", old); sub(/^a\//, "", old); next }
  hdr && /^\+\+\+ / {
    file = substr($0, 5); sub(/\t$/, "", file)
    if (file == "/dev/null") file = old; else sub(/^b\//, "", file)
    next
  }
  /^@@/ { hdr = 0; next }
  !hdr && /^[+-]/ { print substr($0, 1, 1) "\t" file "\t" substr($0, 2) }
' > "$tmp/lines"
while IFS= read -r f; do
  [[ -f $f ]] && awk -v f="$f" '{ print "+\t" f "\t" $0 }' < "$f" >> "$tmp/lines"
done < "$tmp/untracked"

# Changed lines in code files, as "<file>: <text>", the text being everything after the second tab (it can hold tabs
# itself). Patterns go through ENVIRON: awk -v would eat the backslashes.
# "$tmp/code_native" is the same minus JS and TS tests (enzyme and @vue/test-utils have a free mount()); a CI or
# dependency path is never a test.
skip=$skip docs=$docs js=$js tests=$tests deps=$deps out=$tmp/code_native awk -F'\t' '$2 !~ ENVIRON["skip"] && $2 !~ ENVIRON["docs"] {
  line = $2 ": " substr($0, length($1) + length($2) + 3)
  print line
  if ($2 !~ ENVIRON["js"] || $2 !~ ENVIRON["tests"] || $2 ~ ENVIRON["deps"]) print line > ENVIRON["out"]
}' "$tmp/lines" > "$tmp/code"
touch "$tmp/code_native"

declare -A why=()
note() { why[$1]+="  $2"$'\n'; }
first() { grep -a "$@" | head -3 || true; }

# rust: Rust sources or manifests.
while IFS= read -r m; do note rust "file $m"; done < <(first -E '\.rs$|(^|/)Cargo\.toml$' "$tmp/files")

# kubernetes: chart and manifest paths, YAML that declares a resource, or code that uses a Kubernetes client.
k8s_path='(^|/)(Chart\.yaml|kustomization\.ya?ml)$|(^|/)templates/[^/]+\.ya?ml$|kubernetes|k8s|(^|/)(helm|charts?|kube)/'
k8s_code='k8s_openapi|kube::|kube_runtime|kube_client|k8s\.io/(client-go|api|apimachinery)|sigs\.k8s\.io/controller-runtime|from kubernetes import|import kubernetes'
while IFS= read -r m; do note kubernetes "path $m"; done < <(first -iE "$k8s_path" "$tmp/files")
n=0
while IFS= read -r f; do
  [[ -f $f && ! $f =~ $docs && $n -lt 3 ]] || continue
  if [[ $f =~ \.ya?ml$ ]] && grep -aqE -e '^apiVersion:' < "$f" && grep -aqE -e '^kind:' < "$f"; then
    note kubernetes "manifest $f"; n=$((n + 1))
  elif grep -aqE -e "$k8s_code" < "$f"; then
    note kubernetes "client code in $f"; n=$((n + 1))
  fi
done < "$tmp/files"

# kernel: Linux-specific paths, kernel interfaces on changed lines (a libc.mount() call, or a free mount() call outside
# JS and TS tests, never another .mount() method), or isolation primitives in a changed file (sys_mount's builder ends
# in a .mount() call).
kernel_path='(^|/)linux/|seccomp|landlock|cgroup|netns|vfio'
kernel_line='(^|[^A-Za-z0-9_])(libc|nix)::|\bsyscall\(|\bSYS_[a-z]|\bioctl\b|setsockopt|SO_(ATTACH_FILTER|PEERCRED|PEERPIDFD|BINDTODEVICE)|\bbpf\b|BPF_[A-Z]|[Ss]eccomp|SECCOMP_|[Ll]andlock|LANDLOCK_|\bunshare\b|\bsetns\b|clone3|CLONE_NEW|pivot_root|\bprctl\b|PR_SET_|PR_CAP|[Pp]idfd|/proc/|[Cc]group|[Nn]etlink|nftables|[Vv]fio|VFIO_|[Ii]ommu|\bCAP_[A-Z_]+|\bcapset\b|caps::|\bptrace\b|PTRACE_|[Ll]ibc\.mount\(|\bMS_[A-Z]+|mount_setattr|fsopen|move_mount|open_tree|close_range|O_CLOEXEC'
kernel_mount='(^|[^.A-Za-z0-9_])mount\('
kernel_file='seccompiler|landlock::|sys_mount::|SECCOMP_|LANDLOCK_|CLONE_NEW|pivot_root|PR_SET_NO_NEW_PRIVS'
while IFS= read -r m; do note kernel "path $m"; done < <(first -iE "$kernel_path" "$tmp/files")
while IFS= read -r m; do note kernel "line $m"; done < <({ grep -aE "$kernel_line" "$tmp/code" || true; grep -aE "$kernel_mount" "$tmp/code_native" || true; } | awk '!seen[$0]++' | head -3)
n=0
while IFS= read -r f; do
  [[ -f $f && ! $f =~ $docs && $n -lt 3 ]] || continue
  if grep -aqE -e "$kernel_file" < "$f"; then note kernel "primitives in $f"; n=$((n + 1)); fi
done < "$tmp/files"

# supply-chain: CI, dependency manifests, lockfiles, requirements and constraints, vendored code, index and registry
# config, build and packaging files and wrappers, submodules, dependency bots, or release tooling, from every path
# (lockfiles and .txt included), or changed code lines that fetch, unpack, hash, install, or publish.
deps_line='\[build-system\]|build-backend|urlretrieve|urlopen|\bcurl\b|\bwget\b|\btarfile\b|\bzipfile\b|extractall'
deps_line+='|unpack_archive|\bhashlib\b|sha256sum|--require-hashes|\bpip3? install\b|\bnpm (install|ci)\b'
deps_line+='|\bgit (clone|fetch)\b|\btwine\b|\b(uv|cargo|npm|gem) publish\b|\bgh release\b|\bcosign\b'
# Dependency and build paths, submodules included.
{ grep -aE "$deps" "$tmp/all" || true; cat "$tmp/gitlinks"; } | sort -u > "$tmp/deps"
while IFS= read -r m; do note supply-chain "path $m"; done < <(head -3 "$tmp/deps")
while IFS= read -r m; do note supply-chain "line $m"; done < <(first -E "$deps_line" "$tmp/code")

domains=()
for d in rust kubernetes kernel supply-chain; do [[ -n ${why[$d]:-} ]] && domains+=("$d"); done
echo "domains: ${domains[*]:-none}"
for d in "${domains[@]}"; do
  echo "$d:"
  printf '%s' "${why[$d]}"
done

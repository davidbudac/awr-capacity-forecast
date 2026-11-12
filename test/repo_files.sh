# test/repo_files.sh -- sourced by test/lint_*.sh and test/docs_lint.sh (cwd =
# the repo root): the files a lint judges. That is the repository, so in a
# git checkout only tracked files count. A spooled report under reports/, a
# generated install driver or an ad-hoc probe script is not the suite.
# A copy without git (an rsynced tree, an unpacked archive) falls back to
# every file outside the directories .gitignore names.

# The checkout tracks this tree (not merely: some parent directory is a repo).
_repo_git() { git ls-files --error-unmatch install.sql >/dev/null 2>&1; }

# repo_files PATTERN...  files at any depth whose path matches a pattern
# ('*.sql' '*.py'; "*" also matches "/").
repo_files() {
  local f p
  if _repo_git; then
    git -c core.quotepath=off ls-files -- "$@"
  else
    find . \( -name .git -o -name .claude -o -name .agents -o -name reports \
              -o -name __pycache__ -o -name '.install_driver_*.sql' \) -prune \
           -o -type f -print | sed 's|^\./||' | LC_ALL=C sort \
      | while IFS= read -r f; do
          for p in "$@"; do
            case "$f" in $p) printf '%s\n' "$f"; break;; esac
          done
        done
  fi | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done
}

# repo_only PATH...  of the given paths (a caller's shell glob), those that
# belong to the repository.
repo_only() {
  local f
  [ $# -gt 0 ] || return 0
  if _repo_git; then
    git -c core.quotepath=off ls-files -- "$@"
  else
    printf '%s\n' "$@"
  fi | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done
}

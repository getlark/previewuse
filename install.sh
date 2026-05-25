#!/usr/bin/env bash
#
# previewuse installer
#
# Drops the previewuse scripts, compose file, example configs, and the
# configure-preview-deploy Claude Code skill into an existing repo.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/getlark/previewuse/main/install.sh)
#   bash install.sh [--dry-run] [--yes] [--ref REF] [--repo OWNER/REPO] [--from DIR] [TARGET_DIR]
#
# Flags:
#   --dry-run        Print actions without writing anything.
#   --yes, -y        Overwrite existing files without prompting.
#   --ref REF        Git ref (branch/tag/sha) to download from. Default: main.
#   --repo O/R       GitHub repo to download from. Default: getlark/previewuse.
#   --from DIR       Copy from a local previewuse checkout instead of GitHub.
#   TARGET_DIR       Directory to install into. Default: current directory.

set -euo pipefail

DRY_RUN=0
ASSUME_YES=0
REF="main"
REPO="getlark/previewuse"
FROM=""
TARGET="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -y|--yes)  ASSUME_YES=1; shift ;;
    --ref)     REF="$2"; shift 2 ;;
    --repo)    REPO="$2"; shift 2 ;;
    --from)    FROM="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
    *)
      TARGET="$1"; shift
      ;;
  esac
done

# If invoked as a file (not piped via curl) and --from wasn't passed,
# default to copying from the script's own directory.
if [[ -z "$FROM" && -n "${BASH_SOURCE[0]:-}" ]]; then
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || true)"
  if [[ -n "$self_dir" && -f "$self_dir/scripts/deploy.sh" ]]; then
    FROM="$self_dir"
  fi
fi

# Files to install, relative to repo root.
FILES=(
  "scripts/deploy.sh"
  "scripts/teardown.sh"
  "scripts/user-data.sh"
  "docker-compose.preview.yml"
  "Caddyfile.example"
  "preview.config.example.sh"
  "circleci.example.yml"
  "github-actions.example.yml"
  ".claude/skills/configure-preview-deploy/SKILL.md"
)

EXECUTABLE=(
  "scripts/deploy.sh"
  "scripts/teardown.sh"
  "scripts/user-data.sh"
)

if [[ ! -d "$TARGET" ]]; then
  echo "target directory does not exist: $TARGET" >&2
  exit 1
fi
TARGET="$(cd "$TARGET" && pwd)"

if [[ -n "$FROM" ]]; then
  FROM="$(cd "$FROM" && pwd)"
  echo "Source: $FROM (local)"
else
  echo "Source: https://github.com/$REPO @ $REF"
fi
echo "Target: $TARGET"
[[ $DRY_RUN -eq 1 ]] && echo "(dry run — no files will be written)"
echo

confirm_overwrite() {
  local path="$1"
  [[ ! -e "$path" ]] && return 0
  [[ $ASSUME_YES -eq 1 ]] && return 0
  read -r -p "  overwrite $path? [y/N] " ans </dev/tty || ans="n"
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

fetch_file() {
  local rel="$1" dest="$2"
  if [[ -n "$FROM" ]]; then
    local src="$FROM/$rel"
    if [[ ! -f "$src" ]]; then
      echo "  missing in source: $rel" >&2
      return 1
    fi
    cp "$src" "$dest"
  else
    local url="https://raw.githubusercontent.com/$REPO/$REF/$rel"
    if ! curl -fsSL "$url" -o "$dest"; then
      echo "  download failed: $url" >&2
      return 1
    fi
  fi
}

installed=0
skipped=0
for rel in "${FILES[@]}"; do
  dest="$TARGET/$rel"
  action="install"
  if [[ -e "$dest" ]]; then
    if confirm_overwrite "$dest"; then
      action="overwrite"
    else
      echo "  skip   $rel"
      skipped=$((skipped + 1))
      continue
    fi
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  $action $rel"
    installed=$((installed + 1))
    continue
  fi

  mkdir -p "$(dirname "$dest")"
  if ! fetch_file "$rel" "$dest"; then
    skipped=$((skipped + 1))
    continue
  fi
  for exe in "${EXECUTABLE[@]}"; do
    [[ "$rel" == "$exe" ]] && chmod +x "$dest"
  done
  echo "  $action $rel"
  installed=$((installed + 1))
done

echo
echo "Done. installed=$installed skipped=$skipped"
echo
echo "Next:"
echo "  1. mv preview.config.example.sh preview.config.sh (or run /configure-preview-deploy)"
echo "  2. mv Caddyfile.example Caddyfile"
echo "  3. Edit preview.config.sh, docker-compose.preview.yml, and Caddyfile for your app."
echo "  4. Wire CI — see circleci.example.yml or github-actions.example.yml."

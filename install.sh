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
#   --ref REF        Git ref (branch/tag/sha) to download from. Default: latest release.
#   --repo O/R       GitHub repo to download from. Default: getlark/previewuse.
#   --from DIR       Copy from a local previewuse checkout instead of GitHub.
#   TARGET_DIR       Directory to install into. Default: current directory.

set -euo pipefail

DRY_RUN=0
ASSUME_YES=0
REF=""
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
  ".claude/skills/provision-preview-aws/SKILL.md"
)

EXECUTABLE=(
  "scripts/deploy.sh"
  "scripts/teardown.sh"
  "scripts/user-data.sh"
)

# Symlinks to create at the target, as "link_path::target". Target is
# resolved relative to the link's parent directory (same semantics as ln -s).
SYMLINKS=(
  ".agents/skills::../.claude/skills"
)

if [[ ! -d "$TARGET" ]]; then
  echo "target directory does not exist: $TARGET" >&2
  exit 1
fi
TARGET="$(cd "$TARGET" && pwd)"

resolve_latest_release() {
  local api="https://api.github.com/repos/$REPO/releases/latest"
  local tag
  tag="$(curl -fsSL "$api" 2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
  if [[ -z "$tag" ]]; then
    echo "could not resolve latest release for $REPO (set --ref to override)" >&2
    return 1
  fi
  echo "$tag"
}

if [[ -n "$FROM" ]]; then
  FROM="$(cd "$FROM" && pwd)"
  echo "Source: $FROM (local)"
else
  if [[ -z "$REF" ]]; then
    REF="$(resolve_latest_release)"
  fi
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

for entry in "${SYMLINKS[@]}"; do
  link_rel="${entry%%::*}"
  link_target="${entry##*::}"
  link_path="$TARGET/$link_rel"
  action="symlink"
  if [[ -L "$link_path" || -e "$link_path" ]]; then
    existing=""
    [[ -L "$link_path" ]] && existing="$(readlink "$link_path")"
    if [[ "$existing" == "$link_target" ]]; then
      echo "  skip   $link_rel (symlink already correct)"
      skipped=$((skipped + 1))
      continue
    fi
    if confirm_overwrite "$link_path"; then
      action="resymlink"
    else
      echo "  skip   $link_rel"
      skipped=$((skipped + 1))
      continue
    fi
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  $action $link_rel -> $link_target"
    installed=$((installed + 1))
    continue
  fi

  mkdir -p "$(dirname "$link_path")"
  rm -f "$link_path"
  ln -s "$link_target" "$link_path"
  echo "  $action $link_rel -> $link_target"
  installed=$((installed + 1))
done

echo
echo "Done. installed=$installed skipped=$skipped"
echo
echo "Next:"
echo "  Open your coding agent (Claude Code, Cursor, etc.) in this repo and run:"
echo "      /configure-preview-deploy   # fills in config + CI workflow"
echo "      /provision-preview-aws      # creates the AWS resources + CI secrets"
echo "  Run them in that order. The configure skill walks through preview.config.sh,"
echo "  Caddyfile, docker-compose.preview.yml, and CI; the provision skill creates"
echo "  the S3 bucket, IAM roles, OIDC provider, and pushes secrets via gh."
echo
echo "  Prefer to edit by hand? See README.md — start by renaming the .example files."

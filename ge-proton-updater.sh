#!/usr/bin/env bash
# Install the latest GE-Proton into every Steam client on this machine.
# Native packages, Flatpak, and Snap are detected. Symlinks to the same
# Steam directory are installed once. compatibilitytools.d is created if
# it is missing.
#
#   update-ge-proton            # shell function in README.md
#   ge-proton-updater.sh --show-steam
set -euo pipefail

REPO_API="https://api.github.com/repos/GloriousEggroll/proton-ge-custom"

usage() {
  cat <<'EOF'
Usage: ge-proton-updater.sh [--show-steam]

Download the latest GE-Proton and install it into each Steam on this computer.
--show-steam   print the Steam directories, then exit
EOF
}

# ponytail: splits JSON strings with shell patterns, not a parser. Breaks if a
# value contains an escaped quote. Upgrade path: jq.
extract_json_strings() {
  local json=$1 key=$2 needle rest
  needle="\"$key\":"
  rest=$json
  while [[ $rest == *"$needle"* ]]; do
    rest=${rest#*"$needle"}
    rest=${rest#" "}
    rest=${rest#$'\n'}
    rest=${rest#" "}
    if [[ $rest != \"* ]]; then
      rest=${rest#?}
      continue
    fi
    rest=${rest#\"}
    printf '%s\n' "${rest%%\"*}"
  done
}

filter_arch_urls() {
  local arch=$1 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case $arch in
      aarch64 | arm64)
        case $line in
          *-aarch64.*) printf '%s\n' "$line" ;;
        esac
        ;;
      *)
        case $line in
          *-aarch64.*) ;;
          *) printf '%s\n' "$line" ;;
        esac
        ;;
    esac
  done
}

first_match() {
  local pattern=$1 line
  while IFS= read -r line; do
    case $line in
      $pattern) printf '%s\n' "$line"; return 0 ;;
    esac
  done
  return 1
}

steam_candidates() {
  local home=$HOME
  local data=${XDG_DATA_HOME:-$home/.local/share}
  printf '%s\n' \
    "$data/Steam" \
    "$home/.steam/root" \
    "$home/.steam/steam" \
    "$home/.steam/debian-installation" \
    "$home/.var/app/com.valvesoftware.Steam/.local/share/Steam" \
    "$home/.var/app/com.valvesoftware.Steam/data/Steam" \
    "$home/.var/app/com.valvesoftware.Steam/.steam/root" \
    "$home/.var/app/com.valvesoftware.Steam/.steam/steam" \
    "$home/snap/steam/common/.steam/root" \
    "$home/snap/steam/common/.steam/steam" \
    "$home/snap/steam/common/.local/share/Steam"
}

steam_dir_ready() {
  local d=$1
  [ -f "$d/config/config.vdf" ] || [ -d "$d/steamapps" ] || [ -f "$d/steam.sh" ] || [ -d "$d/ubuntu12_32" ]
}

# Physical Steam data directories that already exist, one per line.
find_existing_steam_dirs() {
  local d real seen=$'\n'
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    steam_dir_ready "$d" || continue
    real=$(readlink -f "$d")
    case $seen in
      *$'\n'"$real"$'\n'*) continue ;;
    esac
    seen="$seen$real"$'\n'
    printf '%s\n' "$real"
  done < <(steam_candidates)
}

has_flatpak_steam() {
  command -v flatpak >/dev/null 2>&1 && flatpak info com.valvesoftware.Steam >/dev/null 2>&1
}

has_snap_steam() {
  command -v snap >/dev/null 2>&1 && snap list steam >/dev/null 2>&1
}

# Distro package or Valve's installer. Flatpak's exported stub is not native Steam.
has_native_steam() {
  local bin
  for bin in /usr/bin/steam /usr/games/steam; do
    if [ -x "$bin" ] && ! grep -q 'com.valvesoftware.Steam' "$bin" 2>/dev/null; then
      return 0
    fi
  done
  bin=$(command -v steam 2>/dev/null || true)
  [ -n "$bin" ] || return 1
  case $bin in
    /var/lib/flatpak/* | */.local/share/flatpak/*) return 1 ;;
  esac
  if [ -f "$bin" ] && grep -q 'com.valvesoftware.Steam' "$bin" 2>/dev/null; then
    return 1
  fi
  return 0
}

# Steam is installed but has never been started, so it has no data directory yet.
# ponytail: Debian/Ubuntu's /usr/games/steam package uses ~/.steam/debian-installation.
# Other packages use $XDG_DATA_HOME/Steam. After the first launch, the real
# directory is detected above and this guess is not used.
fallback_steam_dirs() {
  local found=0
  if has_flatpak_steam; then
    printf '%s\n' "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
    found=1
  fi
  if has_snap_steam; then
    printf '%s\n' "$HOME/snap/steam/common/.steam/root"
    found=1
  fi
  if has_native_steam; then
    if [ -x /usr/games/steam ]; then
      printf '%s\n' "$HOME/.steam/debian-installation"
    else
      printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/Steam"
    fi
    found=1
  fi
  if [ "$found" -eq 0 ]; then
    echo "Could not find Steam. Install it, start it once, then run this again." >&2
    return 1
  fi
}

collect_steam_dirs() {
  local found
  found=$(find_existing_steam_dirs)
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
    return 0
  fi
  fallback_steam_dirs
}

try_release() {
  local api_url=$1 release_name=$2 release_json urls tag
  echo "Trying $release_name..."
  if ! release_json=$(curl -fsSL "$api_url"); then
    echo "  Failed to fetch $release_name"
    return 1
  fi

  urls=$(extract_json_strings "$release_json" browser_download_url | filter_arch_urls "$(uname -m)")
  TARBALL_URL=$(first_match '*.tar.gz' <<< "$urls" || true)
  CHECKSUM_URL=$(first_match '*.sha512sum' <<< "$urls" || true)
  if [ -z "${TARBALL_URL:-}" ] || [ -z "${CHECKSUM_URL:-}" ]; then
    TARBALL_URL=
    CHECKSUM_URL=
    echo "  Missing tarball or checksum in $release_name"
    return 1
  fi

  tag=$(extract_json_strings "$release_json" tag_name)
  echo "  Found complete release: ${tag%%$'\n'*}"
}

select_release() {
  local recent_releases_json release_tags tag found_working_release
  echo "Checking for available releases..."
  if try_release "$REPO_API/releases/latest" "latest release"; then
    echo "Using latest release"
    return 0
  fi

  echo "Latest release has no assets, checking recent releases..."
  if ! recent_releases_json=$(curl -fsSL "$REPO_API/releases?per_page=10"); then
    echo "Could not fetch the list of recent releases." >&2
    return 1
  fi

  release_tags=$(extract_json_strings "$recent_releases_json" tag_name)
  if [ -z "$release_tags" ]; then
    echo "Could not read any recent releases." >&2
    return 1
  fi

  echo "Found recent releases:"
  echo "$release_tags"
  echo

  found_working_release=false
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    if try_release "$REPO_API/releases/tags/$tag" "$tag"; then
      echo "Using release: $tag"
      found_working_release=true
      break
    fi
  done <<< "$release_tags"

  if [ "$found_working_release" != true ]; then
    echo "Could not find a recent release with a tarball and checksum." >&2
    return 1
  fi
}

show_steam() {
  collect_steam_dirs
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

self_check() {
  local tmp home out n urls
  tmp=$(mktemp -d)
  home=$tmp/home
  mkdir -p "$home/.local/share/Steam/config" "$home/.steam" "$home/.steam/debian-installation"
  echo '{}' > "$home/.local/share/Steam/config/config.vdf"
  ln -s "$home/.local/share/Steam" "$home/.steam/root"
  ln -s "$home/.local/share/Steam" "$home/.steam/steam"

  out=$(HOME=$home XDG_DATA_HOME=$home/.local/share find_existing_steam_dirs)
  n=$(printf '%s\n' "$out" | grep -c .)
  [ "$n" -eq 1 ] || {
    echo "expected 1 steam dir after symlink dedupe, got $n: $out" >&2
    exit 1
  }
  case $out in
    *debian-installation*)
      echo "empty debian-installation was treated as Steam: $out" >&2
      exit 1
      ;;
  esac

  mkdir -p "$home/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps"
  ln -s .local/share "$home/.var/app/com.valvesoftware.Steam/data"

  out=$(HOME=$home XDG_DATA_HOME=$home/.local/share find_existing_steam_dirs)
  n=$(printf '%s\n' "$out" | grep -c .)
  [ "$n" -eq 2 ] || {
    echo "expected native plus flatpak, got $n: $out" >&2
    exit 1
  }

  urls=$(extract_json_strings '{"browser_download_url":"https://example.com/GE-Proton-aarch64.tar.gz","browser_download_url":"https://example.com/GE-Proton-x86_64.tar.gz","browser_download_url":"https://example.com/GE-Proton-x86_64.sha512sum"}' browser_download_url)
  urls=$(printf '%s\n' "$urls" | filter_arch_urls x86_64)
  [ "$(first_match '*.tar.gz' <<< "$urls")" = "https://example.com/GE-Proton-x86_64.tar.gz" ] || {
    echo "x86_64 asset selection failed: $urls" >&2
    exit 1
  }
  urls=$(extract_json_strings $'{\n  "browser_download_url": "https://example.com/GE-Proton-aarch64.tar.gz"\n}\n' browser_download_url | filter_arch_urls aarch64)
  [ "$urls" = "https://example.com/GE-Proton-aarch64.tar.gz" ] || {
    echo "pretty json selection failed: $urls" >&2
    exit 1
  }

  rm -rf "$tmp"
  echo "self-check ok"
}

main() {
  local steam_list d directory_name tarball_name checksum_name workdir
  local -a steam_dirs pending

  if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as your normal user, not root. Steam's folder is in your home directory." >&2
    exit 1
  fi

  require_cmd curl
  require_cmd tar
  require_cmd sha512sum
  require_cmd readlink

  if ! steam_list=$(collect_steam_dirs); then
    exit 1
  fi
  mapfile -t steam_dirs <<< "$steam_list"

  echo "Steam installations:"
  for d in "${steam_dirs[@]}"; do
    echo "  $d"
  done
  echo

  select_release

  tarball_name=$(basename "$TARBALL_URL")
  directory_name=${tarball_name%.tar.gz}
  checksum_name=$(basename "$CHECKSUM_URL")

  echo
  echo "Selected release:"
  echo "  Tarball: $tarball_name"
  echo "  Directory: $directory_name"

  pending=()
  for d in "${steam_dirs[@]}"; do
    if [ -d "$d/compatibilitytools.d/$directory_name" ]; then
      echo "Already installed: $d/compatibilitytools.d/$directory_name"
    else
      pending+=("$d")
    fi
  done
  if [ "${#pending[@]}" -eq 0 ]; then
    echo "This version is already installed."
    exit 0
  fi

  workdir=$(mktemp -d "${TMPDIR:-/tmp}/proton-ge.XXXXXX")
  trap 'rm -rf "$workdir"' EXIT
  cd "$workdir"

  echo
  echo "Downloading $tarball_name"
  echo "This is about 500MB and can take a few minutes."
  if ! curl -L --progress-bar --fail \
    --write-out "Downloaded %{size_download} bytes in %{time_total}s\n" \
    "$TARBALL_URL" -o "$tarball_name"; then
    echo "Failed to download the tarball." >&2
    exit 1
  fi

  echo "Downloading $checksum_name"
  if ! curl -fsSL "$CHECKSUM_URL" -o "$checksum_name"; then
    echo "Failed to download the checksum." >&2
    exit 1
  fi

  echo "Verifying SHA512 checksum..."
  sha512sum -c "$checksum_name"

  for d in "${pending[@]}"; do
    mkdir -p "$d/compatibilitytools.d"
    echo "Extracting into $d/compatibilitytools.d"
    tar -xf "$tarball_name" -C "$d/compatibilitytools.d"
    echo "Installed: $d/compatibilitytools.d/$directory_name"
  done

  echo
  echo "Restart Steam. The new GE-Proton version will be in a game's Properties, under Compatibility."
}

case ${1:-} in
  --self-check) self_check ;;
  --show-steam) show_steam ;;
  -h | --help) usage ;;
  "") main ;;
  *)
    usage >&2
    exit 1
    ;;
esac

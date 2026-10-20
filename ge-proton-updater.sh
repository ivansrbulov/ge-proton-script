#!/usr/bin/env bash
# Install the latest GE-Proton into the Steam you choose.
# The first run asks for the Steam folder and can add an update alias.
# Later runs only check for a new version. Prompts are read from the
# terminal, so `curl | bash` works from bash or zsh.
#
#   curl -fsSL https://raw.githubusercontent.com/ivansrbulov/ge-proton-script/main/ge-proton-updater.sh | bash
#   ge-proton-updater.sh --setup
#   ge-proton-updater.sh --show-steam
set -euo pipefail

REPO_API="https://api.github.com/repos/GloriousEggroll/proton-ge-custom"
RAW_URL="https://raw.githubusercontent.com/ivansrbulov/ge-proton-script/main/ge-proton-updater.sh"
DEFAULT_ALIAS="update-ge-proton"

choice_label=()
choice_value=()
SETUP_ALIAS=0
SETUP_ALIAS_NAME=
SETUP_ALIAS_RC=
workdir=

usage() {
  cat <<'EOF'
Usage: ge-proton-updater.sh [--setup] [--show-steam] [--yes]

The first run asks which Steam folder to use and can add an update alias.
Later runs download a new GE-Proton only when one is available.

--setup        choose the Steam folder and alias again
--show-steam   print detected Steam directories, then exit
--yes          use the detected Steam folder and skip the questions
EOF
}

cleanup() {
  if have_tty; then
    tput cnorm > /dev/tty 2>/dev/null || true
  fi
  if [ -n "${workdir:-}" ]; then
    rm -rf "$workdir"
  fi
}

have_tty() {
  # A permission check is not enough: /dev/tty exists even with no terminal,
  # and opening it then prints an error. The subshell swallows that error.
  (: < /dev/tty) > /dev/null 2>&1
}

say() {
  printf '%s\n' "$*" > /dev/tty
}

# Default answer is yes. Enter and y both accept.
confirm_yes() {
  local answer
  printf '%s [Y/n] ' "$1" > /dev/tty
  IFS= read -r answer < /dev/tty || return 1
  case ${answer,,} in
    '' | y | yes) return 0 ;;
    *) return 1 ;;
  esac
}

# Default answer is no.
confirm_no() {
  local answer
  printf '%s [y/N] ' "$1" > /dev/tty
  IFS= read -r answer < /dev/tty || return 1
  case ${answer,,} in
    y | yes) return 0 ;;
    *) return 1 ;;
  esac
}

prompt_line() {
  local prompt=$1 default=${2:-} answer
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default" > /dev/tty
  else
    printf '%s: ' "$prompt" > /dev/tty
  fi
  IFS= read -r answer < /dev/tty || return 1
  if [ -z "$answer" ]; then
    printf '%s\n' "$default"
  else
    printf '%s\n' "$answer"
  fi
}

expand_tilde() {
  local p=$1
  case $p in
    \~) printf '%s\n' "$HOME" ;;
    \~/*) printf '%s\n' "$HOME/${p:2}" ;;
    *) printf '%s\n' "$p" ;;
  esac
}

valid_alias_name() {
  case $1 in
    '' | [0-9]* | -* | *[!A-Za-z0-9_-]*) return 1 ;;
  esac
}

parent_shell_name() {
  local name=
  if [ -r "/proc/$PPID/comm" ]; then
    IFS= read -r name < "/proc/$PPID/comm" || true
  fi
  name=${name#-}
  case $name in
    bash | zsh) printf '%s\n' "$name"; return ;;
  esac
  name=$(basename "${SHELL:-}")
  case $name in
    bash | zsh) printf '%s\n' "$name"; return ;;
  esac
  printf '%s\n' bash
}

rc_file_for() {
  case $1 in
    zsh) printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" ;;
    *) printf '%s\n' "$HOME/.bashrc" ;;
  esac
}

config_file() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/ge-proton-updater/steam-dir"
}

read_config() {
  local line
  IFS= read -r line < "$(config_file)"
  printf '%s\n' "$line"
}

save_config() {
  local f
  f=$(config_file)
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$1" > "$f"
}

alias_line() {
  printf "alias %s='curl -fsSL %s | bash -s --'\n" "$1" "$RAW_URL"
}

write_alias() {
  local rc=$1 name=$2 tmp line
  if [ -L "$rc" ]; then
    rc=$(readlink -f "$rc")
  fi
  if [ -d "$rc" ]; then
    echo "Shell config path is a directory: $rc" >&2
    return 1
  fi
  line=$(alias_line "$name")
  mkdir -p "$(dirname "$rc")"
  tmp=$(mktemp)
  if [ -f "$rc" ]; then
    awk '
      /^# ge-proton-updater$/ { skip = 1; next }
      skip && /^alias / { skip = 0; next }
      { print }
    ' "$rc" > "$tmp"
  fi
  if [ -s "$tmp" ]; then
    printf '\n' >> "$tmp"
  fi
  printf '# ge-proton-updater\n%s\n' "$line" >> "$tmp"
  mv "$tmp" "$rc"
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

native_steam_path() {
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/Steam"
}

debian_steam_path() {
  printf '%s\n' "$HOME/.steam/debian-installation"
}

flatpak_steam_path() {
  printf '%s\n' "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
}

snap_steam_path() {
  printf '%s\n' "$HOME/snap/steam/common/.steam/root"
}

steam_kind() {
  case $1 in
    *com.valvesoftware.Steam*) printf '%s\n' Flatpak ;;
    */snap/steam/*) printf '%s\n' Snap ;;
    */.steam/debian-installation) printf '%s\n' "Debian or Ubuntu package" ;;
    *) printf '%s\n' Native ;;
  esac
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

same_path() {
  local a=$1 b=$2
  if [ -d "$a" ] && [ -d "$b" ]; then
    [ "$(readlink -f "$a")" = "$(readlink -f "$b")" ]
    return
  fi
  [ "$a" = "$b" ]
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

# One suggested directory, or nothing if Steam cannot be guessed.
guess_steam_dir() {
  local found
  found=$(find_existing_steam_dirs || true)
  if [ -n "$found" ]; then
    printf '%s\n' "${found%%$'\n'*}"
    return 0
  fi
  if has_flatpak_steam; then
    flatpak_steam_path
    return 0
  fi
  if has_snap_steam; then
    snap_steam_path
    return 0
  fi
  if has_native_steam; then
    if [ -x /usr/games/steam ]; then
      debian_steam_path
    else
      native_steam_path
    fi
    return 0
  fi
  return 1
}

collect_steam_dirs() {
  local found
  found=$(find_existing_steam_dirs)
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
    return 0
  fi
  if guess_steam_dir; then
    return 0
  fi
  echo "Could not find Steam. Install it, start it once, then run this again." >&2
  return 1
}

path_note() {
  if steam_dir_ready "$1"; then
    printf '%s\n' found
  elif [ -d "$1" ]; then
    printf '%s\n' "folder exists"
  else
    printf '%s\n' "will be created"
  fi
}

reset_choices() {
  choice_label=()
  choice_value=()
}

add_choice() {
  local label=$1 value=$2 i
  for i in "${!choice_value[@]}"; do
    if same_path "${choice_value[$i]}" "$value"; then
      return 0
    fi
  done
  choice_label+=("$label")
  choice_value+=("$value")
}

# Other install methods, excluding the directory the user just rejected.
fill_other_methods() {
  local skip=$1 d kind path
  reset_choices
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ -n "$skip" ] && same_path "$d" "$skip"; then
      continue
    fi
    add_choice "$(steam_kind "$d") — $d ($(path_note "$d"))" "$d"
  done < <(find_existing_steam_dirs || true)

  for kind in Native "Debian or Ubuntu package" Flatpak Snap; do
    case $kind in
      Native) path=$(native_steam_path) ;;
      "Debian or Ubuntu package") path=$(debian_steam_path) ;;
      Flatpak) path=$(flatpak_steam_path) ;;
      Snap) path=$(snap_steam_path) ;;
    esac
    if [ -n "$skip" ] && same_path "$path" "$skip"; then
      continue
    fi
    add_choice "$kind — $path ($(path_note "$path"))" "$path"
  done
  add_choice "Custom folder" "__custom__"
}

draw_choices() {
  local selected=$1 i marker line cols
  cols=$(tput cols 2>/dev/null || echo 80)
  if [ "$cols" -lt 20 ]; then
    cols=80
  fi
  for i in "${!choice_label[@]}"; do
    if [ "$i" -eq "$selected" ]; then
      marker='>'
    else
      marker=' '
    fi
    line=$(printf '  %s %s' "$marker" "${choice_label[$i]}")
    if [ "${#line}" -ge "$cols" ]; then
      line="${line:0:cols-2}…"
    fi
    printf '%s\n' "$line" > /dev/tty
  done
  printf '  Up/Down to move, Enter to select\n' > /dev/tty
}

pick_choice_arrows() {
  local selected=0 key rest n
  n=${#choice_label[@]}
  tput civis > /dev/tty 2>/dev/null || true
  draw_choices "$selected"
  while true; do
    key=
    IFS= read -rsn1 key < /dev/tty || true
    if [ "$key" = $'\x1b' ]; then
      rest=
      IFS= read -rsn2 -t 1 rest < /dev/tty || true
      key=$key$rest
    fi
    case $key in
      $'\x1b[A' | $'\x1bOA')
        if [ "$selected" -eq 0 ]; then
          selected=$((n - 1))
        else
          selected=$((selected - 1))
        fi
        ;;
      $'\x1b[B' | $'\x1bOB')
        selected=$((selected + 1))
        if [ "$selected" -ge "$n" ]; then
          selected=0
        fi
        ;;
      '' | $'\n' | $'\r')
        break
        ;;
      *)
        continue
        ;;
    esac
    tput cuu $((n + 1)) > /dev/tty
    tput ed > /dev/tty
    draw_choices "$selected"
  done
  tput cuu $((n + 1)) > /dev/tty
  tput ed > /dev/tty
  tput cnorm > /dev/tty 2>/dev/null || true
  printf '%s\n' "${choice_value[$selected]}"
}

pick_choice_numbers() {
  local i answer
  for i in "${!choice_label[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "${choice_label[$i]}" > /dev/tty
  done
  while true; do
    printf 'Choose a number: ' > /dev/tty
    IFS= read -r answer < /dev/tty || return 1
    case $answer in
      '' | *[!0-9]*) continue ;;
    esac
    if [ "$answer" -ge 1 ] && [ "$answer" -le "${#choice_label[@]}" ]; then
      printf '%s\n' "${choice_value[$((answer - 1))]}"
      return 0
    fi
  done
}

pick_choice() {
  if [ "${#choice_label[@]}" -eq 0 ]; then
    echo "No install locations to choose from." >&2
    return 1
  fi
  # stdout is often a pipe here (`choice=$(pick_choice)`), so test the terminal.
  if have_tty && command -v tput >/dev/null 2>&1; then
    pick_choice_arrows
  else
    pick_choice_numbers
  fi
}

read_custom_steam_dir() {
  local p
  while true; do
    p=$(prompt_line "Path to the Steam folder")
    p=$(expand_tilde "$p")
    if [ -z "$p" ]; then
      say "Enter a path."
      continue
    fi
    if [ "$(basename "$p")" = "compatibilitytools.d" ]; then
      p=$(dirname "$p")
    fi
    printf '%s\n' "$p"
    return 0
  done
}

choose_steam_dir() {
  local first="" choice
  say "1. Steam folder"
  if first=$(guess_steam_dir); then
    say "$(steam_kind "$first"): $first"
    if steam_dir_ready "$first"; then
      say "This folder looks like an existing Steam install."
    else
      say "This folder is not there yet. It will be created."
    fi
    if confirm_yes "Use this directory?"; then
      printf '%s\n' "$first"
      return 0
    fi
  else
    say "No Steam install was detected."
    first=
  fi
  say "Choose how Steam is installed:"
  fill_other_methods "$first"
  choice=$(pick_choice)
  if [ "$choice" = "__custom__" ]; then
    read_custom_steam_dir
    return 0
  fi
  say "Using $choice"
  printf '%s\n' "$choice"
}

choose_alias() {
  local shell rc name
  SETUP_ALIAS=0
  shell=$(parent_shell_name)
  say ""
  say "2. Update alias"
  say "Your current shell is $shell."
  say "The updater itself runs in bash, which is normal if you use zsh."
  if ! confirm_yes "Add an alias for later updates?"; then
    return 0
  fi
  if ! confirm_yes "Use $shell?"; then
    reset_choices
    add_choice "zsh — $(rc_file_for zsh)" zsh
    add_choice "bash — $(rc_file_for bash)" bash
    add_choice "Don't add an alias" __skip__
    say "Which shell should get the alias?"
    shell=$(pick_choice)
    if [ "$shell" = "__skip__" ]; then
      return 0
    fi
  fi
  while true; do
    name=$(prompt_line "Alias name" "$DEFAULT_ALIAS")
    if valid_alias_name "$name"; then
      break
    fi
    say "Use letters, numbers, hyphens, and underscores, and start with a letter."
  done
  rc=$(rc_file_for "$shell")
  if [ -e "$rc" ]; then
    say "Shell config: $rc"
  else
    say "Shell config: $rc"
    say "That file is not there yet. It will be created."
  fi
  if ! confirm_yes "Use this file?"; then
    rc=$(prompt_line "Path to your shell config")
    rc=$(expand_tilde "$rc")
    if [ -z "$rc" ]; then
      say "No file given. Skipping the alias."
      return 0
    fi
  fi
  SETUP_ALIAS=1
  SETUP_ALIAS_NAME=$name
  SETUP_ALIAS_RC=$rc
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

warn_disk() {
  local dir=$1 parent avail
  parent=$dir
  if [ ! -d "$parent" ]; then
    parent=$(dirname "$dir")
  fi
  if [ ! -d "$parent" ]; then
    parent=$HOME
  fi
  avail=$(df -Pk "$parent" 2>/dev/null | awk 'NR==2 {print $4}')
  [ -n "${avail:-}" ] || return 0
  if [ "$avail" -lt 2097152 ]; then
    echo "About $((avail / 1024)) MB is free. The download needs roughly 2 GB." >&2
    if have_tty; then
      confirm_yes "Continue anyway?" || exit 0
    else
      exit 1
    fi
  fi
}

offer_prune() {
  local dir=$1 keep=$2 d base
  local -a old=()
  [ -d "$dir/compatibilitytools.d" ] || return 0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    base=$(basename "$d")
    [ "$base" = "$keep" ] && continue
    case $base in
      GE-Proton*) old+=("$d") ;;
    esac
  done < <(find "$dir/compatibilitytools.d" -mindepth 1 -maxdepth 1 -type d | sort)
  [ "${#old[@]}" -gt 0 ] || return 0
  say "Older GE-Proton folders:"
  for d in "${old[@]}"; do
    say "  $(basename "$d")"
  done
  if confirm_no "Remove those older folders?"; then
    rm -rf "${old[@]}"
    say "Removed ${#old[@]} older folder(s)."
  fi
}

finish_setup() {
  local steam_dir=$1
  save_config "$steam_dir"
  if [ "$SETUP_ALIAS" -eq 1 ]; then
    write_alias "$SETUP_ALIAS_RC" "$SETUP_ALIAS_NAME"
    echo "Added alias $SETUP_ALIAS_NAME to $SETUP_ALIAS_RC"
    echo "Open a new terminal, then run: $SETUP_ALIAS_NAME"
  fi
}

install_release() {
  local steam_dir=$1 directory_name=$2 tarball_name checksum_name
  checksum_name=$(basename "$CHECKSUM_URL")
  tarball_name=$(basename "$TARBALL_URL")

  warn_disk "$steam_dir"
  mkdir -p "$steam_dir/compatibilitytools.d"

  workdir=$(mktemp -d "${TMPDIR:-/tmp}/proton-ge.XXXXXX")
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

  echo "Extracting into $steam_dir/compatibilitytools.d"
  tar -xf "$tarball_name" -C "$steam_dir/compatibilitytools.d"
  echo "Installed: $steam_dir/compatibilitytools.d/$directory_name"
  echo
  echo "Restart Steam. Then, in a game's Properties, open Compatibility and pick this version."
}

main() {
  local mode=${1:-} steam_dir="" interactive=0
  local directory_name tarball_name dest found

  trap cleanup EXIT

  if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as your normal user, not root. Steam's folder is in your home directory." >&2
    exit 1
  fi

  require_cmd curl
  require_cmd tar
  require_cmd sha512sum
  require_cmd readlink

  if [ "$mode" = "yes" ]; then
    if ! found=$(collect_steam_dirs); then
      exit 1
    fi
    steam_dir=${found%%$'\n'*}
  elif [ "$mode" = "setup" ] || [ ! -f "$(config_file)" ]; then
    if ! have_tty; then
      echo "Run this in a terminal so it can ask where Steam is installed." >&2
      exit 1
    fi
    interactive=1
    steam_dir=$(choose_steam_dir)
    choose_alias
  else
    steam_dir=$(read_config)
    echo "Using saved Steam directory: $steam_dir"
    echo "Run with --setup to change the folder or the alias."
    if [ ! -d "$steam_dir" ]; then
      echo "That folder does not exist. Run with --setup to pick a new one." >&2
      exit 1
    fi
  fi

  if [ -z "$steam_dir" ]; then
    echo "No Steam directory selected." >&2
    exit 1
  fi

  select_release
  tarball_name=$(basename "$TARBALL_URL")
  directory_name=${tarball_name%.tar.gz}
  dest="$steam_dir/compatibilitytools.d/$directory_name"

  echo
  echo "Selected release: $directory_name"
  echo "Steam folder: $steam_dir"

  if [ -d "$dest" ]; then
    echo "This version is already installed."
    if [ "$interactive" -eq 1 ] || [ "$mode" = "yes" ]; then
      finish_setup "$steam_dir"
    fi
    if [ "$interactive" -eq 1 ]; then
      offer_prune "$steam_dir" "$directory_name"
    fi
    exit 0
  fi

  if [ "$interactive" -eq 1 ]; then
    if ! confirm_yes "Download and install $directory_name (about 500MB) into this folder?"; then
      say "Cancelled. Nothing was changed."
      exit 0
    fi
  fi

  if [ "$interactive" -eq 1 ] || [ "$mode" = "yes" ]; then
    finish_setup "$steam_dir"
  fi
  install_release "$steam_dir" "$directory_name"
  if [ "$interactive" -eq 1 ]; then
    offer_prune "$steam_dir" "$directory_name"
  fi
}

self_check() {
  local tmp home out n urls rc
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

  HOME=$home XDG_DATA_HOME=$home/.local/share fill_other_methods "$home/.local/share/Steam"
  [ "${choice_value[-1]}" = "__custom__" ] || {
    echo "menu did not end with custom: ${choice_value[*]}" >&2
    exit 1
  }
  local v
  for v in "${choice_value[@]}"; do
    [ "$v" = "__custom__" ] && continue
    if same_path "$v" "$home/.local/share/Steam"; then
      echo "rejected steam dir was offered again: $v" >&2
      exit 1
    fi
  done

  [ "$(HOME=$home expand_tilde '~/Steam')" = "$home/Steam" ] || {
    echo "tilde expansion failed" >&2
    exit 1
  }
  valid_alias_name update-ge-proton
  valid_alias_name foo-bar
  if valid_alias_name 1bad || valid_alias_name 'foo bar'; then
    echo "alias name check accepted a bad name" >&2
    exit 1
  fi
  [ "$(HOME=$home ZDOTDIR= rc_file_for zsh)" = "$home/.zshrc" ] || {
    echo "zsh rc path failed" >&2
    exit 1
  }

  rc=$tmp/rc
  printf 'export KEEP=1\n' > "$rc"
  write_alias "$rc" update-ge-proton
  write_alias "$rc" my-proton
  [ "$(grep -c '# ge-proton-updater' "$rc")" -eq 1 ] || {
    echo "alias block was duplicated" >&2
    exit 1
  }
  grep -q "alias my-proton=" "$rc" || {
    echo "new alias missing" >&2
    exit 1
  }
  if grep -q "alias update-ge-proton=" "$rc"; then
    echo "old alias was left in place" >&2
    exit 1
  fi
  grep -q 'export KEEP=1' "$rc" || {
    echo "existing rc contents were dropped" >&2
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

case ${1:-} in
  --self-check) self_check ;;
  --show-steam) show_steam ;;
  --setup) main setup ;;
  --yes) main yes ;;
  -h | --help) usage ;;
  "") main ;;
  *)
    usage >&2
    exit 1
    ;;
esac

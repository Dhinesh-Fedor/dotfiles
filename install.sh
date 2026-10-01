#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/my-dotfiles"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}"
manifest="$state_dir/installed-files.tsv"
manifest_tmp="$state_dir/installed-files.tsv.tmp"
timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir="$state_dir/backups/$timestamp"
backup_created=0
install_packages=auto

usage() {
    cat <<'EOF'
Usage: ./install.sh [--install-packages|--no-packages] [--help]

Copies the selected config files into $HOME, backing up every replaced file.
On Arch Linux, official repository packages can be installed after a prompt.
AUR packages are never built or installed automatically.
EOF
}

while (($#)); do
    case "$1" in
        --install-packages) install_packages=yes ;;
        --no-packages) install_packages=no ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [[ ! -f "$repo_dir/packages/arch-repo.txt" ]]; then
    printf 'Could not find the package manifest beside install.sh.\n' >&2
    exit 1
fi

os_id=unknown
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-unknown}"
fi
printf 'Detected distribution: %s\n' "$os_id"

missing_repo=()
missing_aur=()
if [[ "$os_id" == arch ]]; then
    while IFS= read -r pkg || [[ -n "$pkg" ]]; do
        [[ -z "$pkg" || "$pkg" == \#* ]] && continue
        if [[ "$pkg" == quickshell ]] && pacman -Q quickshell-git >/dev/null 2>&1; then
            continue
        fi
        if ! pacman -Q "$pkg" >/dev/null 2>&1; then
            if pacman -Si "$pkg" >/dev/null 2>&1; then
                missing_repo+=("$pkg")
            else
                missing_aur+=("$pkg")
            fi
        fi
    done < "$repo_dir/packages/arch-repo.txt"

    if ((${#missing_repo[@]})); then
        printf '\nMissing Arch repository packages:\n  %s\n' "${missing_repo[*]}"
        do_install=0
        if [[ "$install_packages" == yes ]]; then
            do_install=1
        elif [[ "$install_packages" == auto && -t 0 ]]; then
            read -r -p 'Install these packages with sudo pacman now? [y/N] ' answer
            [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] && do_install=1
        fi
        if ((do_install)); then
            sudo pacman -S --needed "${missing_repo[@]}"
        else
            printf 'Skipped package installation. Re-run with --install-packages or install them manually.\n'
        fi
    else
        printf 'All listed Arch repository packages are installed.\n'
    fi

    for pkg in caelestia-cli caelestia-shell waypaper qtengine; do
        if ! pacman -Q "$pkg" >/dev/null 2>&1; then
            missing_aur+=("$pkg")
        fi
    done
    while IFS= read -r pkg || [[ -n "$pkg" ]]; do
        [[ -z "$pkg" || "$pkg" == \#* ]] && continue
        if ! pacman -Q "$pkg" >/dev/null 2>&1; then
            missing_aur+=("$pkg")
        fi
    done < "$repo_dir/packages/aur-manual.txt"
else
    printf 'Automatic package installation is only configured for Arch Linux.\n'
    printf 'Use packages/arch-repo.txt and packages/aur-manual.txt as dependency references.\n'
fi

if ((${#missing_aur[@]})); then
    printf '\nPackages needing manual review/install (usually AUR or optional):\n  %s\n' "${missing_aur[*]}"
fi

mkdir -p "$state_dir"
: > "$manifest_tmp"

rendered_copy() {
    local source="$1" destination="$2" content temp
    if ! grep -Eq '__HOME__|__CONFIG__' "$source"; then
        cp -a -- "$source" "$destination"
        return
    fi
    content="$(<"$source")"
    content="${content//__HOME__/$HOME}"
    content="${content//__CONFIG__/$config_dir}"
    temp="$(mktemp "$state_dir/render.XXXXXX")"
    printf '%s' "$content" > "$temp"
    chmod --reference="$source" "$temp"
    cp -a -- "$temp" "$destination"
    rm -f -- "$temp"
}

record_file() {
    local kind="$1" rel="$2" source="$3" destination="$4"
    local old_backup='' old_status='' backup_rel='' base dest_rel parent_rel component current

    if [[ -f "$manifest" ]]; then
        while IFS=$'\t' read -r old_kind old_rel old_status old_backup; do
            if [[ "$old_kind" == "$kind" && "$old_rel" == "$rel" ]]; then
                break
            fi
            old_status=''
            old_backup=''
        done < "$manifest"
    fi

    dest_rel="$rel"
    if [[ "$kind" == config || "$rel" == .config/* ]]; then
        base="$config_dir"
        [[ "$kind" == home ]] && dest_rel="${rel#.config/}"
    else
        base="$HOME"
    fi
    if [[ "$dest_rel" == */* ]]; then
        parent_rel="${dest_rel%/*}"
        current="$base"
        IFS='/' read -r -a path_components <<< "$parent_rel"
        for component in "${path_components[@]}"; do
            current="$current/$component"
            if [[ -L "$current" ]]; then
                printf 'Refusing to write through symlinked config directory: %s\n' "$current" >&2
                return 1
            fi
        done
    fi

    mkdir -p -- "$(dirname -- "$destination")"
    if [[ -e "$destination" || -L "$destination" ]]; then
        local same=0
        if [[ ! -L "$destination" && -f "$destination" ]]; then
            if ! grep -Eq '__HOME__|__CONFIG__' "$source" && cmp -s -- "$source" "$destination"; then
                same=1
            elif grep -Eq '__HOME__|__CONFIG__' "$source"; then
                local expected
                expected="$(<"$source")"
                expected="${expected//__HOME__/$HOME}"
                expected="${expected//__CONFIG__/$config_dir}"
                [[ "$(<"$destination")" == "$expected" ]] && same=1
            fi
        fi
        if ((same)); then
            printf '%s\t%s\t%s\t%s\n' "$kind" "$rel" "${old_status:-kept}" "$old_backup" >> "$manifest_tmp"
            return
        fi

        if ((backup_created == 0)); then
            mkdir -p -- "$backup_dir"
            backup_created=1
        fi
        backup_rel="$kind/$rel"
        mkdir -p -- "$(dirname -- "$backup_dir/$backup_rel")"
        mv -- "$destination" "$backup_dir/$backup_rel"
        old_status=backup
        old_backup="$backup_rel"
    elif [[ -z "$old_status" ]]; then
        old_status=new
        old_backup=''
    fi

    rendered_copy "$source" "$destination"
    printf '%s\t%s\t%s\t%s\n' "$kind" "$rel" "$old_status" "$old_backup" >> "$manifest_tmp"
}

while IFS= read -r -d '' source; do
    rel="${source#"$repo_dir/config/"}"
    record_file config "$rel" "$source" "$config_dir/$rel"
done < <(find "$repo_dir/config" -type f -print0)

if [[ -d "$repo_dir/home" ]]; then
    while IFS= read -r -d '' source; do
        rel="${source#"$repo_dir/home/"}"
        if [[ "$rel" == .config/* ]]; then
            record_file home "$rel" "$source" "$config_dir/${rel#.config/}"
        else
            record_file home "$rel" "$source" "$HOME/$rel"
        fi
    done < <(find "$repo_dir/home" -type f -print0)
fi

mv -f -- "$manifest_tmp" "$manifest"
chmod +x "$HOME/.local/bin/caelestia-screenshot" 2>/dev/null || true

if [[ -f "$config_dir/systemd/user/gtklock.service" || -f "$config_dir/systemd/user/waypaper-caelestia-theme.path" ]]; then
    if ! systemctl --user daemon-reload 2>/dev/null; then
        printf 'Could not reload the user systemd manager here; run systemctl --user daemon-reload in your desktop session.\n'
    fi
fi

if [[ -f "$config_dir/systemd/user/waypaper-caelestia-theme.path" ]]; then
    if [[ -x "$HOME/.local/bin/waypaper-caelestia-theme" ]]; then
        "$HOME/.local/bin/waypaper-caelestia-theme" || printf 'Could not generate the initial Waypaper Caelestia stylesheet.\n' >&2
    fi
    if ! systemctl --user enable --now waypaper-caelestia-theme.path 2>/dev/null; then
        printf 'Could not enable the Waypaper theme watcher here; run systemctl --user enable --now waypaper-caelestia-theme.path in your desktop session.\n'
    fi
fi

if [[ "$os_id" == arch && "$install_packages" != no ]] && command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files bluetooth.service --no-legend 2>/dev/null | grep -q bluetooth.service &&
        ! systemctl is-enabled --quiet bluetooth.service 2>/dev/null && [[ -t 0 ]]; then
        read -r -p 'Enable the Bluetooth system service for Caelestia Bluetooth controls? [y/N] ' answer
        if [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            sudo systemctl enable --now bluetooth.service
        else
            printf 'Bluetooth service left unchanged. Enable it later with: sudo systemctl enable --now bluetooth.service\n'
        fi
    fi
fi

printf '\nConfiguration files copied.\n'
if ((backup_created)); then
    printf 'Replaced files backed up under: %s\n' "$backup_dir"
fi

validation_failed=0
while IFS=$'\t' read -r kind rel _status _backup_rel; do
    [[ -z "$kind" || -z "$rel" ]] && continue
    if [[ "$kind" == config ]]; then
        installed_path="$config_dir/$rel"
    elif [[ "$rel" == .config/* ]]; then
        installed_path="$config_dir/${rel#.config/}"
    else
        installed_path="$HOME/$rel"
    fi
    if [[ ! -f "$installed_path" ]]; then
        printf 'Validation failed: missing installed file %s\n' "$installed_path" >&2
        validation_failed=1
    fi
done < "$manifest"

for shell_file in "$repo_dir/install.sh" "$repo_dir/uninstall.sh" "$repo_dir/home/.local/bin/caelestia-screenshot"; do
    if ! bash -n "$shell_file"; then
        printf 'Validation failed: shell syntax error in %s\n' "$shell_file" >&2
        validation_failed=1
    fi
done
if command -v fish >/dev/null 2>&1; then
    while IFS= read -r -d '' fish_file; do
        if ! fish -n "$fish_file"; then
            printf 'Validation failed: Fish syntax error in %s\n' "$fish_file" >&2
            validation_failed=1
        fi
    done < <(find "$repo_dir/home/.config/fish" "$repo_dir/config/hypr/scripts" -name '*.fish' -type f -print0)
fi
if command -v luac >/dev/null 2>&1; then
    while IFS= read -r -d '' lua_file; do
        if ! luac -p "$lua_file"; then
            printf 'Validation failed: Lua syntax error in %s\n' "$lua_file" >&2
            validation_failed=1
        fi
    done < <(find "$repo_dir/config/hypr" "$repo_dir/config/caelestia" -name '*.lua' -type f -print0)
fi
if command -v jq >/dev/null 2>&1; then
    if ! jq -e . "$repo_dir/config/caelestia/shell.json" "$repo_dir/config/qtengine/config.json" >/dev/null; then
        printf 'Validation failed: invalid JSON config.\n' >&2
        validation_failed=1
    fi
fi
if ((validation_failed)); then
    printf 'Some validation checks failed; review the messages above.\n' >&2
else
    printf 'Installed-file and available syntax checks passed.\n'
fi

if [[ "$os_id" != arch ]]; then
    printf 'Install and verify Caelestia and Arch-oriented package dependencies manually on this distribution.\n'
fi
printf 'The installer does not enable the GTKLock service or set a wallpaper.\n'


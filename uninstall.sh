#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/my-dotfiles"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}"
manifest="$state_dir/installed-files.tsv"

if [[ ! -f "$manifest" ]]; then
    printf 'No install manifest found at %s\n' "$manifest"
    exit 1
fi

printf 'This removes unchanged files installed by this repository and restores their saved predecessors.\n'
read -r -p 'Continue? [y/N] ' answer
if [[ ! "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    printf 'Cancelled.\n'
    exit 0
fi

backup_root="$state_dir/backups"
restored=0
removed=0
skipped=0

while IFS=$'\t' read -r kind rel status backup_rel; do
    [[ -z "$kind" || -z "$rel" ]] && continue
    if [[ "$kind" == config ]]; then
        source="$repo_dir/config/$rel"
        destination="$config_dir/$rel"
    elif [[ "$kind" == home ]]; then
        source="$repo_dir/home/$rel"
        if [[ "$rel" == .config/* ]]; then
            destination="$config_dir/${rel#.config/}"
        else
            destination="$HOME/$rel"
        fi
    else
        printf 'Unknown manifest entry; skipping: %s %s\n' "$kind" "$rel"
        ((skipped+=1))
        continue
    fi

    [[ -e "$destination" || -L "$destination" ]] || continue
    dest_rel="$rel"
    base="$HOME"
    if [[ "$kind" == config || "$rel" == .config/* ]]; then
        base="$config_dir"
        [[ "$kind" == home ]] && dest_rel="${rel#.config/}"
    fi
    if [[ "$dest_rel" == */* ]]; then
        parent_rel="${dest_rel%/*}"
        current="$base"
        IFS='/' read -r -a path_components <<< "$parent_rel"
        parent_is_symlink=0
        for component in "${path_components[@]}"; do
            current="$current/$component"
            if [[ -L "$current" ]]; then
                printf 'Leaving file under symlinked config directory: %s\n' "$destination"
                parent_is_symlink=1
                ((skipped+=1))
                break
            fi
        done
        ((parent_is_symlink)) && continue
    fi
    same=0
    if [[ -f "$source" && -f "$destination" && ! -L "$destination" ]]; then
        if ! grep -Eq '__HOME__|__CONFIG__' "$source"; then
            cmp -s -- "$source" "$destination" && same=1
        else
            expected="$(<"$source")"
            expected="${expected//__HOME__/$HOME}"
            expected="${expected//__CONFIG__/$config_dir}"
            [[ "$(<"$destination")" == "$expected" ]] && same=1
        fi
    fi
    if ((same == 0)); then
        printf 'Leaving locally changed file in place: %s\n' "$destination"
        ((skipped+=1))
        continue
    fi

    if [[ "$status" == backup && -n "$backup_rel" ]]; then
        backup_file=''
        for candidate in "$backup_root"/*/"$backup_rel"; do
            [[ -e "$candidate" || -L "$candidate" ]] && backup_file="$candidate"
        done
        if [[ -n "$backup_file" ]]; then
            mv -- "$backup_file" "$destination"
            ((restored+=1))
            continue
        fi
    fi

    if [[ "$status" == new ]]; then
        rm -f -- "$destination"
        ((removed+=1))
    else
        # The existing file was identical before install; preserve it.
        ((skipped+=1))
    fi
done < "$manifest"

if [[ -f "$config_dir/systemd/user/gtklock.service" ]]; then
    systemctl --user daemon-reload 2>/dev/null || true
fi

printf 'Uninstall complete: %d restored, %d removed, %d left in place.\n' "$restored" "$removed" "$skipped"
printf 'Backup copies remain under %s. Remove them manually after checking recovery.\n' "$backup_root"

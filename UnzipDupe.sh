#!/usr/bin/env bash

# ==============================================================================
# CONFIGURATION & INITIALIZATION
# ==============================================================================
set -euo pipefail

TARGET_DIR="/home/ares/mnt/NTFS-Drive2/sm2/"
MAX_JOBS=4

# Color standards for real-time parallel tracing
CLR_RESET="\e[0m"
CLR_INFO="\e[34m"
CLR_SUCCESS="\e[32m"
CLR_WARN="\e[33m"
CLR_ERR="\e[31m"

# Intercept termination signals cleanly to prevent background multi-thread leaks
trap 'echo -e "\n${CLR_ERR}[!] Terminal interrupt received. Killing active worker threads...${CLR_RESET}"; kill 0' INT TERM

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================
list_archive() {
    local file="$1"
    local ext="${file,,}"
    {
        case "$ext" in
            *.zip)
                unzip -Z -1 "$file" 2>/dev/null || true
                ;;
            *.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar.bz2|*.tbz2|*.tar)
                tar -tf "$file" 2>/dev/null || true
                ;;
            *)
                # High-speed streaming index extraction via technical 7z descriptor fields
                7z l -slt "$file" 2>/dev/null | awk '/^Path = / { count++; if (count > 1) print substr($0, 8) }'
                ;;
        esac
    } | tr -d '\r' | tr '\\' '/'
}

get_base_name() {
    # Perform a rapid case-insensitive trailing strip of complex and double extension suffixes
    echo "$1" | sed -E 's/\.(zip|7z|rar|tgz|txz|tbz2|tar\.gz|tar\.xz|tar\.bz2|tar)$//I'
}

process_archive() {
    local archive="$1"
    local filename
    filename=$(basename "$archive")
    
    # 1. High-speed content mapping and architectural metadata validation
    local file_list
    file_list=$(list_archive "$archive" | grep -v -E '^(__MACOSX|\.DS_Store|.*/__MACOSX|.*\.DS_Store)' | grep . || true)
    
    if [[ -z "$file_list" ]]; then
        echo -e "${CLR_WARN}[!] Skipping $filename: Archive appears corrupted or contains no valid files.${CLR_RESET}"
        return 0
    fi
    
    # 2. Extract unique high-level mapping nodes
    local top_levels
    top_levels=$(echo "$file_list" | sed 's|/.*||' | sort -u)
    local top_level_count
    top_level_count=$(echo "$top_levels" | wc -l)
    
    local is_single_root=false
    local root_name=""
    local target_path=""
    local extract_dir=""
    
    if [[ "$top_level_count" -eq 1 ]]; then
        root_name="$top_levels"
        if echo "$file_list" | grep -q '/'; then
            is_single_root=true
        fi
    fi
    
    if [[ "$is_single_root" == true ]]; then
        target_path="$TARGET_DIR/$root_name"
        extract_dir="$TARGET_DIR"
    else
        local base_name
        base_name=$(get_base_name "$filename")
        target_path="$TARGET_DIR/$base_name"
        extract_dir="$target_path"
    fi
    
    # 3. Structural collision verification (Deduplication Check)
    if [[ -e "$target_path" ]]; then
        echo -e "${CLR_WARN}[=] Skipping $filename: Destination target folder already exists.${CLR_RESET}"
        return 0
    fi
    
    # 4. Initialize extraction namespace if running a flat array distribution
    if [[ "$is_single_root" == false ]]; then
        mkdir -p "$extract_dir"
    fi
    
    # 5. Targeted Expansion Execution Selection
    local success=false
    local ext="${filename,,}"
    
    case "$ext" in
        *.zip)
            unzip -q "$archive" -d "$extract_dir" && success=true
            ;;
        *.tar.gz|*.tgz)
            tar -xzf "$archive" -C "$extract_dir" && success=true
            ;;
        *.tar.xz|*.txz)
            tar -xJf "$archive" -C "$extract_dir" && success=true
            ;;
        *.tar.bz2|*.tbz2)
            tar -xjf "$archive" -C "$extract_dir" && success=true
            ;;
        *.tar)
            tar -xf "$archive" -C "$extract_dir" && success=true
            ;;
        *.7z)
            7z x -y -o"$extract_dir" "$archive" >/dev/null && success=true
            ;;
        *.rar)
            if command -v unrar >&2; then
                unrar x -y "$archive" "$extract_dir/" >/dev/null && success=true
            else
                7z x -y -o"$extract_dir" "$archive" >/dev/null && success=true
            fi
            ;;
        *)
            7z x -y -o"$extract_dir" "$archive" >/dev/null && success=true
            ;;
    esac
    
    # 6. Post-Extraction Validation & Purging
    if [[ "$success" == true ]]; then
        echo -e "${CLR_SUCCESS}[✓] Extracted: $filename -> Permanent deletion initialized.${CLR_RESET}"
        rm -f "$archive"
    else
        echo -e "${CLR_ERR}[X] Failure: Extraction error occurred on $filename. Activating automated rollback...${CLR_RESET}"
        if [[ "$is_single_root" == false ]]; then
            rm -rf "$extract_dir"
        else
            if [[ -d "$target_path" ]]; then rm -rf "$target_path"; fi
        fi
    fi
}

# ==============================================================================
# MAIN ENGINE
# ==============================================================================
main() {
    if [[ ! -d "$TARGET_DIR" ]]; then
        echo -e "${CLR_ERR}Error: Target directory '$TARGET_DIR' does not exist.${CLR_RESET}" >&2
        exit 1
    fi

    cd "$TARGET_DIR"

    # Gather archives efficiently using null-terminated strings
    local archives=()
    while IFS= read -r -d '' file; do
        archives+=("$file")
    done < <(find . -maxdepth 1 -type f \( \
        -iname "*.zip" -o \
        -iname "*.7z" -o \
        -iname "*.rar" -o \
        -iname "*.tar.gz" -o \
        -iname "*.tgz" -o \
        -iname "*.tar.xz" -o \
        -iname "*.txz" -o \
        -iname "*.tar.bz2" -o \
        -iname "*.tbz2" -o \
        -iname "*.tar" \
    \) -print0)

    if [[ ${#archives[@]} -eq 0 ]]; then
        echo -e "${CLR_INFO}No eligible compressed archive structures detected.${CLR_RESET}"
        exit 0
    fi

    echo -e "${CLR_INFO}[*] Target Directory Matrix: $TARGET_DIR${CLR_RESET}"
    echo -e "${CLR_INFO}[*] Multi-threaded system ready. Found ${#archives[@]} targets.${CLR_RESET}\n"

    # Process and allocate execution jobs inside the parallel boundary ring
    for arc in "${archives[@]}"; do
        process_archive "$arc" &
        
        # Enforce threshold barrier limits using standard job table tracking
        while [[ $(jobs -r | wc -l) -ge $MAX_JOBS ]]; do
            sleep 0.05
            wait -n 2>/dev/null || true
        done
    done

    # Finalize remaining operations
    wait
    echo -e "\n${CLR_SUCCESS}[✓] System operations completed successfully.${CLR_RESET}"
}

main

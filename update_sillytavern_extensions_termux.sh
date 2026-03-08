#!/usr/bin/env bash
#
# update_sillytavern_extensions_termux.sh
#
# 用法：
#   chmod +x ./update_sillytavern_extensions_termux.sh
#   ./update_sillytavern_extensions_termux.sh
#
# 也可直接执行更新：
#   ./update_sillytavern_extensions_termux.sh <SillyTavern根目录> <用户目录名>
#   ./update_sillytavern_extensions_termux.sh --run-update [SillyTavern根目录] [用户目录名]
#   ./update_sillytavern_extensions_termux.sh --auto-start-check [SillyTavern根目录] [用户目录名]
#
# 环境变量同样可用：
#   ST_ROOT=/path/to/SillyTavern ST_USER_NAME=default-user bash ./update_sillytavern_extensions_termux.sh

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR=$(pwd 2>/dev/null)
fi
SCRIPT_NAME=$(basename "$0")
SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_NAME"

DEFAULT_ST_ROOT="$HOME/SillyTavern"
FALLBACK_USER_NAME="default-user"
CONFIG_FILE="$SCRIPT_DIR/.sillytavern_extension_manager.conf"
WHITELIST_FILE="$SCRIPT_DIR/.sillytavern_extension_whitelist"
AUTO_START_BEGIN="# >>> sillytavern-extension-manager auto-start >>>"
AUTO_START_END="# <<< sillytavern-extension-manager auto-start <<<"

CONFIG_DEFAULT_USER_NAME="$FALLBACK_USER_NAME"
AUTO_CHECK_ON_START=0
ACTIVE_ST_ROOT=""
ACTIVE_USER_NAME=""

checked_count=0
updated_count=0
no_update_count=0
skipped_count=0
failed_count=0
SKIPPED_DETAILS=()
FAILED_DETAILS=()

PLUGIN_NAMES=()
PLUGIN_PATHS=()
PLUGIN_SOURCES=()
WHITELIST_ITEMS=()
PARSED_ITEMS=()

COLOR_RED=""
COLOR_RESET=""

shopt -s nullglob

trim_spaces() {
    local value="$1"

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    printf '%s\n' "$value"
}

press_enter_to_continue() {
    printf '\n按回车继续...'
    IFS= read -r _unused_input
}

init_color_output() {
    if [ -t 1 ] && [ -n "$TERM" ] && [ "$TERM" != "dumb" ] && [ -z "$NO_COLOR" ]; then
        COLOR_RED=$'\033[31m'
        COLOR_RESET=$'\033[0m'
    else
        COLOR_RED=""
        COLOR_RESET=""
    fi
}

format_red_text() {
    local text="$1"

    if [ -n "$COLOR_RED" ] && [ -n "$COLOR_RESET" ]; then
        printf '%s%s%s' "$COLOR_RED" "$text" "$COLOR_RESET"
    else
        printf '%s' "$text"
    fi
}

expand_home_path() {
    local input_path="$1"

    case "$input_path" in
        "~")
            printf '%s\n' "$HOME"
            ;;
        "~/"*)
            printf '%s/%s\n' "$HOME" "${input_path#~/}"
            ;;
        *)
            printf '%s\n' "$input_path"
            ;;
    esac
}

trim_trailing_slash() {
    local path_value="$1"

    while [ "$path_value" != "/" ] && [ "${path_value%/}" != "$path_value" ]; do
        path_value=${path_value%/}
    done

    printf '%s\n' "$path_value"
}

ensure_data_files() {
    if [ ! -f "$CONFIG_FILE" ]; then
        {
            printf 'CONFIG_DEFAULT_USER_NAME=%q\n' "$CONFIG_DEFAULT_USER_NAME"
            printf 'AUTO_CHECK_ON_START=%q\n' "$AUTO_CHECK_ON_START"
        } > "$CONFIG_FILE"
    fi

    if [ ! -f "$WHITELIST_FILE" ]; then
        : > "$WHITELIST_FILE"
    fi
}

load_config() {
    CONFIG_DEFAULT_USER_NAME="$FALLBACK_USER_NAME"
    AUTO_CHECK_ON_START=0

    ensure_data_files

    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
    fi

    if [ -z "$CONFIG_DEFAULT_USER_NAME" ]; then
        CONFIG_DEFAULT_USER_NAME="$FALLBACK_USER_NAME"
    fi

    case "$AUTO_CHECK_ON_START" in
        1)
            ;;
        *)
            AUTO_CHECK_ON_START=0
            ;;
    esac
}

save_config() {
    ensure_data_files

    {
        printf 'CONFIG_DEFAULT_USER_NAME=%q\n' "$CONFIG_DEFAULT_USER_NAME"
        printf 'AUTO_CHECK_ON_START=%q\n' "$AUTO_CHECK_ON_START"
    } > "$CONFIG_FILE"
}

get_effective_default_user_name() {
    if [ -n "$CONFIG_DEFAULT_USER_NAME" ]; then
        printf '%s\n' "$CONFIG_DEFAULT_USER_NAME"
    else
        printf '%s\n' "$FALLBACK_USER_NAME"
    fi
}

read_whitelist_items() {
    local line=""

    WHITELIST_ITEMS=()
    ensure_data_files

    while IFS= read -r line || [ -n "$line" ]; do
        line=$(trim_spaces "$line")
        [ -n "$line" ] || continue
        WHITELIST_ITEMS+=("$line")
    done < "$WHITELIST_FILE"
}

print_whitelist() {
    local index=0

    read_whitelist_items

    printf '\n当前白名单：\n'
    if [ "${#WHITELIST_ITEMS[@]}" -eq 0 ]; then
        printf '（空）\n'
        return
    fi

    for index in "${!WHITELIST_ITEMS[@]}"; do
        printf '%s. %s\n' "$((index + 1))" "${WHITELIST_ITEMS[index]}"
    done
}

is_whitelisted() {
    local plugin_name="$1"

    [ -n "$plugin_name" ] || return 1
    ensure_data_files

    grep -Fxq -- "$plugin_name" "$WHITELIST_FILE" 2>/dev/null
}

append_whitelist_name() {
    local plugin_name="$1"

    plugin_name=$(trim_spaces "$plugin_name")
    [ -n "$plugin_name" ] || return 1

    case "$plugin_name" in
        */*)
            printf '[跳过] 白名单项不能包含 / ：%s\n' "$plugin_name"
            return 1
            ;;
    esac

    if is_whitelisted "$plugin_name"; then
        printf '[跳过] 白名单已存在：%s\n' "$plugin_name"
        return 0
    fi

    printf '%s\n' "$plugin_name" >> "$WHITELIST_FILE"
    printf '[已添加] %s\n' "$plugin_name"
}

remove_whitelist_name() {
    local target_name="$1"
    local temp_file="$WHITELIST_FILE.tmp.$$"
    local found=1
    local line=""

    target_name=$(trim_spaces "$target_name")
    [ -n "$target_name" ] || return 1

    ensure_data_files
    : > "$temp_file" || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        line=$(trim_spaces "$line")
        [ -n "$line" ] || continue

        if [ "$line" = "$target_name" ] && [ "$found" -eq 1 ]; then
            found=0
            continue
        fi

        printf '%s\n' "$line" >> "$temp_file"
    done < "$WHITELIST_FILE"

    mv "$temp_file" "$WHITELIST_FILE" || return 1
    return "$found"
}

split_csv_to_array() {
    local raw_input="$1"
    local item=""
    local raw_items=()

    PARSED_ITEMS=()
    IFS=',' read -r -a raw_items <<< "$raw_input"

    for item in "${raw_items[@]}"; do
        item=$(trim_spaces "$item")
        [ -n "$item" ] || continue
        PARSED_ITEMS+=("$item")
    done
}

array_contains() {
    local target="$1"
    shift

    local current=""
    for current in "$@"; do
        if [ "$current" = "$target" ]; then
            return 0
        fi
    done

    return 1
}

is_sillytavern_root() {
    local root_path="$1"

    [ -n "$root_path" ] || return 1
    [ -d "$root_path" ] || return 1
    [ -d "$root_path/public" ] || return 1
    [ -d "$root_path/data" ] || return 1
    [ -d "$root_path/public/scripts/extensions" ] || return 1

    return 0
}

find_root_in_ancestors() {
    local start_path="$1"
    local current_path=""
    local parent_path=""

    [ -n "$start_path" ] || return 1
    [ -d "$start_path" ] || return 1

    current_path=$(trim_trailing_slash "$start_path")

    while :; do
        if is_sillytavern_root "$current_path"; then
            printf '%s\n' "$current_path"
            return 0
        fi

        if [ "$current_path" = "/" ]; then
            break
        fi

        parent_path=${current_path%/*}
        if [ -z "$parent_path" ]; then
            parent_path="/"
        fi

        if [ "$parent_path" = "$current_path" ]; then
            break
        fi

        current_path="$parent_path"
    done

    return 1
}

detect_sillytavern_root() {
    local current_dir=""
    local detected_root=""
    local script_search_dir=""
    local candidate=""

    current_dir=$(pwd 2>/dev/null)
    if [ -n "$current_dir" ]; then
        detected_root=$(find_root_in_ancestors "$current_dir")
        if [ -n "$detected_root" ]; then
            printf '%s\n' "$detected_root"
            return 0
        fi
    fi

    script_search_dir=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)
    if [ -n "$script_search_dir" ]; then
        detected_root=$(find_root_in_ancestors "$script_search_dir")
        if [ -n "$detected_root" ]; then
            printf '%s\n' "$detected_root"
            return 0
        fi
    fi

    for candidate in \
        "$HOME/SillyTavern" \
        "$HOME/sillytavern" \
        "$HOME/storage/shared/SillyTavern" \
        "$HOME/storage/shared/sillytavern" \
        "/storage/emulated/0/SillyTavern" \
        "/storage/emulated/0/sillytavern" \
        "/sdcard/SillyTavern" \
        "/sdcard/sillytavern"
    do
        candidate=$(trim_trailing_slash "$candidate")
        if is_sillytavern_root "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

prompt_for_st_root() {
    local manual_root=""
    local selected_root=""

    while :; do
        printf '未自动识别 SillyTavern 根目录，请输入路径（直接回车使用默认值：%s）：' "$DEFAULT_ST_ROOT" >&2
        IFS= read -r manual_root

        if [ -z "$manual_root" ]; then
            selected_root="$DEFAULT_ST_ROOT"
        else
            selected_root=$(expand_home_path "$manual_root")
        fi

        selected_root=$(trim_trailing_slash "$selected_root")

        if is_sillytavern_root "$selected_root"; then
            printf '%s\n' "$selected_root"
            return 0
        fi

        printf '输入的目录看起来不是 SillyTavern 根目录：%s\n' "$selected_root" >&2
        printf '请确认该目录下能看到 public 和 data。\n\n' >&2
    done
}

prompt_for_user_name() {
    local default_user_name="$1"
    local input_user_name=""

    printf '请输入用户目录名（直接回车使用默认值：%s）：' "$default_user_name" >&2
    IFS= read -r input_user_name

    if [ -z "$input_user_name" ]; then
        printf '%s\n' "$default_user_name"
    else
        printf '%s\n' "$input_user_name"
    fi
}

resolve_st_root_interactive() {
    local input_st_root="$1"
    local st_root=""

    ACTIVE_ST_ROOT=""

    if [ -z "$input_st_root" ] && [ -n "$ST_ROOT" ]; then
        input_st_root="$ST_ROOT"
    fi

    if [ -n "$input_st_root" ]; then
        st_root=$(expand_home_path "$input_st_root")
        st_root=$(trim_trailing_slash "$st_root")

        if ! is_sillytavern_root "$st_root"; then
            printf '错误：指定的 SillyTavern 根目录无效：%s\n' "$st_root"
            printf '请确认该目录下能看到 public 和 data。\n'
            return 1
        fi

        printf '已使用指定的 SillyTavern 根目录：%s\n' "$st_root"
    else
        st_root=$(detect_sillytavern_root)
        if [ -n "$st_root" ]; then
            printf '已自动识别 SillyTavern 根目录：%s\n' "$st_root"
        else
            st_root=$(prompt_for_st_root)
            printf '已使用手动输入的 SillyTavern 根目录：%s\n' "$st_root"
        fi
    fi

    ACTIVE_ST_ROOT="$st_root"
    return 0
}

resolve_st_root_noninteractive() {
    local input_st_root="$1"
    local st_root=""

    ACTIVE_ST_ROOT=""

    if [ -z "$input_st_root" ] && [ -n "$ST_ROOT" ]; then
        input_st_root="$ST_ROOT"
    fi

    if [ -n "$input_st_root" ]; then
        st_root=$(expand_home_path "$input_st_root")
        st_root=$(trim_trailing_slash "$st_root")

        if ! is_sillytavern_root "$st_root"; then
            printf '自动检测更新已跳过：指定的 SillyTavern 根目录无效：%s\n' "$st_root"
            return 1
        fi
    else
        st_root=$(detect_sillytavern_root)
        if [ -z "$st_root" ]; then
            printf '自动检测更新已跳过：未自动识别到 SillyTavern 根目录。\n'
            return 1
        fi
    fi

    ACTIVE_ST_ROOT="$st_root"
    return 0
}

resolve_user_name_interactive() {
    local input_user_name="$1"
    local default_user_name=""

    ACTIVE_USER_NAME=""

    if [ -z "$input_user_name" ] && [ -n "$ST_USER_NAME" ]; then
        input_user_name="$ST_USER_NAME"
    fi

    if [ -n "$input_user_name" ]; then
        ACTIVE_USER_NAME="$input_user_name"
        printf '已使用指定的用户目录名：%s\n' "$ACTIVE_USER_NAME"
        return 0
    fi

    default_user_name=$(get_effective_default_user_name)
    ACTIVE_USER_NAME=$(prompt_for_user_name "$default_user_name")

    if [ -z "$ACTIVE_USER_NAME" ]; then
        ACTIVE_USER_NAME="$default_user_name"
    fi

    return 0
}

resolve_user_name_noninteractive() {
    local input_user_name="$1"

    ACTIVE_USER_NAME=""

    if [ -z "$input_user_name" ] && [ -n "$ST_USER_NAME" ]; then
        input_user_name="$ST_USER_NAME"
    fi

    if [ -n "$input_user_name" ]; then
        ACTIVE_USER_NAME="$input_user_name"
    else
        ACTIVE_USER_NAME=$(get_effective_default_user_name)
    fi

    if [ -z "$ACTIVE_USER_NAME" ]; then
        ACTIVE_USER_NAME="$FALLBACK_USER_NAME"
    fi

    return 0
}

prepare_context_interactive() {
    local input_st_root="$1"
    local input_user_name="$2"

    resolve_st_root_interactive "$input_st_root" || return 1
    resolve_user_name_interactive "$input_user_name" || return 1
    return 0
}

prepare_context_noninteractive() {
    local input_st_root="$1"
    local input_user_name="$2"

    resolve_st_root_noninteractive "$input_st_root" || return 1
    resolve_user_name_noninteractive "$input_user_name" || return 1
    return 0
}

is_termux_environment() {
    [ -n "$TERMUX_VERSION" ] || [ -d "/data/data/com.termux/files/usr" ]
}

require_git() {
    if ! command -v git >/dev/null 2>&1; then
        printf '错误：未检测到 git，请先安装 git。\n'
        if command -v pkg >/dev/null 2>&1; then
            printf 'Termux 可执行：pkg install git\n'
        else
            printf '请先在当前系统安装 git，再重新运行脚本。\n'
        fi
        return 1
    fi

    return 0
}

reset_update_stats() {
    checked_count=0
    updated_count=0
    no_update_count=0
    skipped_count=0
    failed_count=0
    SKIPPED_DETAILS=()
    FAILED_DETAILS=()
}

record_skipped_detail() {
    local plugin_name="$1"
    local reason="$2"

    SKIPPED_DETAILS+=("${plugin_name}：${reason}")
}

record_failed_detail() {
    local plugin_name="$1"
    local reason="$2"

    FAILED_DETAILS+=("${plugin_name}：${reason}")
}

summarize_command_error() {
    local raw_output="$1"
    local line=""
    local summary=""

    raw_output=${raw_output//$'\r'/}

    while IFS= read -r line; do
        line=$(trim_spaces "$line")
        [ -n "$line" ] || continue
        summary="$line"
        break
    done <<< "$raw_output"

    if [ -z "$summary" ]; then
        summary="未提供详细错误信息"
    fi

    if [ "${#summary}" -gt 120 ]; then
        summary="${summary:0:117}..."
    fi

    printf '%s\n' "$summary"
}

print_summary_detail_item() {
    local item="$1"
    local detail_head=""
    local remaining_text=""
    local plugin_name=""
    local source_text=""

    detail_head=${item%%：*}
    if [ "$detail_head" = "$item" ]; then
        printf '%s\n' "$item"
        return
    fi

    remaining_text=${item#"$detail_head"}
    plugin_name="$detail_head"
    source_text=""

    case "$detail_head" in
        *"（public）")
            plugin_name=${detail_head%（public）}
            source_text='（public）'
            ;;
        *"（user）")
            plugin_name=${detail_head%（user）}
            source_text='（user）'
            ;;
    esac

    printf '%s%s%s\n' "$(format_red_text "$plugin_name")" "$source_text" "$remaining_text"
}

print_summary_detail_list() {
    local title="$1"
    local empty_text="$2"
    local item=""

    shift 2

    printf '\n%s：\n' "$title"
    if [ "$#" -eq 0 ]; then
        printf '%s\n' "$empty_text"
        return
    fi

    for item in "$@"; do
        printf -- '- '
        print_summary_detail_item "$item"
    done
}

# 使用非交互 Git，避免远程仓库转私有/失效时卡在认证输入。
git_non_interactive() {
    GIT_TERMINAL_PROMPT=0 \
    GCM_INTERACTIVE=Never \
    GIT_SSH_COMMAND='ssh -oBatchMode=yes' \
    git "$@"
}

is_remote_access_issue() {
    local message=""

    message=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')

    case "$message" in
        *"authentication failed"*|\
        *"authentication required"*|\
        *"could not read username"*|\
        *"could not read password"*|\
        *"terminal prompts disabled"*|\
        *"repository not found"*|\
        *"requested url returned error: 401"*|\
        *"requested url returned error: 403"*|\
        *"requested url returned error: 404"*|\
        *"access denied"*|\
        *"permission denied"*|\
        *"unauthorized"*|\
        *"forbidden"*|\
        *"not authorized"*|\
        *"support for password authentication was removed"*|\
        *"does not appear to be a git repository"*|\
        *"could not read from remote repository"*)
            return 0
            ;;
    esac

    return 1
}

process_plugin_update() {
    local repo_dir="$1"
    local source_label="$2"
    local repo_name=""
    local repo_display_name=""
    local upstream_ref=""
    local remote_name=""
    local remote_check_output=""
    local remote_check_status=0
    local fetch_output=""
    local fetch_status=0
    local counts=""
    local local_ahead=0
    local remote_ahead=0
    local pull_output=""
    local pull_status=0

    repo_name=${repo_dir##*/}
    repo_display_name="${repo_name}（${source_label}）"
    checked_count=$((checked_count + 1))

    printf '[检查] %s\n' "$repo_name"

    if [ ! -d "$repo_dir" ]; then
        skipped_count=$((skipped_count + 1))
        record_skipped_detail "$repo_display_name" "目录不存在"
        printf '  -> [跳过] 目录不存在\n\n'
        return 0
    fi

    if is_whitelisted "$repo_name"; then
        skipped_count=$((skipped_count + 1))
        record_skipped_detail "$repo_display_name" "命中白名单"
        printf '  -> [跳过] 命中白名单，已跳过更新检测\n\n'
        return 0
    fi

    if ! git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        skipped_count=$((skipped_count + 1))
        record_skipped_detail "$repo_display_name" "不是 Git 仓库"
        printf '  -> [跳过] 不是 Git 仓库\n\n'
        return 0
    fi

    upstream_ref=$(git -C "$repo_dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
    if [ -z "$upstream_ref" ]; then
        skipped_count=$((skipped_count + 1))
        record_skipped_detail "$repo_display_name" "未配置上游分支"
        printf '  -> [跳过] Git 仓库未配置上游分支\n\n'
        return 0
    fi

    remote_name=${upstream_ref%%/*}
    remote_check_output=$(git_non_interactive -C "$repo_dir" ls-remote --quiet "$remote_name" HEAD 2>&1)
    remote_check_status=$?
    if [ "$remote_check_status" -ne 0 ]; then
        if is_remote_access_issue "$remote_check_output"; then
            skipped_count=$((skipped_count + 1))
            record_skipped_detail "$repo_display_name" "远程仓库不可访问（$(summarize_command_error "$remote_check_output")）"
            printf '  -> [跳过] 远程仓库不可访问（可能已转私有 / 不存在 / 需要认证）\n'
        else
            failed_count=$((failed_count + 1))
            record_failed_detail "$repo_display_name" "无法访问远程仓库（$(summarize_command_error "$remote_check_output")）"
            printf '  -> [失败] 无法访问远程仓库\n'
        fi
        printf '%s\n\n' "$remote_check_output"
        return 0
    fi

    fetch_output=$(git_non_interactive -C "$repo_dir" fetch --all --prune 2>&1)
    fetch_status=$?
    if [ "$fetch_status" -ne 0 ]; then
        if is_remote_access_issue "$fetch_output"; then
            skipped_count=$((skipped_count + 1))
            record_skipped_detail "$repo_display_name" "远程仓库不可访问（$(summarize_command_error "$fetch_output")）"
            printf '  -> [跳过] 远程仓库不可访问（可能已转私有 / 不存在 / 需要认证）\n'
        else
            failed_count=$((failed_count + 1))
            record_failed_detail "$repo_display_name" "fetch 失败（$(summarize_command_error "$fetch_output")）"
            printf '  -> [失败] fetch 失败\n'
        fi
        printf '%s\n\n' "$fetch_output"
        return 0
    fi

    counts=$(git -C "$repo_dir" rev-list --left-right --count "HEAD...$upstream_ref" 2>/dev/null)
    if [ -z "$counts" ]; then
        failed_count=$((failed_count + 1))
        record_failed_detail "$repo_display_name" "无法比较本地与远程差异"
        printf '  -> [失败] 无法比较本地与远程差异\n\n'
        return 0
    fi

    set -- $counts
    local_ahead=$1
    remote_ahead=$2

    if [ "$remote_ahead" -eq 0 ]; then
        no_update_count=$((no_update_count + 1))
        if [ "$local_ahead" -gt 0 ]; then
            printf '  -> [无更新] 远程没有新提交（本地领先 %s 个提交）\n\n' "$local_ahead"
        else
            printf '  -> [无更新] 本地已是最新\n\n'
        fi
        return 0
    fi

    pull_output=$(git_non_interactive -C "$repo_dir" pull --ff-only 2>&1)
    pull_status=$?
    if [ "$pull_status" -eq 0 ]; then
        updated_count=$((updated_count + 1))
        printf '  -> [已更新] 已拉取远程更新（远程领先 %s 个提交）\n' "$remote_ahead"
        if [ -n "$pull_output" ]; then
            printf '%s\n' "$pull_output"
        fi
        printf '\n'
    else
        if is_remote_access_issue "$pull_output"; then
            skipped_count=$((skipped_count + 1))
            record_skipped_detail "$repo_display_name" "拉取时远程仓库不可访问（$(summarize_command_error "$pull_output")）"
            printf '  -> [跳过] 拉取时远程仓库不可访问（可能已转私有 / 不存在 / 需要认证）\n'
        else
            failed_count=$((failed_count + 1))
            record_failed_detail "$repo_display_name" "pull 失败（$(summarize_command_error "$pull_output")）"
            printf '  -> [失败] pull 失败\n'
        fi
        printf '%s\n\n' "$pull_output"
    fi
}

scan_extensions_dir() {
    local base_dir="$1"
    local scan_label="$2"
    local source_label="$3"
    local repo_dir=""
    local found_any=0

    printf '\n==== 扫描目录：%s ====\n' "$scan_label"
    printf '%s\n\n' "$base_dir"

    if [ ! -d "$base_dir" ]; then
        printf '[总目录不存在] 已跳过：%s\n' "$base_dir"
        return
    fi

    for repo_dir in "$base_dir"/*; do
        [ -d "$repo_dir" ] || continue
        found_any=1
        process_plugin_update "$repo_dir" "$source_label"
    done

    if [ "$found_any" -eq 0 ]; then
        printf '[目录为空] %s 下没有可检查的子目录\n' "$base_dir"
    fi
}

print_update_summary() {
    printf '\n==== 汇总统计 ====\n'
    printf 'SillyTavern 根目录：%s\n' "$ACTIVE_ST_ROOT"
    printf '用户目录名：%s\n' "$ACTIVE_USER_NAME"
    printf '已检查子目录：%s\n' "$checked_count"
    printf '已更新仓库：%s\n' "$updated_count"
    printf '无更新仓库：%s\n' "$no_update_count"
    printf '已跳过项目：%s\n' "$skipped_count"
    printf '失败项目数：%s\n' "$failed_count"

    print_summary_detail_list "跳过项目列表" "无" "${SKIPPED_DETAILS[@]}"
    print_summary_detail_list "失败项目列表" "无" "${FAILED_DETAILS[@]}"
}

run_update_flow() {
    local interactive_mode="$1"
    local input_st_root="$2"
    local input_user_name="$3"
    local third_party_dir=""
    local user_extensions_dir=""

    if [ "$interactive_mode" = "1" ]; then
        require_git || return 1
        prepare_context_interactive "$input_st_root" "$input_user_name" || return 1
    else
        if ! require_git; then
            printf '自动检测更新已跳过：未检测到 git。\n'
            return 0
        fi

        if ! prepare_context_noninteractive "$input_st_root" "$input_user_name"; then
            return 0
        fi
    fi

    third_party_dir="$ACTIVE_ST_ROOT/public/scripts/extensions/third-party"
    user_extensions_dir="$ACTIVE_ST_ROOT/data/$ACTIVE_USER_NAME/extensions"

    reset_update_stats

    printf '\n将按顺序检查以下扩展目录：\n'
    printf '1) %s\n' "$third_party_dir"
    printf '2) %s\n' "$user_extensions_dir"

    scan_extensions_dir "$third_party_dir" "第三方扩展目录" "public"
    scan_extensions_dir "$user_extensions_dir" "用户扩展目录" "user"

    print_update_summary
}

collect_plugins_from_dir() {
    local base_dir="$1"
    local source_label="$2"
    local plugin_dir=""

    [ -d "$base_dir" ] || return 0

    for plugin_dir in "$base_dir"/*; do
        [ -d "$plugin_dir" ] || continue
        PLUGIN_NAMES+=("${plugin_dir##*/}")
        PLUGIN_PATHS+=("$plugin_dir")
        PLUGIN_SOURCES+=("$source_label")
    done
}

collect_plugins() {
    local st_root="$1"
    local user_name="$2"
    local third_party_dir="$st_root/public/scripts/extensions/third-party"
    local user_extensions_dir="$st_root/data/$user_name/extensions"

    PLUGIN_NAMES=()
    PLUGIN_PATHS=()
    PLUGIN_SOURCES=()

    collect_plugins_from_dir "$third_party_dir" "public"
    collect_plugins_from_dir "$user_extensions_dir" "user"
}

print_plugin_sources() {
    local st_root="$1"
    local user_name="$2"

    printf '\n当前检查的目录：\n'
    printf '1) public: %s\n' "$st_root/public/scripts/extensions/third-party"
    printf '2) user:   %s\n' "$st_root/data/$user_name/extensions"
}

display_plugins() {
    local index=0
    local mark=""

    if [ "${#PLUGIN_NAMES[@]}" -eq 0 ]; then
        printf '\n未找到任何已安装插件。\n'
        return 0
    fi

    printf '\n==== 已安装插件列表 ====\n'
    for index in "${!PLUGIN_NAMES[@]}"; do
        mark=""
        if is_whitelisted "${PLUGIN_NAMES[index]}"; then
            mark=' [白名单]'
        fi
        printf '%s. %s | 来源：%s%s\n' \
            "$((index + 1))" \
            "${PLUGIN_NAMES[index]}" \
            "${PLUGIN_SOURCES[index]}" \
            "$mark"
    done
}

view_plugins_workflow() {
    prepare_context_interactive "$1" "$2" || return 1
    print_plugin_sources "$ACTIVE_ST_ROOT" "$ACTIVE_USER_NAME"
    collect_plugins "$ACTIVE_ST_ROOT" "$ACTIVE_USER_NAME"
    display_plugins
}

batch_update_workflow() {
    local raw_input=""
    local selected_numbers=()
    local token=""
    local index=0

    require_git || return 1
    prepare_context_interactive "$1" "$2" || return 1
    print_plugin_sources "$ACTIVE_ST_ROOT" "$ACTIVE_USER_NAME"
    collect_plugins "$ACTIVE_ST_ROOT" "$ACTIVE_USER_NAME"

    if [ "${#PLUGIN_NAMES[@]}" -eq 0 ]; then
        printf '\n未找到任何可更新插件。\n'
        return 0
    fi

    display_plugins

    printf '\n请输入要更新的序号，多个可用逗号分隔（将按输入顺序执行）：'
    IFS= read -r raw_input
    split_csv_to_array "$raw_input"

    if [ "${#PARSED_ITEMS[@]}" -eq 0 ]; then
        printf '未输入任何有效序号，已取消批量更新。\n'
        return 0
    fi

    for token in "${PARSED_ITEMS[@]}"; do
        case "$token" in
            *[!0-9]*|'')
                printf '[跳过] 非法序号：%s\n' "$token"
                continue
                ;;
        esac

        if [ "$token" -lt 1 ] || [ "$token" -gt "${#PLUGIN_NAMES[@]}" ]; then
            printf '[跳过] 序号超出范围：%s\n' "$token"
            continue
        fi

        if array_contains "$token" "${selected_numbers[@]}"; then
            printf '[跳过] 重复序号：%s\n' "$token"
            continue
        fi

        selected_numbers+=("$token")
    done

    if [ "${#selected_numbers[@]}" -eq 0 ]; then
        printf '没有可更新的有效序号。\n'
        return 0
    fi

    printf '\n==== 批量更新顺序 ====\n'
    for token in "${selected_numbers[@]}"; do
        index=$((token - 1))
        printf '%s. %s | 来源：%s\n' \
            "$token" \
            "${PLUGIN_NAMES[index]}" \
            "${PLUGIN_SOURCES[index]}"
    done

    reset_update_stats

    printf '\n==== 开始批量更新 ====\n'
    for token in "${selected_numbers[@]}"; do
        index=$((token - 1))
        process_plugin_update "${PLUGIN_PATHS[index]}" "${PLUGIN_SOURCES[index]}"
    done

    print_update_summary
}

remove_autostart_block_from_file() {
    local file_path="$1"
    local temp_file="$file_path.tmp.$$"
    local in_block=0
    local line=""

    [ -f "$file_path" ] || return 0
    : > "$temp_file" || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "$AUTO_START_BEGIN" ]; then
            in_block=1
            continue
        fi

        if [ "$line" = "$AUTO_START_END" ]; then
            in_block=0
            continue
        fi

        if [ "$in_block" -eq 1 ]; then
            continue
        fi

        printf '%s\n' "$line" >> "$temp_file"
    done < "$file_path"

    mv "$temp_file" "$file_path"
}

append_autostart_block_to_file() {
    local file_path="$1"

    [ -f "$file_path" ] || : > "$file_path" || return 1

    {
        if [ -s "$file_path" ]; then
            printf '\n'
        fi
        printf '%s\n' "$AUTO_START_BEGIN"
        printf 'if [ -z "$ST_EXTENSION_MANAGER_AUTO_STARTED" ] && [ -n "$TERMUX_VERSION" ] && [ -f %q ]; then\n' "$SCRIPT_PATH"
        printf '    export ST_EXTENSION_MANAGER_AUTO_STARTED=1\n'
        printf '    bash %q --auto-start-check\n' "$SCRIPT_PATH"
        printf 'fi\n'
        printf '%s\n' "$AUTO_START_END"
    } >> "$file_path"
}

disable_autostart_in_shell_files() {
    local file_path=""

    for file_path in "$HOME/.bashrc" "$HOME/.zshrc"; do
        [ -f "$file_path" ] || continue
        remove_autostart_block_from_file "$file_path" || return 1
    done

    return 0
}

enable_autostart_in_shell_files() {
    local file_path=""
    local target_files=()

    disable_autostart_in_shell_files || return 1

    if [ -f "$HOME/.bashrc" ]; then
        target_files+=("$HOME/.bashrc")
    fi

    if [ -f "$HOME/.zshrc" ]; then
        target_files+=("$HOME/.zshrc")
    fi

    if [ "${#target_files[@]}" -eq 0 ]; then
        target_files+=("$HOME/.bashrc")
    fi

    for file_path in "${target_files[@]}"; do
        append_autostart_block_to_file "$file_path" || return 1
        printf '已写入启动项：%s\n' "$file_path"
    done

    return 0
}

set_default_user_name_workflow() {
    local current_default_user_name=""
    local new_default_user_name=""

    current_default_user_name=$(get_effective_default_user_name)

    printf '当前默认用户名：%s\n' "$current_default_user_name"
    printf '请输入新的默认用户名（直接回车保持不变）：'
    IFS= read -r new_default_user_name

    new_default_user_name=$(trim_spaces "$new_default_user_name")
    if [ -z "$new_default_user_name" ]; then
        printf '未修改默认用户名。\n'
        return 0
    fi

    CONFIG_DEFAULT_USER_NAME="$new_default_user_name"
    save_config || return 1
    printf '已保存默认用户名：%s\n' "$CONFIG_DEFAULT_USER_NAME"
}

toggle_auto_check_on_start_workflow() {
    if [ "$AUTO_CHECK_ON_START" = "1" ]; then
        if is_termux_environment; then
            disable_autostart_in_shell_files || return 1
        fi

        AUTO_CHECK_ON_START=0
        save_config || return 1
        printf '已关闭“打开 Termux 时自动检测更新”。\n'
        if ! is_termux_environment; then
            printf '当前不是 Termux 环境，未修改本机 shell 启动文件。\n'
        fi
    else
        if is_termux_environment; then
            enable_autostart_in_shell_files || return 1
        fi

        AUTO_CHECK_ON_START=1
        save_config || return 1
        printf '已开启“打开 Termux 时自动检测更新”。\n'
        if is_termux_environment; then
            printf '下次打开 Termux 时会直接执行更新流程，不进入菜单。\n'
        else
            printf '当前不是 Termux 环境，未修改本机 shell 启动文件。\n'
            printf '如需真正写入启动项，请在 Termux 中运行本脚本后再打开此设置。\n'
        fi
    fi
}

whitelist_menu() {
    local menu_choice=""
    local raw_input=""
    local item=""

    while :; do
        printf '\n==== 白名单管理 ====\n'
        print_whitelist
        printf '\n1. 添加插件名\n'
        printf '2. 移除插件名\n'
        printf '0. 返回\n'
        printf '请选择：'
        IFS= read -r menu_choice

        case "$menu_choice" in
            1)
                printf '请输入要加入白名单的插件文件夹名，多个可用逗号分隔：'
                IFS= read -r raw_input
                split_csv_to_array "$raw_input"

                if [ "${#PARSED_ITEMS[@]}" -eq 0 ]; then
                    printf '未输入有效的插件名。\n'
                else
                    for item in "${PARSED_ITEMS[@]}"; do
                        append_whitelist_name "$item"
                    done
                fi
                press_enter_to_continue
                ;;
            2)
                if [ ! -s "$WHITELIST_FILE" ]; then
                    printf '当前白名单为空，无需移除。\n'
                    press_enter_to_continue
                    continue
                fi

                printf '请输入要移除的插件文件夹名，多个可用逗号分隔：'
                IFS= read -r raw_input
                split_csv_to_array "$raw_input"

                if [ "${#PARSED_ITEMS[@]}" -eq 0 ]; then
                    printf '未输入有效的插件名。\n'
                else
                    for item in "${PARSED_ITEMS[@]}"; do
                        if remove_whitelist_name "$item"; then
                            printf '[已移除] %s\n' "$item"
                        else
                            printf '[跳过] 白名单中不存在：%s\n' "$item"
                        fi
                    done
                fi
                press_enter_to_continue
                ;;
            0)
                return 0
                ;;
            *)
                printf '无效选项，请重新输入。\n'
                press_enter_to_continue
                ;;
        esac
    done
}

delete_plugins_workflow() {
    local raw_input=""
    local selected_numbers=()
    local token=""
    local index=0
    local confirm_delete=""
    local delete_success_count=0
    local delete_failed_count=0
    local delete_skipped_count=0
    local delete_path=""

    prepare_context_interactive "$1" "$2" || return 1
    print_plugin_sources "$ACTIVE_ST_ROOT" "$ACTIVE_USER_NAME"
    collect_plugins "$ACTIVE_ST_ROOT" "$ACTIVE_USER_NAME"

    if [ "${#PLUGIN_NAMES[@]}" -eq 0 ]; then
        printf '\n未找到任何可删除插件。\n'
        return 0
    fi

    display_plugins

    printf '\n请输入要删除的序号，多个可用逗号分隔：'
    IFS= read -r raw_input
    split_csv_to_array "$raw_input"

    if [ "${#PARSED_ITEMS[@]}" -eq 0 ]; then
        printf '未输入任何有效序号，已取消删除。\n'
        return 0
    fi

    for token in "${PARSED_ITEMS[@]}"; do
        case "$token" in
            *[!0-9]*|'')
                delete_skipped_count=$((delete_skipped_count + 1))
                printf '[跳过] 非法序号：%s\n' "$token"
                continue
                ;;
        esac

        if [ "$token" -lt 1 ] || [ "$token" -gt "${#PLUGIN_NAMES[@]}" ]; then
            delete_skipped_count=$((delete_skipped_count + 1))
            printf '[跳过] 序号超出范围：%s\n' "$token"
            continue
        fi

        if array_contains "$token" "${selected_numbers[@]}"; then
            delete_skipped_count=$((delete_skipped_count + 1))
            printf '[跳过] 重复序号：%s\n' "$token"
            continue
        fi

        selected_numbers+=("$token")
    done

    if [ "${#selected_numbers[@]}" -eq 0 ]; then
        printf '没有可删除的有效序号。\n'
        printf '删除统计：成功 0，失败 0，跳过 %s\n' "$delete_skipped_count"
        return 0
    fi

    printf '\n将删除以下插件：\n'
    for token in "${selected_numbers[@]}"; do
        index=$((token - 1))
        printf '%s. %s | 来源：%s\n' \
            "$token" \
            "${PLUGIN_NAMES[index]}" \
            "${PLUGIN_SOURCES[index]}"
    done

    printf '请输入 y 确认删除：'
    IFS= read -r confirm_delete
    case "$confirm_delete" in
        y|Y)
            ;;
        *)
            printf '已取消删除。\n'
            return 0
            ;;
    esac

    for token in "${selected_numbers[@]}"; do
        index=$((token - 1))
        delete_path="${PLUGIN_PATHS[index]}"

        if [ ! -e "$delete_path" ]; then
            delete_skipped_count=$((delete_skipped_count + 1))
            printf '[跳过] 目录已不存在：%s\n' "$delete_path"
            continue
        fi

        rm -rf -- "$delete_path"
        if [ -e "$delete_path" ]; then
            delete_failed_count=$((delete_failed_count + 1))
            printf '[失败] 删除失败：%s\n' "$delete_path"
        else
            delete_success_count=$((delete_success_count + 1))
            printf '[已删除] %s\n' "$delete_path"
        fi
    done

    printf '\n删除统计：成功 %s，失败 %s，跳过 %s\n' \
        "$delete_success_count" \
        "$delete_failed_count" \
        "$delete_skipped_count"
}

settings_menu() {
    local menu_choice=""
    local auto_status=""

    while :; do
        if [ "$AUTO_CHECK_ON_START" = "1" ]; then
            auto_status='已开启'
        else
            auto_status='已关闭'
        fi

        printf '\n==== 设置 ====\n'
        printf '1. 默认用户名：%s\n' "$(get_effective_default_user_name)"
        printf '2. 打开 Termux 时自动检测更新：%s\n' "$auto_status"
        printf '0. 返回\n'
        printf '请选择：'
        IFS= read -r menu_choice

        case "$menu_choice" in
            1)
                set_default_user_name_workflow || printf '保存默认用户名失败。\n'
                press_enter_to_continue
                ;;
            2)
                toggle_auto_check_on_start_workflow || printf '切换自动检测更新失败。\n'
                press_enter_to_continue
                ;;
            0)
                return 0
                ;;
            *)
                printf '无效选项，请重新输入。\n'
                press_enter_to_continue
                ;;
        esac
    done
}

print_help() {
    printf '用法：\n'
    printf '  bash %s                # 打开交互式管理面板\n' "$SCRIPT_NAME"
    printf '  bash %s <根目录> <用户名>\n' "$SCRIPT_NAME"
    printf '  bash %s --run-update [根目录] [用户名]\n' "$SCRIPT_NAME"
    printf '  bash %s --auto-start-check [根目录] [用户名]\n' "$SCRIPT_NAME"
    printf '\n说明：\n'
    printf '  - 脚本现在依赖 bash 运行。\n'
    printf '  - Termux 和电脑上的 Git Bash / WSL 都可使用。\n'
    printf '  - “打开 Termux 时自动检测更新”只在 Termux 下生效。\n'
}

main_menu() {
    local menu_choice=""

    while :; do
        load_config
        printf '\n==== SillyTavern 扩展管理面板 ====\n'
        printf '1. 一键更新\n'
        printf '2. 批量更新脚本\n'
        printf '3. 白名单管理\n'
        printf '4. 插件查看\n'
        printf '5. 删除插件\n'
        printf '6. 设置\n'
        printf '0. 退出\n'
        printf '请选择：'
        IFS= read -r menu_choice

        case "$menu_choice" in
            1)
                run_update_flow 1 "" ""
                press_enter_to_continue
                ;;
            2)
                batch_update_workflow "" ""
                press_enter_to_continue
                ;;
            3)
                whitelist_menu
                ;;
            4)
                view_plugins_workflow "" ""
                press_enter_to_continue
                ;;
            5)
                delete_plugins_workflow "" ""
                press_enter_to_continue
                ;;
            6)
                settings_menu
                ;;
            0)
                printf '已退出。\n'
                return 0
                ;;
            *)
                printf '无效选项，请重新输入。\n'
                press_enter_to_continue
                ;;
        esac
    done
}

init_color_output
load_config

case "$1" in
    --help|-h)
        print_help
        ;;
    --auto-start-check)
        shift
        run_update_flow 0 "$1" "$2"
        ;;
    --run-update)
        shift
        run_update_flow 1 "$1" "$2"
        ;;
    "")
        main_menu
        ;;
    *)
        run_update_flow 1 "$1" "$2"
        ;;
esac

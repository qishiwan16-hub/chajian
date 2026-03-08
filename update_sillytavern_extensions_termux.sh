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
# JSON 命令模式（供本地 Web 面板调用）：
#   ./update_sillytavern_extensions_termux.sh --json plugins-list [--st-root 路径] [--user-name 用户名]
#   ./update_sillytavern_extensions_termux.sh --json status [--st-root 路径] [--user-name 用户名]
#   ./update_sillytavern_extensions_termux.sh --json update-all [--st-root 路径] [--user-name 用户名]
#   ./update_sillytavern_extensions_termux.sh --json update-selected --plugins name1,name2 [--st-root 路径] [--user-name 用户名]
#   ./update_sillytavern_extensions_termux.sh --json delete --plugins name1,name2 [--st-root 路径] [--user-name 用户名]
#   ./update_sillytavern_extensions_termux.sh --json whitelist-get
#   ./update_sillytavern_extensions_termux.sh --json whitelist-add --plugins name1,name2
#   ./update_sillytavern_extensions_termux.sh --json whitelist-remove --plugins name1,name2
#   ./update_sillytavern_extensions_termux.sh --json settings-get
#   ./update_sillytavern_extensions_termux.sh --json settings-save [--default-user-name 用户名] [--default-st-root 路径] [--auto-check-on-start 0|1]
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
CONFIG_DEFAULT_ST_ROOT=""
AUTO_CHECK_ON_START=0
ACTIVE_ST_ROOT=""
ACTIVE_USER_NAME=""

JSON_COMMAND=""
JSON_ST_ROOT=""
JSON_USER_NAME=""
JSON_PLUGIN_NAMES_CSV=""
JSON_DEFAULT_USER_NAME=""
JSON_DEFAULT_ST_ROOT=""
JSON_AUTO_CHECK_ON_START=""
JSON_DEFAULT_USER_NAME_SET=0
JSON_DEFAULT_ST_ROOT_SET=0
JSON_AUTO_CHECK_ON_START_SET=0
JSON_ERROR_CODE=""
JSON_ERROR_MESSAGE=""
JSON_ERROR_DETAILS=""

checked_count=0
updated_count=0
no_update_count=0
skipped_count=0
failed_count=0
SKIPPED_DETAILS=()
FAILED_DETAILS=()

SUMMARY_TOTAL=0
SUMMARY_UPDATABLE=0
SUMMARY_UP_TO_DATE=0
SUMMARY_SKIPPED=0
SUMMARY_FAILED=0
SUMMARY_STATUS_UPDATE_AVAILABLE=0
SUMMARY_STATUS_UPDATED=0
SUMMARY_STATUS_UP_TO_DATE=0
SUMMARY_STATUS_WHITELIST_SKIPPED=0
SUMMARY_STATUS_NON_GIT=0
SUMMARY_STATUS_NO_UPSTREAM=0
SUMMARY_STATUS_REMOTE_UNREACHABLE=0
SUMMARY_STATUS_UPDATE_FAILED=0

PLUGIN_NAMES=()
PLUGIN_PATHS=()
PLUGIN_SOURCES=()
SELECTED_PLUGIN_NAMES=()
SELECTED_PLUGIN_PATHS=()
SELECTED_PLUGIN_SOURCES=()
WHITELIST_ITEMS=()
PARSED_ITEMS=()
JSON_RESULT_ITEMS=()
JSON_MISSING_ITEMS=()

LAST_PLUGIN_NAME=""
LAST_PLUGIN_SOURCE=""
LAST_PLUGIN_PATH=""
LAST_PLUGIN_STATUS=""
LAST_PLUGIN_REASON=""
LAST_PLUGIN_REMOTE_NAME=""
LAST_PLUGIN_UPSTREAM_REF=""
LAST_PLUGIN_LOCAL_AHEAD=0
LAST_PLUGIN_REMOTE_AHEAD=0
LAST_PLUGIN_WHITELISTED=0

LAST_WHITELIST_ACTION_STATUS=""
LAST_WHITELIST_ACTION_MESSAGE=""

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

normalize_path_value() {
    local path_value="$1"

    path_value=$(expand_home_path "$path_value")
    path_value=$(trim_trailing_slash "$path_value")
    printf '%s\n' "$path_value"
}

ensure_data_files() {
    if [ ! -f "$CONFIG_FILE" ]; then
        {
            printf 'CONFIG_DEFAULT_USER_NAME=%q\n' "$CONFIG_DEFAULT_USER_NAME"
            printf 'CONFIG_DEFAULT_ST_ROOT=%q\n' "$CONFIG_DEFAULT_ST_ROOT"
            printf 'AUTO_CHECK_ON_START=%q\n' "$AUTO_CHECK_ON_START"
        } > "$CONFIG_FILE"
    fi

    if [ ! -f "$WHITELIST_FILE" ]; then
        : > "$WHITELIST_FILE"
    fi
}

load_config() {
    CONFIG_DEFAULT_USER_NAME="$FALLBACK_USER_NAME"
    CONFIG_DEFAULT_ST_ROOT=""
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
        printf 'CONFIG_DEFAULT_ST_ROOT=%q\n' "$CONFIG_DEFAULT_ST_ROOT"
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

get_effective_default_st_root() {
    if [ -n "$CONFIG_DEFAULT_ST_ROOT" ]; then
        printf '%s\n' "$(normalize_path_value "$CONFIG_DEFAULT_ST_ROOT")"
    else
        printf '%s\n' "$DEFAULT_ST_ROOT"
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

add_whitelist_name_result() {
    local plugin_name="$1"

    LAST_WHITELIST_ACTION_STATUS=""
    LAST_WHITELIST_ACTION_MESSAGE=""

    plugin_name=$(trim_spaces "$plugin_name")
    if [ -z "$plugin_name" ]; then
        LAST_WHITELIST_ACTION_STATUS="invalid"
        LAST_WHITELIST_ACTION_MESSAGE="插件文件夹名不能为空"
        return 1
    fi

    case "$plugin_name" in
        */*)
            LAST_WHITELIST_ACTION_STATUS="invalid"
            LAST_WHITELIST_ACTION_MESSAGE="白名单项不能包含 /"
            return 1
            ;;
    esac

    if is_whitelisted "$plugin_name"; then
        LAST_WHITELIST_ACTION_STATUS="exists"
        LAST_WHITELIST_ACTION_MESSAGE="白名单已存在"
        return 0
    fi

    if ! printf '%s\n' "$plugin_name" >> "$WHITELIST_FILE"; then
        LAST_WHITELIST_ACTION_STATUS="write_failed"
        LAST_WHITELIST_ACTION_MESSAGE="写入白名单失败"
        return 1
    fi

    LAST_WHITELIST_ACTION_STATUS="added"
    LAST_WHITELIST_ACTION_MESSAGE="已添加"
    return 0
}

append_whitelist_name() {
    local plugin_name="$1"

    add_whitelist_name_result "$plugin_name"

    case "$LAST_WHITELIST_ACTION_STATUS" in
        added)
            printf '[已添加] %s\n' "$(trim_spaces "$plugin_name")"
            return 0
            ;;
        exists)
            printf '[跳过] 白名单已存在：%s\n' "$(trim_spaces "$plugin_name")"
            return 0
            ;;
        invalid)
            printf '[跳过] %s：%s\n' "$LAST_WHITELIST_ACTION_MESSAGE" "$(trim_spaces "$plugin_name")"
            return 1
            ;;
        write_failed)
            printf '[失败] %s：%s\n' "$LAST_WHITELIST_ACTION_MESSAGE" "$(trim_spaces "$plugin_name")"
            return 1
            ;;
        *)
            printf '[失败] 白名单处理失败：%s\n' "$(trim_spaces "$plugin_name")"
            return 1
            ;;
    esac
}

remove_whitelist_name_result() {
    local target_name="$1"
    local temp_file="$WHITELIST_FILE.tmp.$$"
    local found=1
    local line=""

    LAST_WHITELIST_ACTION_STATUS=""
    LAST_WHITELIST_ACTION_MESSAGE=""

    target_name=$(trim_spaces "$target_name")
    if [ -z "$target_name" ]; then
        LAST_WHITELIST_ACTION_STATUS="invalid"
        LAST_WHITELIST_ACTION_MESSAGE="插件文件夹名不能为空"
        return 1
    fi

    ensure_data_files
    : > "$temp_file" || {
        LAST_WHITELIST_ACTION_STATUS="write_failed"
        LAST_WHITELIST_ACTION_MESSAGE="无法创建临时文件"
        return 1
    }

    while IFS= read -r line || [ -n "$line" ]; do
        line=$(trim_spaces "$line")
        [ -n "$line" ] || continue

        if [ "$line" = "$target_name" ] && [ "$found" -eq 1 ]; then
            found=0
            continue
        fi

        printf '%s\n' "$line" >> "$temp_file"
    done < "$WHITELIST_FILE"

    if ! mv "$temp_file" "$WHITELIST_FILE"; then
        rm -f -- "$temp_file"
        LAST_WHITELIST_ACTION_STATUS="write_failed"
        LAST_WHITELIST_ACTION_MESSAGE="写回白名单失败"
        return 1
    fi

    if [ "$found" -eq 0 ]; then
        LAST_WHITELIST_ACTION_STATUS="removed"
        LAST_WHITELIST_ACTION_MESSAGE="已移除"
        return 0
    fi

    LAST_WHITELIST_ACTION_STATUS="not_found"
    LAST_WHITELIST_ACTION_MESSAGE="白名单中不存在"
    return 1
}

remove_whitelist_name() {
    remove_whitelist_name_result "$1"

    case "$LAST_WHITELIST_ACTION_STATUS" in
        removed)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
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
        if ! array_contains "$item" "${PARSED_ITEMS[@]}"; then
            PARSED_ITEMS+=("$item")
        fi
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

json_escape() {
    local value="$1"

    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}

    printf '%s' "$value"
}

json_quote() {
    printf '"%s"' "$(json_escape "$1")"
}

json_bool() {
    case "$1" in
        1|true|TRUE|True)
            printf 'true'
            ;;
        *)
            printf 'false'
            ;;
    esac
}

json_null_or_string() {
    if [ -n "$1" ]; then
        json_quote "$1"
    else
        printf 'null'
    fi
}

json_print_string_array() {
    local array_name="$1"
    local -n array_ref="$array_name"
    local index=0

    printf '['
    for index in "${!array_ref[@]}"; do
        if [ "$index" -gt 0 ]; then
            printf ','
        fi
        json_quote "${array_ref[index]}"
    done
    printf ']'
}

json_print_raw_array() {
    local array_name="$1"
    local -n array_ref="$array_name"
    local index=0

    printf '['
    for index in "${!array_ref[@]}"; do
        if [ "$index" -gt 0 ]; then
            printf ','
        fi
        printf '%s' "${array_ref[index]}"
    done
    printf ']'
}

emit_json_error() {
    local command_name="$1"
    local code="$2"
    local message="$3"
    local details="$4"

    printf '{'
    printf '"ok":false,'
    printf '"command":%s,' "$(json_quote "$command_name")"
    printf '"error":{'
    printf '"code":%s,' "$(json_quote "$code")"
    printf '"message":%s,' "$(json_quote "$message")"
    printf '"details":%s' "$(json_null_or_string "$details")"
    printf '}'
    printf '}'
    printf '\n'
}

emit_settings_json_object() {
    printf '{'
    printf '"default_user_name":%s,' "$(json_quote "$(get_effective_default_user_name)")"
    printf '"default_st_root":%s,' "$(json_null_or_string "$CONFIG_DEFAULT_ST_ROOT")"
    printf '"effective_default_st_root":%s,' "$(json_quote "$(get_effective_default_st_root)")"
    printf '"auto_check_on_start":%s,' "$(json_bool "$AUTO_CHECK_ON_START")"
    printf '"config_file":%s,' "$(json_quote "$CONFIG_FILE")"
    printf '"whitelist_file":%s' "$(json_quote "$WHITELIST_FILE")"
    printf '}'
}

emit_context_json_object() {
    local third_party_dir=""
    local user_extensions_dir=""

    if [ -n "$ACTIVE_ST_ROOT" ] && [ -n "$ACTIVE_USER_NAME" ]; then
        third_party_dir="$ACTIVE_ST_ROOT/public/scripts/extensions/third-party"
        user_extensions_dir="$ACTIVE_ST_ROOT/data/$ACTIVE_USER_NAME/extensions"
    fi

    printf '{'
    printf '"st_root":%s,' "$(json_null_or_string "$ACTIVE_ST_ROOT")"
    printf '"user_name":%s,' "$(json_null_or_string "$ACTIVE_USER_NAME")"
    printf '"third_party_dir":%s,' "$(json_null_or_string "$third_party_dir")"
    printf '"user_extensions_dir":%s' "$(json_null_or_string "$user_extensions_dir")"
    printf '}'
}

build_basic_plugin_json_item() {
    local plugin_name="$1"
    local plugin_path="$2"
    local plugin_source="$3"
    local whitelisted_flag=0

    if is_whitelisted "$plugin_name"; then
        whitelisted_flag=1
    fi

    printf '{'
    printf '"name":%s,' "$(json_quote "$plugin_name")"
    printf '"source":%s,' "$(json_quote "$plugin_source")"
    printf '"path":%s,' "$(json_quote "$plugin_path")"
    printf '"whitelisted":%s' "$(json_bool "$whitelisted_flag")"
    printf '}'
}

build_last_plugin_json_item() {
    printf '{'
    printf '"name":%s,' "$(json_quote "$LAST_PLUGIN_NAME")"
    printf '"source":%s,' "$(json_quote "$LAST_PLUGIN_SOURCE")"
    printf '"path":%s,' "$(json_quote "$LAST_PLUGIN_PATH")"
    printf '"whitelisted":%s,' "$(json_bool "$LAST_PLUGIN_WHITELISTED")"
    printf '"status":%s,' "$(json_quote "$LAST_PLUGIN_STATUS")"
    printf '"reason":%s,' "$(json_quote "$LAST_PLUGIN_REASON")"
    printf '"remote":%s,' "$(json_null_or_string "$LAST_PLUGIN_REMOTE_NAME")"
    printf '"upstream":%s,' "$(json_null_or_string "$LAST_PLUGIN_UPSTREAM_REF")"
    printf '"local_ahead":%s,' "$LAST_PLUGIN_LOCAL_AHEAD"
    printf '"remote_ahead":%s' "$LAST_PLUGIN_REMOTE_AHEAD"
    printf '}'
}

reset_json_summary_counters() {
    SUMMARY_TOTAL=0
    SUMMARY_UPDATABLE=0
    SUMMARY_UP_TO_DATE=0
    SUMMARY_SKIPPED=0
    SUMMARY_FAILED=0
    SUMMARY_STATUS_UPDATE_AVAILABLE=0
    SUMMARY_STATUS_UPDATED=0
    SUMMARY_STATUS_UP_TO_DATE=0
    SUMMARY_STATUS_WHITELIST_SKIPPED=0
    SUMMARY_STATUS_NON_GIT=0
    SUMMARY_STATUS_NO_UPSTREAM=0
    SUMMARY_STATUS_REMOTE_UNREACHABLE=0
    SUMMARY_STATUS_UPDATE_FAILED=0
}

add_json_summary_status() {
    local status_value="$1"

    SUMMARY_TOTAL=$((SUMMARY_TOTAL + 1))

    case "$status_value" in
        update_available)
            SUMMARY_UPDATABLE=$((SUMMARY_UPDATABLE + 1))
            SUMMARY_STATUS_UPDATE_AVAILABLE=$((SUMMARY_STATUS_UPDATE_AVAILABLE + 1))
            ;;
        updated)
            SUMMARY_STATUS_UPDATED=$((SUMMARY_STATUS_UPDATED + 1))
            ;;
        up_to_date)
            SUMMARY_UP_TO_DATE=$((SUMMARY_UP_TO_DATE + 1))
            SUMMARY_STATUS_UP_TO_DATE=$((SUMMARY_STATUS_UP_TO_DATE + 1))
            ;;
        whitelist_skipped)
            SUMMARY_SKIPPED=$((SUMMARY_SKIPPED + 1))
            SUMMARY_STATUS_WHITELIST_SKIPPED=$((SUMMARY_STATUS_WHITELIST_SKIPPED + 1))
            ;;
        non_git)
            SUMMARY_SKIPPED=$((SUMMARY_SKIPPED + 1))
            SUMMARY_STATUS_NON_GIT=$((SUMMARY_STATUS_NON_GIT + 1))
            ;;
        no_upstream)
            SUMMARY_SKIPPED=$((SUMMARY_SKIPPED + 1))
            SUMMARY_STATUS_NO_UPSTREAM=$((SUMMARY_STATUS_NO_UPSTREAM + 1))
            ;;
        remote_unreachable)
            SUMMARY_SKIPPED=$((SUMMARY_SKIPPED + 1))
            SUMMARY_STATUS_REMOTE_UNREACHABLE=$((SUMMARY_STATUS_REMOTE_UNREACHABLE + 1))
            ;;
        update_failed)
            SUMMARY_FAILED=$((SUMMARY_FAILED + 1))
            SUMMARY_STATUS_UPDATE_FAILED=$((SUMMARY_STATUS_UPDATE_FAILED + 1))
            ;;
    esac
}

emit_status_summary_json_object() {
    printf '{'
    printf '"total":%s,' "$SUMMARY_TOTAL"
    printf '"updatable":%s,' "$SUMMARY_UPDATABLE"
    printf '"up_to_date":%s,' "$SUMMARY_UP_TO_DATE"
    printf '"skipped":%s,' "$SUMMARY_SKIPPED"
    printf '"failed":%s,' "$SUMMARY_FAILED"
    printf '"by_status":{'
    printf '"update_available":%s,' "$SUMMARY_STATUS_UPDATE_AVAILABLE"
    printf '"updated":%s,' "$SUMMARY_STATUS_UPDATED"
    printf '"up_to_date":%s,' "$SUMMARY_STATUS_UP_TO_DATE"
    printf '"whitelist_skipped":%s,' "$SUMMARY_STATUS_WHITELIST_SKIPPED"
    printf '"non_git":%s,' "$SUMMARY_STATUS_NON_GIT"
    printf '"no_upstream":%s,' "$SUMMARY_STATUS_NO_UPSTREAM"
    printf '"remote_unreachable":%s,' "$SUMMARY_STATUS_REMOTE_UNREACHABLE"
    printf '"update_failed":%s' "$SUMMARY_STATUS_UPDATE_FAILED"
    printf '}'
    printf '}'
}

emit_update_summary_json_object() {
    printf '{'
    printf '"checked":%s,' "$checked_count"
    printf '"updated":%s,' "$updated_count"
    printf '"up_to_date":%s,' "$no_update_count"
    printf '"skipped":%s,' "$skipped_count"
    printf '"failed":%s,' "$failed_count"
    printf '"skipped_details":'
    json_print_string_array SKIPPED_DETAILS
    printf ','
    printf '"failed_details":'
    json_print_string_array FAILED_DETAILS
    printf '}'
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
    local suggested_root=""

    suggested_root=$(get_effective_default_st_root)

    while :; do
        printf '未自动识别 SillyTavern 根目录，请输入路径（直接回车使用默认值：%s）：' "$suggested_root" >&2
        IFS= read -r manual_root

        if [ -z "$manual_root" ]; then
            selected_root="$suggested_root"
        else
            selected_root=$(normalize_path_value "$manual_root")
        fi

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
    local configured_root=""

    ACTIVE_ST_ROOT=""

    if [ -z "$input_st_root" ] && [ -n "$ST_ROOT" ]; then
        input_st_root="$ST_ROOT"
    fi

    if [ -n "$input_st_root" ]; then
        st_root=$(normalize_path_value "$input_st_root")

        if ! is_sillytavern_root "$st_root"; then
            printf '错误：指定的 SillyTavern 根目录无效：%s\n' "$st_root"
            printf '请确认该目录下能看到 public 和 data。\n'
            return 1
        fi

        printf '已使用指定的 SillyTavern 根目录：%s\n' "$st_root"
    else
        if [ -n "$CONFIG_DEFAULT_ST_ROOT" ]; then
            configured_root=$(get_effective_default_st_root)
            if is_sillytavern_root "$configured_root"; then
                st_root="$configured_root"
                printf '已使用设置中的 SillyTavern 根目录：%s\n' "$st_root"
            fi
        fi

        if [ -z "$st_root" ]; then
            st_root=$(detect_sillytavern_root)
            if [ -n "$st_root" ]; then
                printf '已自动识别 SillyTavern 根目录：%s\n' "$st_root"
            else
                st_root=$(prompt_for_st_root)
                printf '已使用手动输入的 SillyTavern 根目录：%s\n' "$st_root"
            fi
        fi
    fi

    ACTIVE_ST_ROOT="$st_root"
    return 0
}

resolve_st_root_noninteractive() {
    local input_st_root="$1"
    local st_root=""
    local configured_root=""

    ACTIVE_ST_ROOT=""

    if [ -z "$input_st_root" ] && [ -n "$ST_ROOT" ]; then
        input_st_root="$ST_ROOT"
    fi

    if [ -n "$input_st_root" ]; then
        st_root=$(normalize_path_value "$input_st_root")

        if ! is_sillytavern_root "$st_root"; then
            printf '自动检测更新已跳过：指定的 SillyTavern 根目录无效：%s\n' "$st_root"
            return 1
        fi
    else
        if [ -n "$CONFIG_DEFAULT_ST_ROOT" ]; then
            configured_root=$(get_effective_default_st_root)
            if is_sillytavern_root "$configured_root"; then
                st_root="$configured_root"
            fi
        fi

        if [ -z "$st_root" ]; then
            st_root=$(detect_sillytavern_root)
            if [ -z "$st_root" ]; then
                printf '自动检测更新已跳过：未自动识别到 SillyTavern 根目录。\n'
                return 1
            fi
        fi
    fi

    ACTIVE_ST_ROOT="$st_root"
    return 0
}

resolve_st_root_json() {
    local input_st_root="$1"
    local st_root=""
    local configured_root=""

    ACTIVE_ST_ROOT=""
    JSON_ERROR_CODE=""
    JSON_ERROR_MESSAGE=""
    JSON_ERROR_DETAILS=""

    if [ -z "$input_st_root" ] && [ -n "$ST_ROOT" ]; then
        input_st_root="$ST_ROOT"
    fi

    if [ -n "$input_st_root" ]; then
        st_root=$(normalize_path_value "$input_st_root")

        if ! is_sillytavern_root "$st_root"; then
            JSON_ERROR_CODE="invalid_root"
            JSON_ERROR_MESSAGE="指定的 SillyTavern 根目录无效"
            JSON_ERROR_DETAILS="$st_root"
            return 1
        fi
    else
        if [ -n "$CONFIG_DEFAULT_ST_ROOT" ]; then
            configured_root=$(get_effective_default_st_root)
            if is_sillytavern_root "$configured_root"; then
                st_root="$configured_root"
            fi
        fi

        if [ -z "$st_root" ]; then
            st_root=$(detect_sillytavern_root)
            if [ -z "$st_root" ]; then
                JSON_ERROR_CODE="root_not_found"
                JSON_ERROR_MESSAGE="未识别到 SillyTavern 根目录"
                JSON_ERROR_DETAILS=""
                return 1
            fi
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

resolve_user_name_json() {
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

prepare_context_json() {
    local input_st_root="$1"
    local input_user_name="$2"

    resolve_st_root_json "$input_st_root" || return 1
    resolve_user_name_json "$input_user_name" || return 1
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

require_git_quiet() {
    command -v git >/dev/null 2>&1
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

    if [ "${#summary}" -gt 160 ]; then
        summary="${summary:0:157}..."
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

reset_last_plugin_result() {
    LAST_PLUGIN_NAME=""
    LAST_PLUGIN_SOURCE=""
    LAST_PLUGIN_PATH=""
    LAST_PLUGIN_STATUS=""
    LAST_PLUGIN_REASON=""
    LAST_PLUGIN_REMOTE_NAME=""
    LAST_PLUGIN_UPSTREAM_REF=""
    LAST_PLUGIN_LOCAL_AHEAD=0
    LAST_PLUGIN_REMOTE_AHEAD=0
    LAST_PLUGIN_WHITELISTED=0
}

print_plugin_state_verbose() {
    local action_mode="$1"
    local repo_name="$LAST_PLUGIN_NAME"

    case "$LAST_PLUGIN_STATUS" in
        whitelist_skipped)
            printf '  -> [跳过] 命中白名单，已跳过更新检测\n\n'
            ;;
        non_git)
            printf '  -> [跳过] 不是 Git 仓库\n\n'
            ;;
        no_upstream)
            printf '  -> [跳过] Git 仓库未配置上游分支\n\n'
            ;;
        remote_unreachable)
            printf '  -> [跳过] %s\n\n' "$LAST_PLUGIN_REASON"
            ;;
        up_to_date)
            printf '  -> [无更新] %s\n\n' "$LAST_PLUGIN_REASON"
            ;;
        update_available)
            printf '  -> [可更新] %s\n\n' "$LAST_PLUGIN_REASON"
            ;;
        updated)
            printf '  -> [已更新] %s\n\n' "$LAST_PLUGIN_REASON"
            ;;
        update_failed)
            printf '  -> [失败] %s\n\n' "$LAST_PLUGIN_REASON"
            ;;
        *)
            printf '  -> [未知状态] %s：%s\n\n' "$repo_name" "$LAST_PLUGIN_REASON"
            ;;
    esac
}

record_update_summary_from_last_plugin() {
    local repo_display_name="${LAST_PLUGIN_NAME}（${LAST_PLUGIN_SOURCE}）"

    case "$LAST_PLUGIN_STATUS" in
        updated)
            updated_count=$((updated_count + 1))
            ;;
        up_to_date)
            no_update_count=$((no_update_count + 1))
            ;;
        whitelist_skipped|non_git|no_upstream|remote_unreachable)
            skipped_count=$((skipped_count + 1))
            record_skipped_detail "$repo_display_name" "$LAST_PLUGIN_REASON"
            ;;
        update_failed)
            failed_count=$((failed_count + 1))
            record_failed_detail "$repo_display_name" "$LAST_PLUGIN_REASON"
            ;;
    esac
}

inspect_plugin_state() {
    local repo_dir="$1"
    local source_label="$2"
    local action_mode="$3"
    local verbose_mode="$4"
    local repo_name=""
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

    reset_last_plugin_result

    repo_name=${repo_dir##*/}
    LAST_PLUGIN_NAME="$repo_name"
    LAST_PLUGIN_SOURCE="$source_label"
    LAST_PLUGIN_PATH="$repo_dir"
    checked_count=$((checked_count + 1))

    if [ "$verbose_mode" = "1" ]; then
        printf '[检查] %s\n' "$repo_name"
    fi

    if [ ! -d "$repo_dir" ]; then
        LAST_PLUGIN_STATUS="update_failed"
        LAST_PLUGIN_REASON="目录不存在"
        [ "$verbose_mode" = "1" ] && print_plugin_state_verbose "$action_mode"
        return 0
    fi

    if is_whitelisted "$repo_name"; then
        LAST_PLUGIN_WHITELISTED=1
        LAST_PLUGIN_STATUS="whitelist_skipped"
        LAST_PLUGIN_REASON="命中白名单"
        [ "$verbose_mode" = "1" ] && print_plugin_state_verbose "$action_mode"
        return 0
    fi

    if ! git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        LAST_PLUGIN_STATUS="non_git"
        LAST_PLUGIN_REASON="不是 Git 仓库"
        [ "$verbose_mode" = "1" ] && print_plugin_state_verbose "$action_mode"
        return 0
    fi

    upstream_ref=$(git -C "$repo_dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
    if [ -z "$upstream_ref" ]; then
        LAST_PLUGIN_STATUS="no_upstream"
        LAST_PLUGIN_REASON="未配置上游分支"
        [ "$verbose_mode" = "1" ] && print_plugin_state_verbose "$action_mode"
        return 0
    fi

    remote_name=${upstream_ref%%/*}
    LAST_PLUGIN_REMOTE_NAME="$remote_name"
    LAST_PLUGIN_UPSTREAM_REF="$upstream_ref"

    remote_check_output=$(git_non_interactive -C "$repo_dir" ls-remote --quiet "$remote_name" HEAD 2>&1)
    remote_check_status=$?
    if [ "$remote_check_status" -ne 0 ]; then
        if is_remote_access_issue "$remote_check_output"; then
            LAST_PLUGIN_STATUS="remote_unreachable"
            LAST_PLUGIN_REASON="远程不可访问（$(summarize_command_error "$remote_check_output")）"
        else
            LAST_PLUGIN_STATUS="update_failed"
            LAST_PLUGIN_REASON="无法访问远程仓库（$(summarize_command_error "$remote_check_output")）"
        fi
        [ "$verbose_mode" = "1" ] && print_plugin_state_verbose "$action_mode"
        return 0
    fi

    fetch_output=$(git_non_interactive -C "$repo_dir" fetch --all --prune 2>&1)
    fetch_status=$?
    if [ "$fetch_status" -ne 0 ]; then
        if is_remote_access_issue "$fetch_output"; then
            LAST_PLUGIN_STATUS="remote_unreachable"
            LAST_PLUGIN_REASON="远程不可访问（$(summarize_command_error "$fetch_output")）"
        else
            LAST_PLUGIN_STATUS="update_failed"
            LAST_PLUGIN_REASON="fetch 失败（$(summarize_command_error "$fetch_output")）"
        fi
        [ "$verbose_mode" = "1" ] && print_plugin_state_verbose "$action_mode"
        return 0
    fi

    counts=$(git -C "$repo_dir" rev-list --left-right --count "HEAD...$upstream_ref" 2>/dev/null)
    if [ -z "$counts" ]; then
        LAST_PLUGIN_STATUS="update_failed"
        LAST_PLUGIN_REASON="无法比较本地与远程差异"
        [ "$verbose_mode" = "1" ] && print_plugin_state_verbose "$action_mode"
        return 0
    fi

    set -- $counts
    local_ahead=$1
    remote_ahead=$2
    LAST_PLUGIN_LOCAL_AHEAD=$local_ahead
    LAST_PLUGIN_REMOTE_AHEAD=$remote_ahead

    if [ "$remote_ahead" -eq 0 ]; then
        LAST_PLUGIN_STATUS="up_to_date"
        if [ "$local_ahead" -gt 0 ]; then
            LAST_PLUGIN_REASON="远程没有新提交（本地领先 ${local_ahead} 个提交）"
        else
            LAST_PLUGIN_REASON="本地已是最新"
        fi
        [ "$verbose_mode" = "1" ] && print_plugin_state_verbose "$action_mode"
        return 0
    fi

    if [ "$action_mode" = "status" ]; then
        LAST_PLUGIN_STATUS="update_available"
        LAST_PLUGIN_REASON="远程领先 ${remote_ahead} 个提交"
        [ "$verbose_mode" = "1" ] && print_plugin_state_verbose "$action_mode"
        return 0
    fi

    pull_output=$(git_non_interactive -C "$repo_dir" pull --ff-only 2>&1)
    pull_status=$?
    if [ "$pull_status" -eq 0 ]; then
        LAST_PLUGIN_STATUS="updated"
        LAST_PLUGIN_REASON="已拉取远程更新（远程领先 ${remote_ahead} 个提交）"
    else
        if is_remote_access_issue "$pull_output"; then
            LAST_PLUGIN_STATUS="remote_unreachable"
            LAST_PLUGIN_REASON="拉取时远程不可访问（$(summarize_command_error "$pull_output")）"
        else
            LAST_PLUGIN_STATUS="update_failed"
            LAST_PLUGIN_REASON="pull 失败（$(summarize_command_error "$pull_output")）"
        fi
    fi

    [ "$verbose_mode" = "1" ] && print_plugin_state_verbose "$action_mode"
    return 0
}

process_plugin_update() {
    inspect_plugin_state "$1" "$2" "update" "1"
    record_update_summary_from_last_plugin
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

select_plugins_by_name_list() {
    local raw_names_csv="$1"
    local requested_name=""
    local index=0
    local found_for_name=0
    local missing_name=""

    SELECTED_PLUGIN_NAMES=()
    SELECTED_PLUGIN_PATHS=()
    SELECTED_PLUGIN_SOURCES=()
    JSON_MISSING_ITEMS=()

    split_csv_to_array "$raw_names_csv"
    if [ "${#PARSED_ITEMS[@]}" -eq 0 ]; then
        return 1
    fi

    for requested_name in "${PARSED_ITEMS[@]}"; do
        found_for_name=0
        for index in "${!PLUGIN_NAMES[@]}"; do
            if [ "${PLUGIN_NAMES[index]}" = "$requested_name" ]; then
                SELECTED_PLUGIN_NAMES+=("${PLUGIN_NAMES[index]}")
                SELECTED_PLUGIN_PATHS+=("${PLUGIN_PATHS[index]}")
                SELECTED_PLUGIN_SOURCES+=("${PLUGIN_SOURCES[index]}")
                found_for_name=1
            fi
        done

        if [ "$found_for_name" -eq 0 ]; then
            JSON_MISSING_ITEMS+=("$requested_name")
        fi
    done

    return 0
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

set_default_st_root_workflow() {
    local current_default_st_root=""
    local new_default_st_root=""
    local normalized_root=""

    current_default_st_root="$CONFIG_DEFAULT_ST_ROOT"

    if [ -n "$current_default_st_root" ]; then
        printf '当前默认根目录：%s\n' "$current_default_st_root"
    else
        printf '当前默认根目录：未设置（将自动检测）\n'
    fi

    printf '请输入新的 SillyTavern 根目录（输入 auto 或直接回车可清空设置并恢复自动检测）：'
    IFS= read -r new_default_st_root

    new_default_st_root=$(trim_spaces "$new_default_st_root")
    case "$new_default_st_root" in
        ""|auto|AUTO|Auto)
            CONFIG_DEFAULT_ST_ROOT=""
            save_config || return 1
            printf '已清空默认根目录，将恢复自动检测。\n'
            return 0
            ;;
    esac

    normalized_root=$(normalize_path_value "$new_default_st_root")
    if ! is_sillytavern_root "$normalized_root"; then
        printf '输入的目录看起来不是 SillyTavern 根目录：%s\n' "$normalized_root"
        printf '请确认该目录下能看到 public 和 data。\n'
        return 1
    fi

    CONFIG_DEFAULT_ST_ROOT="$normalized_root"
    save_config || return 1
    printf '已保存默认根目录：%s\n' "$CONFIG_DEFAULT_ST_ROOT"
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
                        remove_whitelist_name_result "$item"
                        case "$LAST_WHITELIST_ACTION_STATUS" in
                            removed)
                                printf '[已移除] %s\n' "$item"
                                ;;
                            not_found)
                                printf '[跳过] 白名单中不存在：%s\n' "$item"
                                ;;
                            invalid)
                                printf '[跳过] %s：%s\n' "$LAST_WHITELIST_ACTION_MESSAGE" "$item"
                                ;;
                            *)
                                printf '[失败] %s：%s\n' "$LAST_WHITELIST_ACTION_MESSAGE" "$item"
                                ;;
                        esac
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
    local root_status=""

    while :; do
        if [ "$AUTO_CHECK_ON_START" = "1" ]; then
            auto_status='已开启'
        else
            auto_status='已关闭'
        fi

        if [ -n "$CONFIG_DEFAULT_ST_ROOT" ]; then
            root_status="$CONFIG_DEFAULT_ST_ROOT"
        else
            root_status='未设置（自动检测）'
        fi

        printf '\n==== 设置 ====\n'
        printf '1. 默认用户名：%s\n' "$(get_effective_default_user_name)"
        printf '2. 默认 SillyTavern 根目录：%s\n' "$root_status"
        printf '3. 打开 Termux 时自动检测更新：%s\n' "$auto_status"
        printf '0. 返回\n'
        printf '请选择：'
        IFS= read -r menu_choice

        case "$menu_choice" in
            1)
                set_default_user_name_workflow || printf '保存默认用户名失败。\n'
                press_enter_to_continue
                ;;
            2)
                set_default_st_root_workflow || printf '保存默认根目录失败。\n'
                press_enter_to_continue
                ;;
            3)
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

json_plugins_list_command() {
    local index=0

    if ! prepare_context_json "$JSON_ST_ROOT" "$JSON_USER_NAME"; then
        emit_json_error "$JSON_COMMAND" "$JSON_ERROR_CODE" "$JSON_ERROR_MESSAGE" "$JSON_ERROR_DETAILS"
        return 1
    fi

    collect_plugins "$ACTIVE_ST_ROOT" "$ACTIVE_USER_NAME"

    printf '{'
    printf '"ok":true,'
    printf '"command":%s,' "$(json_quote "$JSON_COMMAND")"
    printf '"context":'
    emit_context_json_object
    printf ','
    printf '"plugins":['
    for index in "${!PLUGIN_NAMES[@]}"; do
        if [ "$index" -gt 0 ]; then
            printf ','
        fi
        build_basic_plugin_json_item "${PLUGIN_NAMES[index]}" "${PLUGIN_PATHS[index]}" "${PLUGIN_SOURCES[index]}"
    done
    printf ']'
    printf '}'
    printf '\n'
    return 0
}

json_status_command() {
    local index=0

    if ! require_git_quiet; then
        emit_json_error "$JSON_COMMAND" "git_missing" "未检测到 git" "请先安装 git"
        return 1
    fi

    if ! prepare_context_json "$JSON_ST_ROOT" "$JSON_USER_NAME"; then
        emit_json_error "$JSON_COMMAND" "$JSON_ERROR_CODE" "$JSON_ERROR_MESSAGE" "$JSON_ERROR_DETAILS"
        return 1
    fi

    collect_plugins "$ACTIVE_ST_ROOT" "$ACTIVE_USER_NAME"
    reset_update_stats
    reset_json_summary_counters
    JSON_RESULT_ITEMS=()

    for index in "${!PLUGIN_NAMES[@]}"; do
        inspect_plugin_state "${PLUGIN_PATHS[index]}" "${PLUGIN_SOURCES[index]}" "status" "0"
        add_json_summary_status "$LAST_PLUGIN_STATUS"
        JSON_RESULT_ITEMS+=("$(build_last_plugin_json_item)")
    done

    printf '{'
    printf '"ok":true,'
    printf '"command":%s,' "$(json_quote "$JSON_COMMAND")"
    printf '"context":'
    emit_context_json_object
    printf ','
    printf '"summary":'
    emit_status_summary_json_object
    printf ','
    printf '"plugins":'
    json_print_raw_array JSON_RESULT_ITEMS
    printf '}'
    printf '\n'
    return 0
}

json_update_all_command() {
    local index=0

    if ! require_git_quiet; then
        emit_json_error "$JSON_COMMAND" "git_missing" "未检测到 git" "请先安装 git"
        return 1
    fi

    if ! prepare_context_json "$JSON_ST_ROOT" "$JSON_USER_NAME"; then
        emit_json_error "$JSON_COMMAND" "$JSON_ERROR_CODE" "$JSON_ERROR_MESSAGE" "$JSON_ERROR_DETAILS"
        return 1
    fi

    collect_plugins "$ACTIVE_ST_ROOT" "$ACTIVE_USER_NAME"
    reset_update_stats
    reset_json_summary_counters
    JSON_RESULT_ITEMS=()

    for index in "${!PLUGIN_NAMES[@]}"; do
        inspect_plugin_state "${PLUGIN_PATHS[index]}" "${PLUGIN_SOURCES[index]}" "update" "0"
        record_update_summary_from_last_plugin
        add_json_summary_status "$LAST_PLUGIN_STATUS"
        JSON_RESULT_ITEMS+=("$(build_last_plugin_json_item)")
    done

    printf '{'
    printf '"ok":true,'
    printf '"command":%s,' "$(json_quote "$JSON_COMMAND")"
    printf '"context":'
    emit_context_json_object
    printf ','
    printf '"summary":'
    emit_update_summary_json_object
    printf ','
    printf '"status_overview":'
    emit_status_summary_json_object
    printf ','
    printf '"results":'
    json_print_raw_array JSON_RESULT_ITEMS
    printf '}'
    printf '\n'
    return 0
}

json_update_selected_command() {
    local index=0

    if [ -z "$JSON_PLUGIN_NAMES_CSV" ]; then
        emit_json_error "$JSON_COMMAND" "missing_plugins" "缺少 --plugins 参数" "请传入逗号分隔的插件目录名"
        return 1
    fi

    if ! require_git_quiet; then
        emit_json_error "$JSON_COMMAND" "git_missing" "未检测到 git" "请先安装 git"
        return 1
    fi

    if ! prepare_context_json "$JSON_ST_ROOT" "$JSON_USER_NAME"; then
        emit_json_error "$JSON_COMMAND" "$JSON_ERROR_CODE" "$JSON_ERROR_MESSAGE" "$JSON_ERROR_DETAILS"
        return 1
    fi

    collect_plugins "$ACTIVE_ST_ROOT" "$ACTIVE_USER_NAME"
    if ! select_plugins_by_name_list "$JSON_PLUGIN_NAMES_CSV"; then
        emit_json_error "$JSON_COMMAND" "invalid_plugins" "未传入有效的插件目录名" "$JSON_PLUGIN_NAMES_CSV"
        return 1
    fi

    reset_update_stats
    reset_json_summary_counters
    JSON_RESULT_ITEMS=()

    for index in "${!SELECTED_PLUGIN_NAMES[@]}"; do
        inspect_plugin_state "${SELECTED_PLUGIN_PATHS[index]}" "${SELECTED_PLUGIN_SOURCES[index]}" "update" "0"
        record_update_summary_from_last_plugin
        add_json_summary_status "$LAST_PLUGIN_STATUS"
        JSON_RESULT_ITEMS+=("$(build_last_plugin_json_item)")
    done

    printf '{'
    printf '"ok":true,'
    printf '"command":%s,' "$(json_quote "$JSON_COMMAND")"
    printf '"context":'
    emit_context_json_object
    printf ','
    printf '"requested_plugins":'
    json_print_string_array PARSED_ITEMS
    printf ','
    printf '"missing_plugins":'
    json_print_string_array JSON_MISSING_ITEMS
    printf ','
    printf '"summary":'
    emit_update_summary_json_object
    printf ','
    printf '"status_overview":'
    emit_status_summary_json_object
    printf ','
    printf '"results":'
    json_print_raw_array JSON_RESULT_ITEMS
    printf '}'
    printf '\n'
    return 0
}

json_whitelist_get_command() {
    read_whitelist_items

    printf '{'
    printf '"ok":true,'
    printf '"command":%s,' "$(json_quote "$JSON_COMMAND")"
    printf '"items":'
    json_print_string_array WHITELIST_ITEMS
    printf '}'
    printf '\n'
    return 0
}

json_whitelist_add_command() {
    local item=""
    local result_items=()

    if [ -z "$JSON_PLUGIN_NAMES_CSV" ]; then
        emit_json_error "$JSON_COMMAND" "missing_plugins" "缺少 --plugins 参数" "请传入逗号分隔的插件目录名"
        return 1
    fi

    split_csv_to_array "$JSON_PLUGIN_NAMES_CSV"
    if [ "${#PARSED_ITEMS[@]}" -eq 0 ]; then
        emit_json_error "$JSON_COMMAND" "invalid_plugins" "未传入有效的插件目录名" "$JSON_PLUGIN_NAMES_CSV"
        return 1
    fi

    result_items=()
    for item in "${PARSED_ITEMS[@]}"; do
        add_whitelist_name_result "$item"
        result_items+=("{\"name\":$(json_quote "$item"),\"status\":$(json_quote "$LAST_WHITELIST_ACTION_STATUS"),\"message\":$(json_quote "$LAST_WHITELIST_ACTION_MESSAGE")}")
    done

    read_whitelist_items

    printf '{'
    printf '"ok":true,'
    printf '"command":%s,' "$(json_quote "$JSON_COMMAND")"
    printf '"results":'
    json_print_raw_array result_items
    printf ','
    printf '"items":'
    json_print_string_array WHITELIST_ITEMS
    printf '}'
    printf '\n'
    return 0
}

json_whitelist_remove_command() {
    local item=""
    local result_items=()

    if [ -z "$JSON_PLUGIN_NAMES_CSV" ]; then
        emit_json_error "$JSON_COMMAND" "missing_plugins" "缺少 --plugins 参数" "请传入逗号分隔的插件目录名"
        return 1
    fi

    split_csv_to_array "$JSON_PLUGIN_NAMES_CSV"
    if [ "${#PARSED_ITEMS[@]}" -eq 0 ]; then
        emit_json_error "$JSON_COMMAND" "invalid_plugins" "未传入有效的插件目录名" "$JSON_PLUGIN_NAMES_CSV"
        return 1
    fi

    result_items=()
    for item in "${PARSED_ITEMS[@]}"; do
        remove_whitelist_name_result "$item"
        result_items+=("{\"name\":$(json_quote "$item"),\"status\":$(json_quote "$LAST_WHITELIST_ACTION_STATUS"),\"message\":$(json_quote "$LAST_WHITELIST_ACTION_MESSAGE")}")
    done

    read_whitelist_items

    printf '{'
    printf '"ok":true,'
    printf '"command":%s,' "$(json_quote "$JSON_COMMAND")"
    printf '"results":'
    json_print_raw_array result_items
    printf ','
    printf '"items":'
    json_print_string_array WHITELIST_ITEMS
    printf '}'
    printf '\n'
    return 0
}

json_settings_get_command() {
    printf '{'
    printf '"ok":true,'
    printf '"command":%s,' "$(json_quote "$JSON_COMMAND")"
    printf '"settings":'
    emit_settings_json_object
    printf '}'
    printf '\n'
    return 0
}

json_settings_save_command() {
    local normalized_root=""
    local shell_updated=0

    if [ "$JSON_DEFAULT_USER_NAME_SET" = "1" ]; then
        JSON_DEFAULT_USER_NAME=$(trim_spaces "$JSON_DEFAULT_USER_NAME")
        if [ -z "$JSON_DEFAULT_USER_NAME" ]; then
            CONFIG_DEFAULT_USER_NAME="$FALLBACK_USER_NAME"
        else
            CONFIG_DEFAULT_USER_NAME="$JSON_DEFAULT_USER_NAME"
        fi
    fi

    if [ "$JSON_DEFAULT_ST_ROOT_SET" = "1" ]; then
        JSON_DEFAULT_ST_ROOT=$(trim_spaces "$JSON_DEFAULT_ST_ROOT")
        if [ -z "$JSON_DEFAULT_ST_ROOT" ]; then
            CONFIG_DEFAULT_ST_ROOT=""
        else
            normalized_root=$(normalize_path_value "$JSON_DEFAULT_ST_ROOT")
            if ! is_sillytavern_root "$normalized_root"; then
                emit_json_error "$JSON_COMMAND" "invalid_root" "指定的 SillyTavern 根目录无效" "$normalized_root"
                return 1
            fi
            CONFIG_DEFAULT_ST_ROOT="$normalized_root"
        fi
    fi

    if [ "$JSON_AUTO_CHECK_ON_START_SET" = "1" ]; then
        case "$JSON_AUTO_CHECK_ON_START" in
            0|1)
                ;;
            *)
                emit_json_error "$JSON_COMMAND" "invalid_auto_check" "--auto-check-on-start 只能是 0 或 1" "$JSON_AUTO_CHECK_ON_START"
                return 1
                ;;
        esac

        if [ "$JSON_AUTO_CHECK_ON_START" = "1" ] && [ "$AUTO_CHECK_ON_START" != "1" ]; then
            if is_termux_environment; then
                enable_autostart_in_shell_files || {
                    emit_json_error "$JSON_COMMAND" "autostart_enable_failed" "开启自动检测更新失败" "无法写入 shell 启动文件"
                    return 1
                }
                shell_updated=1
            fi
            AUTO_CHECK_ON_START=1
        fi

        if [ "$JSON_AUTO_CHECK_ON_START" = "0" ] && [ "$AUTO_CHECK_ON_START" != "0" ]; then
            if is_termux_environment; then
                disable_autostart_in_shell_files || {
                    emit_json_error "$JSON_COMMAND" "autostart_disable_failed" "关闭自动检测更新失败" "无法修改 shell 启动文件"
                    return 1
                }
                shell_updated=1
            fi
            AUTO_CHECK_ON_START=0
        fi
    fi

    save_config || {
        emit_json_error "$JSON_COMMAND" "save_config_failed" "保存设置失败" "$CONFIG_FILE"
        return 1
    }

    printf '{'
    printf '"ok":true,'
    printf '"command":%s,' "$(json_quote "$JSON_COMMAND")"
    printf '"shell_updated":%s,' "$(json_bool "$shell_updated")"
    printf '"termux_environment":%s,' "$(json_bool "$(is_termux_environment && printf 1 || printf 0)")"
    printf '"settings":'
    emit_settings_json_object
    printf '}'
    printf '\n'
    return 0
}

json_delete_command() {
    local index=0
    local result_items=()
    local delete_path=""
    local delete_name=""
    local delete_source=""
    local deleted_count=0
    local delete_failed_local=0
    local delete_skipped_local=0

    if [ -z "$JSON_PLUGIN_NAMES_CSV" ]; then
        emit_json_error "$JSON_COMMAND" "missing_plugins" "缺少 --plugins 参数" "请传入逗号分隔的插件目录名"
        return 1
    fi

    if ! prepare_context_json "$JSON_ST_ROOT" "$JSON_USER_NAME"; then
        emit_json_error "$JSON_COMMAND" "$JSON_ERROR_CODE" "$JSON_ERROR_MESSAGE" "$JSON_ERROR_DETAILS"
        return 1
    fi

    collect_plugins "$ACTIVE_ST_ROOT" "$ACTIVE_USER_NAME"
    if ! select_plugins_by_name_list "$JSON_PLUGIN_NAMES_CSV"; then
        emit_json_error "$JSON_COMMAND" "invalid_plugins" "未传入有效的插件目录名" "$JSON_PLUGIN_NAMES_CSV"
        return 1
    fi

    result_items=()
    for index in "${!SELECTED_PLUGIN_NAMES[@]}"; do
        delete_name="${SELECTED_PLUGIN_NAMES[index]}"
        delete_path="${SELECTED_PLUGIN_PATHS[index]}"
        delete_source="${SELECTED_PLUGIN_SOURCES[index]}"

        if [ ! -e "$delete_path" ]; then
            delete_skipped_local=$((delete_skipped_local + 1))
            result_items+=("{\"name\":$(json_quote "$delete_name"),\"source\":$(json_quote "$delete_source"),\"path\":$(json_quote "$delete_path"),\"status\":\"not_found\",\"reason\":\"目录不存在\"}")
            continue
        fi

        rm -rf -- "$delete_path"
        if [ -e "$delete_path" ]; then
            delete_failed_local=$((delete_failed_local + 1))
            result_items+=("{\"name\":$(json_quote "$delete_name"),\"source\":$(json_quote "$delete_source"),\"path\":$(json_quote "$delete_path"),\"status\":\"delete_failed\",\"reason\":\"删除失败\"}")
        else
            deleted_count=$((deleted_count + 1))
            result_items+=("{\"name\":$(json_quote "$delete_name"),\"source\":$(json_quote "$delete_source"),\"path\":$(json_quote "$delete_path"),\"status\":\"deleted\",\"reason\":\"已删除\"}")
        fi
    done

    printf '{'
    printf '"ok":true,'
    printf '"command":%s,' "$(json_quote "$JSON_COMMAND")"
    printf '"context":'
    emit_context_json_object
    printf ','
    printf '"requested_plugins":'
    json_print_string_array PARSED_ITEMS
    printf ','
    printf '"missing_plugins":'
    json_print_string_array JSON_MISSING_ITEMS
    printf ','
    printf '"summary":{'
    printf '"deleted":%s,' "$deleted_count"
    printf '"failed":%s,' "$delete_failed_local"
    printf '"skipped":%s' "$delete_skipped_local"
    printf '},'
    printf '"results":'
    json_print_raw_array result_items
    printf '}'
    printf '\n'
    return 0
}

run_json_command() {
    case "$JSON_COMMAND" in
        plugins-list)
            json_plugins_list_command
            ;;
        status|overview)
            json_status_command
            ;;
        update-all)
            json_update_all_command
            ;;
        update-selected)
            json_update_selected_command
            ;;
        whitelist-get)
            json_whitelist_get_command
            ;;
        whitelist-add)
            json_whitelist_add_command
            ;;
        whitelist-remove)
            json_whitelist_remove_command
            ;;
        settings-get)
            json_settings_get_command
            ;;
        settings-save)
            json_settings_save_command
            ;;
        delete)
            json_delete_command
            ;;
        *)
            emit_json_error "$JSON_COMMAND" "unknown_command" "未知 JSON 命令" "$JSON_COMMAND"
            return 1
            ;;
    esac
}

parse_json_mode() {
    shift

    if [ "$#" -eq 0 ]; then
        emit_json_error "" "missing_command" "缺少 JSON 命令" "请在 --json 后指定命令名"
        return 1
    fi

    JSON_COMMAND="$1"
    shift

    JSON_ST_ROOT=""
    JSON_USER_NAME=""
    JSON_PLUGIN_NAMES_CSV=""
    JSON_DEFAULT_USER_NAME=""
    JSON_DEFAULT_ST_ROOT=""
    JSON_AUTO_CHECK_ON_START=""
    JSON_DEFAULT_USER_NAME_SET=0
    JSON_DEFAULT_ST_ROOT_SET=0
    JSON_AUTO_CHECK_ON_START_SET=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --st-root)
                if [ "$#" -lt 2 ]; then
                    emit_json_error "$JSON_COMMAND" "missing_argument" "--st-root 缺少参数值" ""
                    return 1
                fi
                JSON_ST_ROOT="$2"
                shift 2
                ;;
            --user-name)
                if [ "$#" -lt 2 ]; then
                    emit_json_error "$JSON_COMMAND" "missing_argument" "--user-name 缺少参数值" ""
                    return 1
                fi
                JSON_USER_NAME="$2"
                shift 2
                ;;
            --plugins)
                if [ "$#" -lt 2 ]; then
                    emit_json_error "$JSON_COMMAND" "missing_argument" "--plugins 缺少参数值" ""
                    return 1
                fi
                JSON_PLUGIN_NAMES_CSV="$2"
                shift 2
                ;;
            --default-user-name)
                if [ "$#" -lt 2 ]; then
                    emit_json_error "$JSON_COMMAND" "missing_argument" "--default-user-name 缺少参数值" ""
                    return 1
                fi
                JSON_DEFAULT_USER_NAME="$2"
                JSON_DEFAULT_USER_NAME_SET=1
                shift 2
                ;;
            --default-st-root)
                if [ "$#" -lt 2 ]; then
                    emit_json_error "$JSON_COMMAND" "missing_argument" "--default-st-root 缺少参数值" ""
                    return 1
                fi
                JSON_DEFAULT_ST_ROOT="$2"
                JSON_DEFAULT_ST_ROOT_SET=1
                shift 2
                ;;
            --auto-check-on-start)
                if [ "$#" -lt 2 ]; then
                    emit_json_error "$JSON_COMMAND" "missing_argument" "--auto-check-on-start 缺少参数值" ""
                    return 1
                fi
                JSON_AUTO_CHECK_ON_START="$2"
                JSON_AUTO_CHECK_ON_START_SET=1
                shift 2
                ;;
            *)
                emit_json_error "$JSON_COMMAND" "unknown_argument" "未知参数" "$1"
                return 1
                ;;
        esac
    done

    run_json_command
}

print_help() {
    printf '用法：\n'
    printf '  bash %s                # 打开交互式管理面板\n' "$SCRIPT_NAME"
    printf '  bash %s <根目录> <用户名>\n' "$SCRIPT_NAME"
    printf '  bash %s --run-update [根目录] [用户名]\n' "$SCRIPT_NAME"
    printf '  bash %s --auto-start-check [根目录] [用户名]\n' "$SCRIPT_NAME"
    printf '  bash %s --json <命令> [参数]\n' "$SCRIPT_NAME"
    printf '\nJSON 命令：\n'
    printf '  plugins-list / status / update-all / update-selected\n'
    printf '  whitelist-get / whitelist-add / whitelist-remove\n'
    printf '  settings-get / settings-save / delete\n'
    printf '\n说明：\n'
    printf '  - 脚本依赖 bash 运行。\n'
    printf '  - Termux 和电脑上的 Git Bash / WSL 都可使用。\n'
    printf '  - “打开 Termux 时自动检测更新”只在 Termux 下生效。\n'
    printf '  - Web 面板请通过 JSON 命令模式调用，不要解析终端文案。\n'
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
    --json)
        parse_json_mode "$@"
        ;;
    "")
        main_menu
        ;;
    *)
        run_update_flow 1 "$1" "$2"
        ;;
esac

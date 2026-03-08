ge#!/data/data/com.termux/files/usr/bin/sh
#
# update_sillytavern_extensions_termux.sh
#
# 用法：
#   chmod +x ./update_sillytavern_extensions_termux.sh
#   ./update_sillytavern_extensions_termux.sh
#
# 也可选传：
#   ./update_sillytavern_extensions_termux.sh <SillyTavern根目录> <用户目录名>
#
# 环境变量同样可用：
#   ST_ROOT=/path/to/SillyTavern ST_USER_NAME=default-user sh ./update_sillytavern_extensions_termux.sh

DEFAULT_ST_ROOT="$HOME/SillyTavern"
DEFAULT_USER_NAME="default-user"

checked_count=0
updated_count=0
no_update_count=0
skipped_count=0
failed_count=0

expand_home_path() {
    input_path=$1

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
    path_value=$1

    while [ "$path_value" != "/" ] && [ "${path_value%/}" != "$path_value" ]; do
        path_value=${path_value%/}
    done

    printf '%s\n' "$path_value"
}

is_sillytavern_root() {
    root_path=$1

    [ -n "$root_path" ] || return 1
    [ -d "$root_path" ] || return 1
    [ -d "$root_path/public" ] || return 1
    [ -d "$root_path/data" ] || return 1
    [ -d "$root_path/public/scripts/extensions" ] || return 1

    return 0
}

find_root_in_ancestors() {
    start_path=$1

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

        current_path=$parent_path
    done

    return 1
}

detect_sillytavern_root() {
    current_dir=$(pwd 2>/dev/null)
    if [ -n "$current_dir" ]; then
        detected_root=$(find_root_in_ancestors "$current_dir")
        if [ -n "$detected_root" ]; then
            printf '%s\n' "$detected_root"
            return 0
        fi
    fi

    script_dir=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)
    if [ -n "$script_dir" ]; then
        detected_root=$(find_root_in_ancestors "$script_dir")
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
    while :; do
        printf '未自动识别 SillyTavern 根目录，请输入路径（直接回车使用默认值：%s）：' "$DEFAULT_ST_ROOT"
        IFS= read -r manual_root

        if [ -z "$manual_root" ]; then
            selected_root=$DEFAULT_ST_ROOT
        else
            selected_root=$(expand_home_path "$manual_root")
        fi

        selected_root=$(trim_trailing_slash "$selected_root")

        if is_sillytavern_root "$selected_root"; then
            printf '%s\n' "$selected_root"
            return 0
        fi

        printf '输入的目录看起来不是 SillyTavern 根目录：%s\n' "$selected_root"
        printf '请确认该目录下能看到 public 和 data。\n\n'
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

scan_extensions_dir() {
    base_dir=$1
    label=$2

    printf '\n==== 扫描目录：%s ====\n' "$label"
    printf '%s\n\n' "$base_dir"

    if [ ! -d "$base_dir" ]; then
        printf '[总目录不存在] 已跳过：%s\n' "$base_dir"
        return
    fi

    for repo_dir in "$base_dir"/*; do
        if [ ! -e "$repo_dir" ]; then
            printf '[目录为空] %s 下没有可检查的子目录\n' "$base_dir"
            return
        fi

        [ -d "$repo_dir" ] || continue

        repo_name=${repo_dir##*/}
        checked_count=$((checked_count + 1))

        printf '[检查] %s\n' "$repo_name"

        if ! git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            skipped_count=$((skipped_count + 1))
            printf '  -> [跳过] 不是 Git 仓库\n\n'
            continue
        fi

        upstream_ref=$(git -C "$repo_dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
        if [ -z "$upstream_ref" ]; then
            skipped_count=$((skipped_count + 1))
            printf '  -> [跳过] Git 仓库未配置上游分支\n\n'
            continue
        fi

        remote_name=${upstream_ref%%/*}
        remote_check_output=$(git_non_interactive -C "$repo_dir" ls-remote --quiet "$remote_name" HEAD 2>&1)
        remote_check_status=$?
        if [ "$remote_check_status" -ne 0 ]; then
            if is_remote_access_issue "$remote_check_output"; then
                skipped_count=$((skipped_count + 1))
                printf '  -> [跳过] 远程仓库不可访问（可能已转私有 / 不存在 / 需要认证）\n'
            else
                failed_count=$((failed_count + 1))
                printf '  -> [失败] 无法访问远程仓库\n'
            fi
            printf '%s\n\n' "$remote_check_output"
            continue
        fi

        fetch_output=$(git_non_interactive -C "$repo_dir" fetch --all --prune 2>&1)
        fetch_status=$?
        if [ "$fetch_status" -ne 0 ]; then
            if is_remote_access_issue "$fetch_output"; then
                skipped_count=$((skipped_count + 1))
                printf '  -> [跳过] 远程仓库不可访问（可能已转私有 / 不存在 / 需要认证）\n'
            else
                failed_count=$((failed_count + 1))
                printf '  -> [失败] fetch 失败\n'
            fi
            printf '%s\n\n' "$fetch_output"
            continue
        fi

        counts=$(git -C "$repo_dir" rev-list --left-right --count "HEAD...$upstream_ref" 2>/dev/null)
        if [ -z "$counts" ]; then
            failed_count=$((failed_count + 1))
            printf '  -> [失败] 无法比较本地与远程差异\n\n'
            continue
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
            continue
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
                printf '  -> [跳过] 拉取时远程仓库不可访问（可能已转私有 / 不存在 / 需要认证）\n'
            else
                failed_count=$((failed_count + 1))
                printf '  -> [失败] pull 失败\n'
            fi
            printf '%s\n\n' "$pull_output"
        fi
    done
}

if ! command -v git >/dev/null 2>&1; then
    printf '错误：未检测到 git，请先在 Termux 中安装 git。\n'
    printf '可执行：pkg install git\n'
    exit 1
fi

input_st_root=$1
input_user_name=$2

if [ -z "$input_st_root" ] && [ -n "$ST_ROOT" ]; then
    input_st_root=$ST_ROOT
fi

if [ -z "$input_user_name" ] && [ -n "$ST_USER_NAME" ]; then
    input_user_name=$ST_USER_NAME
fi

if [ -n "$input_st_root" ]; then
    st_root=$(expand_home_path "$input_st_root")
    st_root=$(trim_trailing_slash "$st_root")

    if ! is_sillytavern_root "$st_root"; then
        printf '错误：指定的 SillyTavern 根目录无效：%s\n' "$st_root"
        printf '请确认该目录下能看到 public 和 data。\n'
        exit 1
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

if [ -n "$input_user_name" ]; then
    user_name=$input_user_name
    printf '已使用指定的用户目录名：%s\n' "$user_name"
else
    printf '请输入用户目录名（直接回车使用默认值：%s）：' "$DEFAULT_USER_NAME"
    IFS= read -r input_user_name

    if [ -z "$input_user_name" ]; then
        user_name=$DEFAULT_USER_NAME
    else
        user_name=$input_user_name
    fi
fi

third_party_dir="$st_root/public/scripts/extensions/third-party"
user_extensions_dir="$st_root/data/$user_name/extensions"

printf '\n将按顺序检查以下扩展目录：\n'
printf '1) %s\n' "$third_party_dir"
printf '2) %s\n' "$user_extensions_dir"

scan_extensions_dir "$third_party_dir" "第三方扩展目录"
scan_extensions_dir "$user_extensions_dir" "用户扩展目录"

printf '\n==== 汇总统计 ====\n'
printf 'SillyTavern 根目录：%s\n' "$st_root"
printf '用户目录名：%s\n' "$user_name"
printf '已检查子目录：%s\n' "$checked_count"
printf '已更新仓库：%s\n' "$updated_count"
printf '无更新仓库：%s\n' "$no_update_count"
printf '已跳过项目：%s\n' "$skipped_count"
printf '失败项目数：%s\n' "$failed_count"

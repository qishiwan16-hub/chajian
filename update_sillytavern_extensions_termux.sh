#!/data/data/com.termux/files/usr/bin/sh
#
# update_sillytavern_extensions_termux.sh
#
# 用法：
#   chmod +x ./update_sillytavern_extensions_termux.sh
#   ./update_sillytavern_extensions_termux.sh
#
# 或者直接用 shell 执行：
#   sh ./update_sillytavern_extensions_termux.sh
#
# 脚本作用：
#   1. 提示输入 SillyTavern 根目录，回车时默认使用 $HOME/SillyTavern
#   2. 提示输入用户目录名，回车时默认使用 default-user
#   3. 依次扫描以下两个扩展总目录下的“直接子目录”：
#      - public/scripts/extensions/third-party
#      - data/<用户名>/extensions
#   4. 如果子目录是 Git 仓库，则执行 fetch + pull 检查并更新
#   5. 如果不是 Git 仓库，或仓库未配置上游分支，则跳过并提示
#   6. 最后输出本次批量检查的统计结果
#
# 依赖：
#   - git

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

        fetch_output=$(git -C "$repo_dir" fetch --all --prune 2>&1)
        fetch_status=$?
        if [ "$fetch_status" -ne 0 ]; then
            failed_count=$((failed_count + 1))
            printf '  -> [失败] fetch 失败\n'
            printf '%s\n\n' "$fetch_output"
            continue
        fi

        upstream_ref=$(git -C "$repo_dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
        if [ -z "$upstream_ref" ]; then
            skipped_count=$((skipped_count + 1))
            printf '  -> [跳过] Git 仓库未配置上游分支\n\n'
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

        pull_output=$(git -C "$repo_dir" pull --ff-only 2>&1)
        pull_status=$?
        if [ "$pull_status" -eq 0 ]; then
            updated_count=$((updated_count + 1))
            printf '  -> [已更新] 已拉取远程更新（远程领先 %s 个提交）\n' "$remote_ahead"
            if [ -n "$pull_output" ]; then
                printf '%s\n' "$pull_output"
            fi
            printf '\n'
        else
            failed_count=$((failed_count + 1))
            printf '  -> [失败] pull 失败\n'
            printf '%s\n\n' "$pull_output"
        fi
    done
}

if ! command -v git >/dev/null 2>&1; then
    printf '错误：未检测到 git，请先在 Termux 中安装 git。\n'
    printf '可执行：pkg install git\n'
    exit 1
fi

printf '请输入 SillyTavern 根目录（直接回车使用默认值：%s）：' "$DEFAULT_ST_ROOT"
IFS= read -r input_st_root

if [ -z "$input_st_root" ]; then
    st_root=$DEFAULT_ST_ROOT
else
    st_root=$(expand_home_path "$input_st_root")
fi

st_root=$(trim_trailing_slash "$st_root")

printf '请输入用户目录名（直接回车使用默认值：%s）：' "$DEFAULT_USER_NAME"
IFS= read -r input_user_name

if [ -z "$input_user_name" ]; then
    user_name=$DEFAULT_USER_NAME
else
    user_name=$input_user_name
fi

third_party_dir="$st_root/public/scripts/extensions/third-party"
user_extensions_dir="$st_root/data/$user_name/extensions"

printf '\n将按顺序检查以下扩展目录：\n'
printf '1) %s\n' "$third_party_dir"
printf '2) %s\n' "$user_extensions_dir"

scan_extensions_dir "$third_party_dir" "第三方扩展目录"
scan_extensions_dir "$user_extensions_dir" "用户扩展目录"

printf '\n==== 汇总统计 ====\n'
printf '已检查子目录：%s\n' "$checked_count"
printf '已更新仓库：%s\n' "$updated_count"
printf '无更新仓库：%s\n' "$no_update_count"
printf '已跳过项目：%s\n' "$skipped_count"
printf '失败项目数：%s\n' "$failed_count"

# SillyTavern 扩展管理脚本

用于在 Termux 中管理和更新 SillyTavern 扩展，也可在电脑上用 `bash` 运行基础功能。当前项目同时提供了一个本地轻量 Web 面板：后端使用 Python 标准库，前端使用原生 HTML / CSS / JS，底层仍由 Bash 脚本执行真实插件操作。

## 快速开始

先安装 Git，然后拉取本项目：

```sh
git clone https://github.com/qishiwan16-hub/chajian.git
cd chajian
```

### 依赖

- Git
- Bash（Termux 可直接安装；桌面端推荐 Git Bash）
- Python 3（仅 Web 面板需要，使用标准库，无需额外 `pip install`）

Termux 里建议先安装 Git：

```sh
pkg install git
```

### CLI 菜单启动

进入项目目录后，直接执行：

```sh
bash ./update_sillytavern_extensions_termux.sh
```

启动后会直接进入脚本面板，输入对应数字即可进入功能。

### Web 面板启动

在项目目录执行：

```sh
python web_panel_server.py
```

默认监听地址为 `http://127.0.0.1:8765` 。如果需要，也可以通过 `--host`、`--port`、`--timeout`、`--bash` 调整监听参数、脚本超时和 Bash 路径。

Web 面板核心能力：

- 顶部概览统计卡片
- 插件列表、搜索、状态筛选、来源筛选
- 批量选择、批量更新、全量更新
- 单插件更新、白名单加入/移除、删除插件
- 设置默认用户名、默认 SillyTavern 根目录、Termux 自动检测更新
- 友好名按“元数据 → 映射文件 → 目录名”回退

前端只消费后端 JSON，不解析终端文本输出。

## 菜单功能

默认启动后会进入管理面板，输入对应数字即可进入对应功能：

1. 一键更新
2. 批量更新脚本
3. 白名单管理
4. 插件查看
5. 删除插件
6. 设置
0. 退出

## 一键更新

会按顺序检查这两个目录：

1. `public/scripts/extensions/third-party`
2. `data/<用户目录名>/extensions`

保留原有更新规则：

- 只检查子目录中的 Git 仓库
- 无更新就跳过
- 有更新就拉取
- 私有仓库、仓库失效、需要认证时自动跳过
- 单个插件失败不会中断整轮更新
- 最后输出统计

如果插件文件夹名在白名单中，会直接跳过检测，并显示白名单跳过原因。

## 批量更新脚本

“批量更新脚本”会先列出和“插件查看”一致的插件列表，包含：

- `public/scripts/extensions/third-party`
- `data/<用户名>/extensions`

然后输入要更新的序号即可，支持：

- 单个序号
- 多个序号
- 逗号分隔批量更新

输入多个序号时，会严格按你输入的顺序依次更新。

如果输入为空、序号非法、超出范围或重复，脚本会给出提示并跳过，不会中断后续项。
批量更新结束后，也会输出本次更新统计，以及跳过项目列表、失败项目列表。

## 白名单管理

白名单按“插件文件夹名”匹配。

可以在面板里：

- 查看当前白名单
- 添加插件名
- 移除插件名

白名单会保存在脚本同目录，下次运行仍然有效。

## 插件查看

会优先使用设置中的默认用户名，也可以直接回车继续。

然后列出两个目录下的所有插件：

- `public/scripts/extensions/third-party`
- `data/<用户名>/extensions`

列表中会显示：

- 序号
- 插件名
- 来源（`public` / `user`）

## 删除插件

“删除插件”会先列出和“插件查看”一致的完整插件列表。

然后你可以输入序号删除，支持：

- 单个序号
- 多个序号
- 逗号分隔批量删除

删除前会再次要求输入 `y` 确认，避免误删。

删除结果会统计成功、失败、跳过数量；非法序号、重复序号、目录不存在都不会让脚本崩掉。

## 设置

目前支持：

- 默认用户名
- 默认 SillyTavern 根目录
- 打开 Termux 时自动检测更新

### 默认用户名

设置后，更新、插件查看、删除插件时都会优先使用这个用户名，直接回车即可继续。

### 默认 SillyTavern 根目录

设置后，CLI 和 Web 面板都会优先使用这个根目录查找扩展；未设置时仍会按原有逻辑自动检测。

### 打开 Termux 时自动检测更新

开启后，脚本会在 Termux 常见启动文件里写入带标记的启动块；关闭时会自动移除这段启动块。

自动启动时不会进入菜单，而是直接执行更新流程；如果没识别到 SillyTavern 根目录或缺少必要条件，会安全跳过，不会卡住。

这个自动启动逻辑只在 Termux 下生效；在电脑上运行脚本时，不会去改你本机的 shell 启动文件。

## JSON / 命令模式

如果你明确想跳过交互面板，也可以直接执行命令模式。

### 直接执行更新

```sh
bash ./update_sillytavern_extensions_termux.sh --run-update
```

### JSON 模式示例

```sh
bash ./update_sillytavern_extensions_termux.sh --json settings-get
bash ./update_sillytavern_extensions_termux.sh --json whitelist-get
bash ./update_sillytavern_extensions_termux.sh --json overview
bash ./update_sillytavern_extensions_termux.sh --json update-selected --plugins ext-a,ext-b
```

当前 JSON 模式已覆盖：

- 插件列表 / 概览状态
- 全量更新 / 指定目录名批量更新
- 白名单查看 / 添加 / 移除
- 删除插件
- 设置读取 / 保存

`--auto-start-check` 仍仅供“打开 Termux 时自动检测更新”功能内部使用。

## 补充说明

如果你在手动下载或安装插件时遇到“插件已安装”之类的提示，常见原因是当前扩展目录里已经存在同名插件文件夹。

这时建议先：

- 先用面板里的“插件查看”确认是否已有同名目录
- 如果确认是旧目录、重复目录或装错目录，可先用“删除插件”删掉旧目录
- 再重新下载或安装目标插件

## 说明

- 用户目录名默认是 `default-user`
- 脚本依赖 `bash`
- Termux 可直接使用
- 电脑上可用 Git Bash / WSL 运行脚本本体
- “打开 Termux 时自动检测更新”这一项设计目标仍是 Termux

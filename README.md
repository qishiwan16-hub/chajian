# SillyTavern 扩展管理脚本

用于在 Termux 中管理和更新 SillyTavern 扩展，也可在电脑上用 `bash` 运行基础功能。

## 使用

先安装 Git，然后拉取本项目：

```sh
git clone https://github.com/qishiwan16-hub/chajian.git
cd chajian
```

Termux 里建议先安装 Git：

```sh
pkg install git
```

脚本现在要求用 `bash` 启动：

```sh
chmod +x ./update_sillytavern_extensions_termux.sh
bash ./update_sillytavern_extensions_termux.sh
```

也可以直接执行更新：

```sh
bash ./update_sillytavern_extensions_termux.sh --run-update
```

## 菜单功能

运行后会进入管理面板：

1. 一键更新
2. 白名单管理
3. 插件查看
4. 删除插件
5. 设置
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
- 实际路径

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
- 打开 Termux 时自动检测更新

### 默认用户名

设置后，更新、插件查看、删除插件时都会优先使用这个用户名，直接回车即可继续。

### 打开 Termux 时自动检测更新

开启后，脚本会在 Termux 常见启动文件里写入带标记的启动块；关闭时会自动移除这段启动块。

自动启动时不会进入菜单，而是直接执行更新流程；如果没识别到 SillyTavern 根目录或缺少必要条件，会安全跳过，不会卡住。

这个自动启动逻辑只在 Termux 下生效；在电脑上运行脚本时，不会去改你本机的 shell 启动文件。

## 说明

- 用户目录名默认是 `default-user`
- 脚本依赖 `bash`
- Termux 可直接使用
- 电脑上可用 Git Bash / WSL 运行脚本本体
- “打开 Termux 时自动检测更新”这一项设计目标仍是 Termux

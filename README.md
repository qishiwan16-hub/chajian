# Termux 下批量更新 SillyTavern 扩展

用于在 Termux 中一键检查并更新 SillyTavern 的第三方扩展和用户扩展。

## 直接使用

如果还没安装 Git，先执行：

```sh
pkg install git
```

拉取本项目：

```sh
git clone https://github.com/qishiwan16-hub/chajian.git
cd chajian
```

赋予执行权限：

```sh
chmod +x ./update_sillytavern_extensions_termux.sh
```

运行脚本：

```sh
./update_sillytavern_extensions_termux.sh
```

如果不想赋予执行权限，也可以直接运行：

```sh
sh ./update_sillytavern_extensions_termux.sh
```

## 运行时会让你输入什么

### 1. SillyTavern 根目录
- 脚本会先自动识别常见路径
- 识别到了就直接使用，不用输入
- 没识别到时会提示你手动输入
- 直接回车会使用默认值：`~/SillyTavern`

### 2. 用户目录名
- 默认值是 `default-user`
- 大多数情况直接回车即可
- 只有你自己改过用户目录名时才需要输入

## 这个脚本会更新哪里

脚本会按顺序检查这两个扩展目录：

1. `public/scripts/extensions/third-party`
2. `data/<用户目录名>/extensions`

只要子目录本身是 Git 仓库，脚本就会检查并拉取更新。

## 运行结果怎么看

运行过程中常见提示：

- `[无更新]`：本地已经是最新
- `[已更新]`：已经成功拉取远程更新
- `[跳过]`：不是 Git 仓库，或没有配置上游分支
- `[失败]`：这个扩展更新失败，但脚本会继续检查下一个

最后会输出汇总统计，重点看这几项：

- `已更新仓库`
- `无更新仓库`
- `已跳过项目`
- `失败项目数`

## 常见问题

### 1. 提示没找到 Git
先执行：

```sh
pkg install git
```

### 2. 不知道用户目录名填什么
没改过就直接回车，使用默认值 `default-user`。

### 3. 为什么有些扩展被跳过
通常是因为那个目录不是 Git 仓库，或者没有配置上游分支。

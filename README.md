# Termux 下批量更新 SillyTavern 扩展

## 这是什么

[`update_sillytavern_extensions_termux.sh`](update_sillytavern_extensions_termux.sh) 是一个给 Termux 用的批量更新脚本。

它会按顺序检查这两个目录下的扩展子目录：

- `public/scripts/extensions/third-party`
- `data/<用户名>/extensions`

如果子目录本身是 Git 仓库，就自动检查远程更新；有更新就拉取，没更新就跳过；单个仓库失败也不会中断整个过程，最后会输出统计结果。

## 如何获取并使用脚本（最稳妥）

如果你的 Termux 还没装 Git，先执行：

```sh
pkg install git
```

### 情况 A：文件已经在本地

如果你已经把这个脚本文件放到本地了，就**不要重复 `git clone`**，直接进入脚本所在目录即可：

```sh
cd chajian
```

> 如果你的本地目录名不是 `chajian`，把上面命令里的目录名改成你自己的实际目录名。

### 情况 B：本地还没有文件，再执行一次 `git clone`

```sh
git clone https://github.com/你的用户名/你的仓库名.git
cd 你的仓库目录名
```

注意：

- 上面的仓库地址只是**示例格式**，请替换成你自己的**真实仓库地址**。
- `git clone` 这一行结尾**不能多任何字符**，尤其不能多 `~`。
- 也就是说，命令应当在 `.git` 处结束，不要写成 `...git~`、`...git。`、`...git/` 之类。
- 如果你已经在本地拿到了脚本，就跳过这一步，直接进入脚本目录运行。

### 运行脚本

给脚本执行权限：

```sh
chmod +x ./update_sillytavern_extensions_termux.sh
```

运行：

```sh
./update_sillytavern_extensions_termux.sh
```

不想赋权也可以直接这样运行：

```sh
sh ./update_sillytavern_extensions_termux.sh
```

## 你图里的报错是什么意思

你图里执行的是类似下面这种命令：

```sh
git clone https://github.com/qishiwan16-hub/chajian.git~
```

这里最后多了一个 `~`，Git 会把它当成仓库地址的一部分，也就是去找 `chajian.git~` 这个仓库，所以才会出现“仓库不存在 / URL not found”。

正确写法应当是：

```sh
git clone https://github.com/你的用户名/你的仓库名.git
```

或者，如果文件已经在本地，就不要重新 `clone`，直接进入目录后运行脚本。

## 运行时需要输入什么

脚本已经尽量做了简化：

1. **SillyTavern 根目录**
   - 脚本会先尝试自动识别常见路径。
   - 识别到了就直接使用，不用你输入。
   - 只有识别不到时，才会提示你手动输入。
   - 手动输入时，直接回车会使用默认值：`~/SillyTavern`

2. **用户目录名**
   - 默认值是 `default-user`
   - 大多数情况直接回车即可
   - 只有你自己改过用户目录名时，才需要手动输入

## 结果怎么看

运行过程中你会看到下面几类结果：

- `[无更新]`：这个扩展已经是最新
- `[已更新]`：这个扩展已经成功拉取更新
- `[跳过]`：不是 Git 仓库，或者没有配置上游分支
- `[失败]`：这个扩展更新失败，但脚本会继续检查下一个

最后会输出汇总统计，大致像这样：

```text
==== 汇总统计 ====
SillyTavern 根目录：/data/data/com.termux/files/home/SillyTavern
用户目录名：default-user
已检查子目录：10
已更新仓库：3
无更新仓库：4
已跳过项目：2
失败项目数：1
```

看 `已更新仓库`、`无更新仓库`、`已跳过项目`、`失败项目数` 这几项就够了。

## 常见问题

### 1. 提示没找到 Git

先执行：

```sh
pkg install git
```

### 2. 为什么会跳过某些扩展

通常是因为那个文件夹不是 Git 仓库，或者仓库没有配置上游分支。这种情况脚本不会强行处理。

### 3. 自动识别不到 SillyTavern 根目录怎么办

手动输入 SillyTavern 根目录即可。这个目录里通常能看到 `public` 和 `data`。

### 4. 用户目录名填什么

没改过就直接回车，用默认值 `default-user`。

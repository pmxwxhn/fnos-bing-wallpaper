# 飞牛 fnOS Bing 每日壁纸

让飞牛 fnOS 的**登录页**和**桌面背景**每天自动换成 Bing 每日壁纸。

不装 Docker，不改系统组件，一个脚本 + 一条定时任务搞定。换完可随时一键还原。

> ### 关于出处
>
> 本项目的思路来自 **[playGitboy/fnOS_wallpaper_diy](https://github.com/playGitboy/fnOS_wallpaper_diy)**
> （作者 [@playGitboy](https://github.com/playGitboy)）。
> 原项目最早验证了「替换 `wallpaper-1.webp` + `chattr` 锁防止系统还原」这条路可行，
> 本项目的核心思路直接受益于它，**感谢原作者**。
>
> 本项目**不是原项目的 fork**，而是独立重写：原项目只做「换成指定图片」，
> 本项目在其思路基础上增加了 Bing 每日抓取、ffmpeg 转码、幂等控制、
> 一键安装器和自动备份恢复，并修正了 chattr 的处理方式（详见下文「工作原理」）。
>
> 如果你觉得这个项目有用，也请去给[原仓库](https://github.com/playGitboy/fnOS_wallpaper_diy)点个 Star。

---

## 效果

每天早上 7:00（可自定义），你的飞牛登录页和桌面背景会变成当天的 Bing 首页图，
通常是一张 4K 风景照，附带 Bing 编辑的选图说明。

```
今天：泛舟如画秋林 —— 五彩落羽杉间划船的人们，宣城，安徽省，中国
```

> 飞牛的桌面壁纸和登录页壁纸**共用同一个文件** `wallpaper-1.webp`，
> 所以换一次两处同时生效，不需要分别设置。

## 特性

- 每天自动更换，取自 Bing 官方每日图片接口，4K 原图
- 自动转码为 webp，大图 2560 宽、缩略图 350 宽，体积比原图更小
- 同一天不会重复替换（幂等），失败自动重试
- 首次替换前自动备份系统原图，随时可还原
- 不依赖 Docker、不需要图形界面、不需要改数据库
- 支持换回任意自己的图片（jpg / png / webp / gif）

## 要求

- 飞牛 fnOS（在 1.2.0800 上验证，理论兼容其他版本）
- 已开启 SSH，能 `sudo`
- 系统自带 `curl`、`ffmpeg`（飞牛默认都有）
- 设备能访问 `cn.bing.com`

## 安装

### 方式一：一键脚本（推荐）

SSH 登录到飞牛，执行：

```bash
curl -fsSL https://raw.githubusercontent.com/pmxwxhn/fnos-bing-wallpaper/main/install.sh | sudo bash
```

### 方式二：下载压缩包

把压缩包传到飞牛，解压后执行：

```bash
tar -xzf fnos-bing-wallpaper.tar.gz
cd fnos-bing-wallpaper
sudo ./install.sh
```

自定义每天的更换时间：

```bash
sudo ./install.sh --time 06:30    # 每天早上 6:30
```

装完刷新浏览器（F5）就能看到效果。

## 使用

```bash
# 立即换一张（不用等定时任务）
sudo bing-wallpaper-daily.sh --force

# 只下载不修改系统（试运行）
sudo bing-wallpaper-daily.sh --dry-run

# 查看当前壁纸状态
sudo fnos-wallpaper-set.sh --status

# 换回飞牛系统原始壁纸
sudo fnos-wallpaper-set.sh --restore

# 换成本地任意图片
sudo fnos-wallpaper-set.sh /vol1/1000/图片.jpg

# 调整画质（默认 2560 宽 / 质量 85）
sudo WALLPAPER_WIDTH=3840 WALLPAPER_QUALITY=92 bing-wallpaper-daily.sh --force

# 换成其他地区的 Bing 每日图
sudo BING_MARKET=en-US bing-wallpaper-daily.sh --force

# 查看日志
tail -f /var/log/fnos-bing-wallpaper.log
```

## 卸载

```bash
sudo ./install.sh --uninstall
```

会恢复系统原始壁纸、删除脚本和定时任务。壁纸缓存和备份保留在
`/var/lib/fnos-wallpaper`，确认不需要可手动 `rm -rf`。

## 工作原理

飞牛的登录页背景是 `/usr/trim/www/static/bg/wallpaper-1.webp`，
桌面壁纸在数据库里指向同一个路径（`trim_sac.user_preference.single_photo_wp_id = 1`
→ `wallpaper` 表 `id=1` → `/static/bg/wallpaper-1.webp`）。

所以整个方案就是：**每天把这个文件换成 Bing 当天的图**。

看起来简单，但踩了三个坑，这也是本项目存在的原因：

### 坑 1：系统会在几秒内把壁纸还原

替换后约 5–8 秒，文件就被守护进程改回原图，大小和 md5 完全一致。
必须给目标文件加 `chattr +a`（append-only）锁住。

参考的原项目 [fnOS_wallpaper_diy](https://github.com/playGitboy/fnOS_wallpaper_diy)
会把 `/usr/bin/chattr` 永久改名成 `chattrx` 来阻止系统解锁，且改完不恢复。
实测发现**没有必要**：只要文件锁上了，即使把 chattr 名字恢复，文件也不会被改动。
所以本项目不动系统工具。

### 坑 2：ffmpeg 写不进 `/usr/trim/www`

`touch`、`cp`、`vipsthumbnail` 都能写，唯独 `ffmpeg` 打开输出文件报 `ENOENT`。
所以脚本先转码到 `/tmp`，再用 `cp` 拷进去。

### 坑 3：替换过程不能有间隙

如果先换大图、再慢慢转码缩略图、最后统一加锁，中间那几秒无锁的窗口里，
守护进程会把整个 `static` 目录重建，导致后续 `cp` 报「目录不存在」，已换的图也被还原。

解决办法：**两张图先全部转码到 `/tmp`，再逐张「解锁 → cp → 立刻上锁」**，
无锁窗口只有一次 `cp` 的时间。

### 其他细节

- nginx 对壁纸返回 `cache-control: no-cache`，所以换完 F5 即可，不用清缓存
- 原始备份存在 `/var/lib/fnos-wallpaper/orig/`，不能存在壁纸同目录（会被守护进程清理）
- 幂等标记按 Bing 的 `startdate` 判断，同一天重复运行不会重复下载

## 常见问题

**Q：刷新后壁纸没变？**

按 `Ctrl+Shift+R` 强制刷新。如果还不行，关掉标签页重新打开飞牛。
桌面是单页应用，有时会复用已渲染的画面。

**Q：会不会影响系统升级？**

壁纸文件带 append-only 属性，大版本升级时若需覆盖可能失败。
**升级前建议先执行 `sudo fnos-wallpaper-set.sh --restore`** 恢复原始壁纸，
升级完定时任务会自动换回来。

**Q：定时任务没生效？**

```bash
systemctl status cron              # 确认 cron 在跑
cat /etc/cron.d/fnos-bing-wallpaper  # 确认任务存在
tail -20 /var/log/fnos-bing-wallpaper.log
```

飞牛基于 Debian，`/etc/cron.d` 由 cron 服务加载，文件属主必须是 root。

**Q：想同时保留原来的系统壁纸怎么办？**

安装时已经自动备份了，`--restore` 随时可回退。

**Q：会不会有安全风险？**

脚本只做三件事：下载图片、转码、替换 `wallpaper-1.webp` + 加文件锁。
不联网上报、不改数据库、不改系统配置、不开端口。全部源码都在本仓库，可自行审阅。

## 文件说明

| 文件 | 说明 |
|---|---|
| `install.sh` | 安装 / 卸载脚本 |
| `scripts/bing-wallpaper-daily.sh` | 抓取 Bing 每日图并应用（cron 调用这个） |
| `scripts/fnos-wallpaper-set.sh` | 实际替换壁纸的底层脚本 |
| `README.md` | 本文档 |

运行时产生的文件：

| 路径 | 说明 |
|---|---|
| `/usr/local/sbin/bing-wallpaper-daily.sh` | 主脚本 |
| `/usr/local/sbin/fnos-wallpaper-set.sh` | 壁纸设置脚本 |
| `/etc/cron.d/fnos-bing-wallpaper` | 定时任务 |
| `/var/lib/fnos-wallpaper/wallpapers/` | 下载的原图缓存（保留最近 7 张） |
| `/var/lib/fnos-wallpaper/orig/` | **系统原始壁纸备份，勿删** |
| `/var/log/fnos-bing-wallpaper.log` | 运行日志 |

## 致谢与出处

### 原作者

**[@playGitboy](https://github.com/playGitboy)** ——
项目 [fnOS_wallpaper_diy](https://github.com/playGitboy/fnOS_wallpaper_diy)
（自动更换飞牛 fnOS 登录页面背景壁纸）

本项目**继承的核心思路**来自原项目：

- 飞牛登录页背景文件是 `/usr/trim/www/static/bg/wallpaper-1.webp`，替换它即可换背景
- 系统会把文件重置回默认，需要用 `chattr` 给文件加锁才能保住
- 大图和缩略图（`thumbnail_bg/`）需要一起换

### 本项目的改动

| 方面 | 原项目 | 本项目 |
|---|---|---|
| 图片来源 | 手动指定一张图 | 自动抓取 Bing 每日 4K 图 |
| 图片格式 | 直接拷贝，扩展名可能与实际格式不符 | 用 ffmpeg 转成真正的 webp |
| 依赖 | 需要 ImageMagick（`convert`） | 用系统自带的 ffmpeg，无需额外安装 |
| chattr 处理 | 把 `/usr/bin/chattr` **永久改名**为 `chattrx`，不恢复 | 只临时解锁/加锁，**不改名系统工具** |
| 定时更换 | 无 | 内置 cron，每天自动换 |
| 幂等 | 无 | 同一张图不重复处理 |
| 备份恢复 | 同目录 `.bak`（会被守护进程清理） | 备份到 `/var/lib/`，可靠可恢复 |
| 安装方式 | 手动下载 + `chmod +x` | 一条命令安装 / 卸载 |

### 关于许可证

**原项目未声明开源许可证**（仓库中没有 LICENSE 文件，README 也未提及授权方式）。
因此：

- 本项目的代码是**独立重写实现**，不是对原项目源码的复制或改造
- 原项目中的具体代码文本未在本项目中使用
- 本项目自身以 MIT 协议发布（见 [LICENSE](LICENSE)）
- 如原作者对署名方式有异议，欢迎提 Issue 联系调整

### 其他

- Bing 每日壁纸版权归 Microsoft 及图片原作者所有，本项目仅抓取其公开接口
  用于个人设备的登录页背景，不做二次分发
- 感谢飞牛 fnOS 提供开放的静态资源结构

## 许可

MIT

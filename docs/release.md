# Morning Mist 版本与发布

Morning Mist 的版本号怎么定、如何发布桌面安装包，以及已安装的应用如何拿到更新。应用侧检查、下载、校验和安装流程见 [auto-update.md](auto-update.md)。

- 桌面安装包与更新清单：GitHub Releases，`zt15242/Morning-mist`
- 远程内核下载：仍由 `https://dl.baocode.dev` 提供
- 构建与发布：GitHub Actions，`.github/workflows/build-release.yml`
- 工具：`tool/bump_version.dart`、`tool/build_macos.dart`、`tool/build_windows.dart`、`tool/build_remote_server.dart`、`tool/release_manifest.dart`

## 目录

1. [发布流程](#1-发布流程)
2. [版本号](#2-版本号)
3. [发一个版本](#3-发一个版本)
4. [CI 做了什么](#4-ci-做了什么)
5. [GitHub Release 与远程服务端](#5-github-release-与远程服务端)
6. [更新的数据流](#6-更新的数据流)
7. [第一次发布前的准备](#7-第一次发布前的准备)
8. [出了问题](#8-出了问题)
9. [不用 CI，手动发布](#9-不用-ci手动发布)
10. [手机版](#10-手机版)
11. [浏览器扩展](#11-浏览器扩展)

---

## 1. 发布流程

```
本地提交                         GitHub Actions                     GitHub Releases
────────                         ───────────────                     ──────────────
 tool/bump_version.dart
 改版本号、更新说明
 git push v* 标签 ─────────▶ build-release.yml
                               ├ remote   构建桌面包所需的远程内核
                               ├ macos    DMG + 更新用 ZIP
                               ├ windows  安装 EXE
                               └ release  签名 latest.json，先上传安装包，最后上传清单
                                                                          │
已安装的 Morning Mist ─────── GET releases/latest/download/latest.json ◀──┘
                               校验 SHA-256 + Ed25519，再下载并安装
```

- **更新清单最后上传**：Release 先有 DMG、ZIP 和 EXE，最后才上传 `latest.json`；检查更新的客户端不会读到尚未就绪的包。
- **签名密钥**：从 GitHub Environment `release` 的 `UPDATE_SIGNING_KEY` secret 读取；正式标签发布或从 `main` 明确发起的手动发布会使用它，可再用 Environment 审批和分支/标签规则限制访问。
- **远程内核独立**：`dl.baocode.dev` 仍用于远程内核的构建产物，不再作为桌面安装包或更新清单来源。

## 2. 版本号

**写法**：`主.次.修订+build`，例如 `1.2.0+12`。写在两处，必须一样（`test/update/version_test.dart` 会检查，CI 也会检查）：

- `pubspec.yaml`：`version: 1.2.0+12`
- `lib/update/version.dart`：`const appVersionString = '1.2.0+12';`

**规则**

- `主.次.修订` 是给人看的版本（marketing 版本），按 semver：修 bug 加修订号，加功能加次版本号，不兼容的大改加主版本号。
- `+build` 是给机器比较的序号，**每次发布都加 1，永远不回退**。应用只接受比自己新的版本（先比 `主.次.修订`，再比 build），build 号没涨，用户就收不到。
- **标签**：`v` + marketing 版本，例如 `v1.2.0`。CI 会核对标签和 pubspec.yaml 是否一致。
- **同一个版本可以重新发布**（比如发出去才发现包有问题，修好后把标签挪到新提交上重推，见第 3 节）。下载链接末尾带着文件哈希（`?sha256=<前 16 位>`），重新发布后是新的地址，CDN 不会给出旧文件。但已经装上这个版本的用户不会再收到它（版本号没变），所以只适合还没人装上、或者问题不影响已装用户的时候；否则发 `1.2.1`。
- **预发布版**（`1.2.0-beta.1`）目前不支持：只有一个更新渠道，所有用户读同一份 `latest.json`，发 beta 就是发给所有人。以后要做的话见 [auto-update.md 第 13 节](auto-update.md#13-已知限制与待办)。

**改版本号用工具**，两处一起改，build 号自动加 1：

```sh
dart run tool/bump_version.dart patch    # 1.2.0+12 → 1.2.1+13
dart run tool/bump_version.dart minor    # 1.2.0+12 → 1.3.0+13
dart run tool/bump_version.dart major    # 1.2.0+12 → 2.0.0+13
dart run tool/bump_version.dart 1.4.0    # 1.2.0+12 → 1.4.0+13
```

**更新日志**：`release-notes/<版本>.en.md` 和 `release-notes/<版本>.zh.md`，是应用内更新说明的来源，不另外维护 CHANGELOG.md。它们会出现在：

- `latest.json`：设置 → 更新里显示（纯文本，按应用语言选）
- GitHub Release 的说明（英文那份）；更新通知里的“更新日志”按钮打开对应 Release
- 网站更新日志页（若仍维护）：由 `tool/build_changelog.dart` 生成，与桌面应用的自动更新流程分开

`bump_version.dart` 会顺手生成草稿（`tool/draft_release_notes.dart`，也可以单独跑）：上一个标签以来的 `feat` / `perf` / `fix` 提交标题，分到「New / Improved / Fixed」（中文「新功能 / 改进 / 修复」）下面，不含 `site`、`ci` 的提交。提交标题是写给开发者的，**草稿要改写成用户看得懂的话**，每版十行左右，中文那份写中文。格式只用普通段落和 `-` 列表：设置页按纯文本显示，标题、加粗之类的 Markdown 符号会原样露出来。

没有 notes 也能发，但 CI 会给出警告：通知里没有「更新日志」按钮，网站上也没有这个版本，GitHub Release 改用自动生成的提交列表。`test/tool/build_changelog_test.dart` 会检查网站页面是不是最新的。

## 3. 发一个版本

以发布 `1.2.0` 为例：

```sh
dart run tool/bump_version.dart minor          # 1.1.3+12 → 1.2.0+13，并生成更新日志草稿
# 改写 release-notes/1.2.0.en.md、release-notes/1.2.0.zh.md
dart run tool/build_changelog.dart             # 生成网站的更新日志页
flutter test test/update/version_test.dart test/tool/build_changelog_test.dart
git add pubspec.yaml lib/update/version.dart release-notes/ site/changelog.html site/zh/changelog.html
git commit -m "chore: release 1.2.0"
git push origin main
git tag v1.2.0
git push origin v1.2.0                          # 从这里开始 CI 接手
```

然后在 GitHub 的 Actions → Build Morning Mist Installers 里看进度（如果给 `release` 环境设了审批人，要点一下 Approve）。macOS 公证要等几分钟，整个流程大约 20～30 分钟。

完成后确认：

- [ ] `https://github.com/zt15242/Morning-mist/releases/latest/download/latest.json` 返回新版本和三种桌面更新资产
- [ ] 最新 GitHub Release 附有 `latest.json`、两个 macOS DMG/ZIP 和 Windows 安装程序
- [ ] 装着旧版本的机器上点“检查更新”，能发现、下载、重启装上

**重新发布同一个版本**（标签挪到新提交上）：

```sh
git push origin :refs/tags/v1.2.0                # 删掉远端的标签
git tag -f v1.2.0 && git push origin v1.2.0      # 打在现在的提交上，重新推
```

CI 会照常构建并覆盖同一 GitHub Release 的资产；`latest.json` 在安装包更新完成后最后上传。

**只想试一下构建**：Actions → Build Morning Mist Installers → Run workflow，并将 `create_release` 设为 `false`。构建产物保存在该次运行的 Artifacts 中，不会创建 Release 或更新清单。

**单独发布远程服务端**：在要发的提交上打一个 `server-` 开头的标签并推送：

```sh
git tag server-1.0.7-ssh-fix && git push origin server-1.0.7-ssh-fix
```

`.github/workflows/remote.yml` 编译四个平台的服务端、在 macOS 和 Docker 里的 Linux 上各跑一遍，然后把 `.gz` 和 `servers.json` 传到 `releases/remote/<VERSION>/`，最后更新 `releases/remote/latest.json`（指向这份）。不构建应用、不动应用的 `latest.json`，已安装的应用不受影响。用途是**本机打的包**：本机编出来的服务端 `VERSION` 和 CI 的对不上，线上没有，连主机会报 404；打包时改用已发布的那份：

```sh
dart run tool/build_windows.dart --remote-release            # 最新发布的服务端
dart run tool/build_windows.dart --remote-release <VERSION>  # 指定的那份
dart run tool/build_macos.dart --remote-release              # macOS 同理
```

脚本用 `tool/fetch_remote_server.dart` 取 `servers.json`、确认每个 `.gz` 都能下载，放进 `build/remote-release/` 再打包。应用和服务端是严格一一对应的内部协议（docs/ssh-remote.md），**服务端要从和应用相同（至少 `packages/bao_remote` 相同）的提交发布**，否则连上后可能出错。正式发版（`v*`）也会传 `servers.json`、更新 `releases/remote/latest.json`。

**发布官网**：和应用发版无关，推送到 `main` 就由 Cloudflare Workers Builds 部署到 baocode.dev（GitHub 上这个提交的检查里有“Workers Builds: baocode”）。

- 先预览：推送任何别的分支，Workers Builds 只上传一个预览版本、不上线。预览地址是 `https://<版本 ID 前 8 位>-baocode.leokun-cn.workers.dev`，版本 ID 在那个提交的“Workers Builds: baocode”检查详情里。
- 只发官网：把 `site/` 的改动单独提交推到 `main` 即可，`main` 上没发版的应用代码不受影响（应用只在推 `v*` 标签时发布）。

## 4. CI 做了什么

`.github/workflows/build-release.yml`，推送 `v*` 标签时运行：

| Job | 机器 | 做什么 |
| --- | --- | --- |
| `remote` | macOS 15 | 构建应用内置的远程内核，并上传给 macOS/Windows 构建任务使用 |
| `macos` | macOS 15 | 构建 Apple silicon 与 Intel 应用，生成 DMG 和用于自动更新的 ZIP |
| `windows` | Windows | 构建并生成 Inno Setup 安装程序 |
| `release` | Ubuntu | 汇总安装包；使用 `release` 环境的 `UPDATE_SIGNING_KEY` 签出 `latest.json`；创建 GitHub Release 并上传安装包，最后上传更新清单 |

几个设计上的考虑：

- **`latest.json` 最后上传**：所有更新资产进入 Release 后才上传清单，避免应用拿到尚未发布的包。
- **下载链接带哈希**：每个资产 URL 带 SHA-256 前 16 位；应用下载后仍校验完整 SHA-256 和 Ed25519 签名。
- **Release 标签**：资产链接按 `v<pubspec marketing version>` 生成；工作流会拒绝与应用版本不匹配的 `v*` 标签。
- **密钥只在 `release` 环境里**：普通分支 push 不会运行发布任务；正式标签或显式选择 `create_release` 的手动运行才会使用它。可在 Environment 中设置审批人和允许的分支/标签。
- Flutter 版本固定在工作流中，升级 Flutter 时一起改。

## 5. GitHub Release 与远程服务端

桌面更新清单和安装包位于 `zt15242/Morning-mist` 的 GitHub Releases。每个 `v<版本>` Release 包含：

```
latest.json
Morning-Mist-1.2.0-setup.exe
Morning-Mist-1.2.0-arm64.dmg
Morning-Mist-1.2.0-x64.dmg
Morning-Mist-1.2.0-mac-arm64.zip
Morning-Mist-1.2.0-mac-x64.zip
```

- 应用读取 `https://github.com/zt15242/Morning-mist/releases/latest/download/latest.json`，包链接只接受该仓库的 versioned Release assets。
- `dl.baocode.dev` 仍保存远程内核二进制；远程主机仍在使用旧版本时，不要删除对应的内核文件。

## 6. 更新的数据流

**发布时**（CI 的 `release`）：

1. 对每个平台的安装包算 SHA-256，用 Ed25519 私钥签 `baocode-update-v1 / 版本 / 平台 / 大小 / SHA-256` 这段文本。
2. 写出 `latest.json`：版本、日期、更新说明、每个平台的 `url / size / sha256 / signature`。
3. GitHub Release 先附加安装包和 DMG，最后附加 `latest.json`。

**已安装的应用**（`update.mode` 是默认的“自动检查并下载”时）：

1. 启动 10 秒后、之后每 5 分钟，GET `https://github.com/zt15242/Morning-mist/releases/latest/download/latest.json`。
2. 解析清单；下载链接必须是该仓库的 HTTPS Release 资产。版本不比自己新，或者没有本平台的条目 → 已是最新，结束。
3. 后台下载本平台的安装包（Mac 按处理器取 Apple silicon 或 Intel 的包，见 [auto-update.md 5.2](auto-update.md#52-latestjson-格式)）到 `<数据目录>/updates/<版本>/`，支持断点续传。
4. 依次校验大小 → SHA-256 → Ed25519 签名（公钥内置在应用里）。任何一项不过就删掉，报错。macOS 还会检查新 .app 的 bundle id，以及在当前应用有正式签名时，新 .app 是不是同一个 Team 签的。
5. 主窗口右下角弹通知。用户点“立即重启更新”后，走和平时退出一样的确认（未保存的文件、运行中的 agent 和终端），确认了才安装：
   - Windows：应用退出后，带 `/SILENT /RELAUNCH` 运行新的 setup.exe，覆盖安装到原来的位置，再重新打开。
   - macOS：解压出新 .app，等应用退出后由脚本替换原来的 Morning Mist.app，再打开。
6. 新版本启动时清理 `updates/` 里旧版本的下载。

设置和对话放在数据目录里，不在安装目录里，更新不会动它们。

手动更新入口打开 GitHub 最新 Release；该页面提供 Windows 安装程序与 macOS DMG。`latest.json` 中的本地化更新说明显示在应用设置页。

**两把“钥匙”管的是不同的事**：

| | 防的是什么 | 没有它会怎样 |
| --- | --- | --- |
| 更新签名私钥（Ed25519） | 有人替换 GitHub Release 中的安装包或清单，给用户推送恶意更新 | 发不了更新；泄露的话，后果见 [auto-update.md 6.3](auto-update.md#63-保管) |
| Apple Developer ID + 公证 | macOS 的 Gatekeeper 拦截从网上下载的未知应用 | 用户第一次打开 dmg 里的应用时被拦：“已损坏，无法打开” |
| Windows 代码签名（还没做） | SmartScreen 的“未知发布者”警告 | 第一次安装时多点一次“仍要运行” |

自动更新只依赖第一把：应用自己下载的文件不带隔离属性，不经过 Gatekeeper 和 SmartScreen。

## 7. 第一次发布前的准备

GitHub 更新发布只需配置签名密钥。Cloudflare 仍可能被网站或远程内核服务使用，但不再是桌面安装包和更新清单的发布目标。后台密钥不要发到聊天里，也不要提交到仓库。

### 7.1 Cloudflare

1. **R2 存储桶**：R2 → Create bucket，名字比如 `baocode-downloads`。
2. **自定义域名**：存储桶 → Settings → Custom Domains → Connect Domain → `dl.baocode.dev`。不要开 `r2.dev` 公共地址。
3. **CORS**（给下载页读 `latest.json`）：存储桶 → Settings → CORS Policy：
   ```json
   [
     {
       "AllowedOrigins": ["https://baocode.dev"],
       "AllowedMethods": ["GET", "HEAD"],
       "AllowedHeaders": ["*"],
       "MaxAgeSeconds": 3600
     }
   ]
   ```
4. **API 令牌**：R2 → Manage R2 API Tokens → Create API token，权限 **Object Read & Write**，范围**只选这个存储桶**。记下 Access Key ID 和 Secret Access Key（只显示一次），以及页面上的 Account ID。
5. **网站**：Worker `baocode`，静态资源是 `site/`（`_headers`、`_redirects` 照常生效），Settings → Builds 连着 GitHub 仓库（生产分支 `main`），自定义域名 `baocode.dev`。

### 7.2 GitHub

1. **环境**：Settings → Environments → New environment，名字 `release`。可添加 Required reviewers；若设置 Deployment branches and tags，正式 tag 发布需允许 `v*`，从 `main` 手动发布也需允许 `main`。
2. **环境密钥**（`release` 环境 → Environment secrets）：

   | 名字 | 值 |
   | --- | --- |
   | `UPDATE_SIGNING_KEY` | 现有 `update-signing.key` 文件的内容，一行 base64；不要重新生成或替换，否则已安装版本会拒绝新清单 |

3. **保护标签**：Settings → Rules → Rulesets → New tag ruleset，目标 `v*`，限制创建、更新、删除，只允许你自己绕过。

更新签名私钥放进 GitHub 之后，本机和离线备份仍然要留着（见 [auto-update.md 6.3](auto-update.md#63-保管)）。

### 7.3 Apple（macOS 签名与公证）

**需要 Apple 开发者账号吗？** 要。没有的话应用照样能构建、能自动更新，但新用户第一次从网上下载打开时会被 Gatekeeper 拦下（“BaoCode 已损坏，无法打开”），只能在终端里运行 `xattr -dr com.apple.quarantine` 才能打开。对外发布基本绕不过去。

1. **加入 Apple Developer Program**（每年 99 美元）：<https://developer.apple.com/programs/enroll/>
   - 我们**以个人身份**加入：用本人的 Apple ID（要开双重认证）。中国大陆的表单要求填身份证上的中文姓名和身份证号。在 iPhone 或 Mac 的 Apple Developer App 里注册最快，要拍证件做身份验证；也可以在网页上注册。付款后一般一两天内通过。
   - 证书上显示的是个人姓名（`Developer ID Application: <姓名> (<Team ID>)`），用户在签名信息里能看到，双击打开时的提示里看不到。
   - 以后想改成组织：可以联系 Apple 把个人账号转成组织账号（需要 D-U-N-S 编号）。转换前向 Apple 确认 Team ID 不变，否则见下面的注意。
2. **Developer ID Application 证书**：只有账号持有人（Account Holder）能创建。
   - 在 Mac 上打开 Xcode → Settings → Accounts → 登录 Apple ID → Manage Certificates → 左下角 `+` → **Developer ID Application**。
   - 打开“钥匙串访问” → 登录 → 我的证书 → 找到 “Developer ID Application: <名字> (<Team ID>)” → 右键导出为 `.p12`，设一个密码。
   - 终端运行 `security find-identity -v -p codesigning`，复制那一行开头的 40 位十六进制指纹（也可以用引号里的完整名字，但名字里有中文时用指纹更稳）。
3. **公证用的 API 密钥**：App Store Connect → 用户和访问 → 集成 → App Store Connect API → 团队密钥 → `+`，访问权限选 **Developer**。下载 `.p8` 文件（只能下载一次），记下 Key ID 和页面上方的 Issuer ID。
4. **填进 `release` 环境的密钥**：

   | 名字 | 值 |
   | --- | --- |
   | `MACOS_CERTIFICATE` | `base64 -i 证书.p12 \| pbcopy` 复制出来的内容 |
   | `MACOS_CERTIFICATE_PASSWORD` | 导出 `.p12` 时设的密码 |
   | `MACOS_SIGN_IDENTITY` | 第 2 步复制的指纹，例如 `1A2B3C…`（40 位）；或完整名字 `Developer ID Application: <姓名> (<Team ID>)` |
   | `NOTARY_KEY` | `.p8` 文件的全部内容（包括 `-----BEGIN PRIVATE KEY-----` 那两行） |
   | `NOTARY_KEY_ID` | Key ID |
   | `NOTARY_ISSUER` | Issuer ID |

5. 当前发布工作流尚未配置 Apple 签名与公证所需的证书变量，macOS 包会按构建脚本的默认方式签名。只构建验证时从 Actions → Build Morning Mist Installers → Run workflow 运行，并保持 `create_release` 为 `false`。

**注意**

- **Team 一旦用上就别换**：应用正式签名之后，只接受同一个 Team 签名的更新（`lib/update/installer_io.dart`）。从 ad hoc 签名的版本（现在的 1.0.0）更新到第一个正式签名的版本没问题；之后换 Team（比如另注册一个组织账号），老用户就得手动重装一次。
- **证书有效期 5 年**：到期前在同一个 Team 下新建一张，换掉 `MACOS_CERTIFICATE` 等密钥即可，Team 不变，老用户不受影响。已经公证过的版本过期后仍然能打开。
- **不需要提供给我**：证书、密码、密钥都只填在 GitHub 里。脚本和工作流已经按上面这些名字写好了，填好就能用。

## 8. 出了问题

| 情况 | 怎么办 |
| --- | --- |
| `check` 失败：版本不一致 / 标签不对 | 按报错改，删掉远端标签（`git push origin :refs/tags/v1.2.0`），重新打标签推送 |
| `check` 失败：比已发布的旧 | `tool/bump_version.dart` 加到比已发布的新 |
| `remote` › `linux` 失败：Docker 里跑不起来 | 日志里有每个系统、每种架构的结果和服务端的输出。在本机用 `dart run tool/build_remote_server.dart && tool/test_remote_server.sh` 复现（需要 Docker） |
| `remote` › `build` 失败：macOS 版没编出来或跑不起来 | 多半是下载 x64 Dart SDK 失败（Flutter 带的 Dart 版本在 dart-archive 上没有对应的包），或 Rosetta 没装上。在 Apple silicon 的 Mac 上用 `dart run tool/build_remote_server.dart --all --macos-x64-dart <x64 sdk>/bin/dart && tool/test_remote_server_macos.sh` 复现 |
| `macos` 失败：Not universal | 某个框架只编了一种架构，日志里列出了是哪个。拆出来的某个包会少这个框架的代码，在用到它时崩溃，所以不发 |
| `macos` 公证失败 | 日志里有 Apple 返回的详细原因（哪个文件、什么问题）。常见原因：某个二进制没开 hardened runtime、没有时间戳 |
| `release` 在上传 `latest.json` 之前失败 | 用户仍读不到新版本清单。修复后重新运行发布工作流即可 |
| 发出去的版本有问题 | 尽快发一个修复版（版本号更高）。也可以把上一版的 `latest.json` 传回去，让还没更新的人停在旧版，但已经更新的人不会被降级。见 [auto-update.md 5.5](auto-update.md#55-撤回一个版本) |
| 用户报“检查更新失败” | 见 [auto-update.md 第 10 节](auto-update.md#10-故障排查) |

## 9. 不用 CI，手动发布

CI 不可用时的备用办法，步骤和 CI 一样：

```sh
# macOS 上：先把四份远程服务端都编好（x64 的 Dart SDK 见 docs/ssh-remote.md 9.1）
dart run tool/build_remote_server.dart --all --macos-x64-dart <x64 sdk>/bin/dart
# 然后打包（有证书的话先设好第 7.3 节对应的环境变量，见 tool/build_macos.dart 开头）
dart run tool/build_macos.dart --remote-built
# Windows 上：把 Mac 上的 build/remote/ 拷过来，用同一份（自己编的没有 macOS 版）
dart run tool/build_windows.dart --remote-built

# 有私钥的机器上，两个平台的包都拷过来之后；自动更新更推荐使用 GitHub Actions
BAOCODE_UPDATE_SIGNING_KEY=~/.baocode-release/update-signing.key \
  dart run tool/release_manifest.dart \
    --windows build/installers/Morning-Mist-1.2.0-setup.exe \
    --macos-arm64 build/installers/Morning-Mist-1.2.0-mac-arm64.zip \
    --macos-x64   build/installers/Morning-Mist-1.2.0-mac-x64.zip \
    --dmg-arm64   build/installers/Morning-Mist-1.2.0-arm64.dmg \
    --dmg-x64     build/installers/Morning-Mist-1.2.0-x64.dmg \
    --notes-en release-notes/1.2.0.en.md --notes-zh release-notes/1.2.0.zh.md
```

先在 GitHub 创建或选择 `v1.2.0` Release，并上传版本化安装包；确认资产上传成功后，再上传清单：

```sh
gh release upload v1.2.0 build/installers/*.dmg build/installers/*.exe build/installers/*.zip --clobber
gh release upload v1.2.0 build/installers/latest.json --clobber
```

macOS 本机签名时用的环境变量：

| 变量 | 值 |
| --- | --- |
| `BAOCODE_MACOS_SIGN_IDENTITY` | 证书的 40 位指纹，或 `Developer ID Application: <名字> (<Team ID>)`；证书在钥匙串里 |
| `BAOCODE_NOTARY_KEY` | `.p8` 文件的路径 |
| `BAOCODE_NOTARY_KEY_ID` | Key ID |
| `BAOCODE_NOTARY_ISSUER` | Issuer ID |

只设 `BAOCODE_MACOS_SIGN_IDENTITY` 就只签名、不公证；都不设就是 ad hoc 签名。

## 10. 手机版

手机版（Android 的 APK、iOS 走 TestFlight）由 `.github/workflows/mobile.yml` 构建，和桌面版分开发布，版本号也分开（手机版 `pubspec.yaml` 里的版本，`0.x` 算 Beta）。官网下载页的 Android 按钮是 `/dl/android`，由 `site-worker/index.js` 按 `releases/mobile/latest.json` 跳转到当前版本。

```sh
git tag mobile-v0.1.0 && git push origin mobile-v0.1.0      # 发布：标签要和手机版的版本一致
git tag mobile-test-foo && git push origin mobile-test-foo  # 测试包：APK 传到 dl.baocode.dev/test/mobile-…，iOS 照样传 TestFlight
```

CI 从 `baocode-dev/mobile` 的 main 取代码（放在本仓库旁边，`../monad` 的包照常能找到），分两台机器构建：

- **Android**（Ubuntu）：`flutter build apk --release`，用发布密钥签名。每个版本都要用**同一把密钥**，否则装不上旧版之上，只能卸载重装。
- **iOS**（`macos-26`，要 Xcode 26：App Store Connect 只收 iOS 26 SDK 编的包）：导入 Apple Distribution 证书和 App Store 描述文件 → 把工程里 Runner 目标的 Release 配置改成手动签名（工程本身是自动签名，要登录开发者账号，CI 上没有；只改 Runner，Pods 的目标不能带描述文件）→ `flutter build ipa`，build 号用本工作流的 run number（TestFlight 不收重复的 build 号）→ `xcrun altool --upload-app` 用 App Store Connect API Key 上传到 TestFlight。**`mobile-test-*` 也上传**：iOS 的测试员走 TestFlight。上传后苹果要处理几分钟，测试员才看得到。

APK 上传时用 `--content-type` 说明类型（`application/vnd.android.package-archive`）。

发布时 APK 传到 `releases/mobile/<版本>/`，最后写 `releases/mobile/latest.json`（`version`、`pubDate`、`beta`、`downloads.android` 的 `url / size / sha256`）。桌面版的 `latest.json` 不受影响。

iOS 在 App Store Connect 上的 App 是 **BaoCode**（Apple ID `6825371537`，Bundle ID `dev.baocode.mobile`，Team `77SLP2NCVR`）。证书和描述文件一年一换：到期前用 App Store Connect API（或开发者网站）新建 Apple Distribution 证书、用它重做 App Store 描述文件，换掉下面三个密钥。

TestFlight 上每个 build 都要回答出口合规（加密）问题，否则停在「缺少合规证明」；在手机版的 `Info.plist` 里加 `ITSAppUsesNonExemptEncryption` 就不用每次回答。

**`release` 环境里要有的**（7.2 那些之外）：

| 名字 | 是什么 |
| --- | --- |
| `MOBILE_DEPLOY_KEY` | 读 `baocode-dev/mobile` 的部署密钥（私钥）。公钥加在那个仓库的 Settings → Deploy keys，只读即可 |
| `ANDROID_KEYSTORE` | Android 发布密钥库（`.jks`）的 base64 |
| `ANDROID_KEYSTORE_PASSWORD` | 它的密码（密钥别名 `baocode`，密钥密码与之相同） |
| `IOS_CERTIFICATE` | Apple Distribution 证书 `.p12` 的 base64 |
| `IOS_CERTIFICATE_PASSWORD` | 它的密码 |
| `IOS_PROFILE` | `dev.baocode.mobile` 的 App Store 描述文件（`.mobileprovision`）的 base64 |

上传 TestFlight 用的是 7.3 公证用的那把 App Store Connect API Key（`NOTARY_KEY`、`NOTARY_KEY_ID`、`NOTARY_ISSUER`），它的职能是 App 管理，两件事都够用。

环境的部署规则里要允许 `mobile-*` 标签。

下载页这两张卡片各带一个二维码（`site/qr/android.svg`、`site/qr/ios.svg`，鼠标悬停或点击卡片时显示）：码里是卡片自己那个按钮的链接，也就是 `/dl/android`、`/dl/ios`，扫到就跳到当时最新的那版安装包。链接变了就先跑 `dart run tool/make_download_qr.dart` 重新生成（`test/tool/download_qr_test.dart` 会检查页面、按钮和码三者一致）。**别把 `dl.baocode.dev` 上带哈希的直链写进码里**：那地址每次发版都换，码是要能一直用的。`latest.json` 里已经没有 iOS 的包：手机版重新上线前，`/dl/ios` 要改成跳到 App Store 或 TestFlight 的公开链接（`site-worker/index.js`）。

> 发布密钥库丢了就再也发不了能覆盖安装的 APK：本机和 CI 之外务必另存一份。

## 11. 浏览器扩展

浏览器扩展（`browser_extension/`，原理见 `lib/browser/browser_bridge.dart`）由 `.github/workflows/extension.yml` 打包发布，版本号就是 `manifest.json` 里的 `version`，和应用、手机版都分开。用户有两种装法，官网下载页「浏览器扩展」一节两个按钮都有：

- **Chrome 应用商店**（`/dl/chrome-web-store`）：自动更新。
- **开发者模式**（`/dl/browser-extension`）：下载 zip，解压后在 `chrome://extensions` 里「加载已解压的扩展程序」。不会自动更新。

两种装法的扩展 ID 一样，都是 `jfjagocghaaheooicmdnhcholmgdkngk`：开发者模式的 zip 里 `manifest.json` 带着 `key`，商店版是第一次上传时带上私钥 `key.pem` 定下的（见 [docs/browser-extension-store](browser-extension-store/README.md#第一次上传)）。应用只认这个 ID（`BrowserBridge.extensionIds`），CI 会检查 `key` 算出来的 ID 和它一致。私钥在 `~/.baocode-signing/browser-extension.pem`，丢了也不影响已上架的扩展（商店有自己的签名），但开发者模式的 ID 就没法再算出来了，务必另存一份。

```sh
# 先改 browser_extension/manifest.json 的 version（商店要求每次上传版本号都更大）
git tag extension-v0.2.0 && git push origin extension-v0.2.0         # 发布：标签要和 manifest 的版本一致
git tag extension-test-foo && git push origin extension-test-foo     # 只打包，传到 dl.baocode.dev/test/extension-…
```

本地打包：`tool/pack_browser_extension.sh`，产物在 `build/browser_extension/`。

CI 做的事：

| Job | 做什么 |
| --- | --- |
| `pack` | 标签和版本一致；`node --check` 检查 `background.js`；`key` 算出的 ID 等于应用认的 ID；manifest 里提到的文件都在；打两个 zip。改了扩展的 PR 也会跑这一步 |
| `share` | `extension-test-*`：两个 zip 都传到 `test/` |
| `publish` | 开发者模式的 zip 传到 `releases/extension/<版本>/`，最后写 `releases/extension/latest.json`（`version`、`pubDate`、`id`、`store`、`downloads.browser-extension`） |
| `store` | 用 Chrome Web Store API 上传商店的 zip 并提交审核，审核通过后自动上架。没配凭据就跳过，提示手动上传（凭据怎么拿见 [docs/browser-extension-store](browser-extension-store/README.md#ci-自动提交之后每个版本)） |

商店地址由官网维护：`latest.json` 的 `store`，默认是用 ID 拼出来的 `https://chromewebstore.google.com/detail/<ID>`，要换别的就在 `release` 环境的变量 `CHROME_WEB_STORE_URL` 里填，再推一次标签（或手动改 `latest.json`），不用发新版应用。官网的 `/dl/chrome-web-store` 跳过去（读不到 `latest.json` 时也跳 ID 地址）；应用里的按钮（`lib/browser/extension_store.dart`）每次运行拉一次，存在缓存目录的 `browser/store`，拉不到用上次存的，从没拉到过就用 ID 地址。

环境的部署规则里要允许 `extension-*` 标签。

**少发扩展**：扩展只做应用做不了的事：通信、共享标签页的边界（应用的任何请求都越不过它）、工具栏按钮。页面里的一切走 DevTools 协议原样转发（`cdp`，带 `sessionId` 时是页面里 iframe、worker 的会话，事件也带 `sessionId`）；标签页、窗口、分组走 `call`（`chrome.tabs.*`、`chrome.windows.*`、`chrome.tabGroups.*`，只能碰共享的标签页，返回的也只有共享的）和 `subscribe`（这几类的事件，只报共享标签页的）；行为开关走 `configure`（如 `followOpeners`：共享标签页打开的新标签页自动共享，默认开）。所以新功能基本只改应用。只有要新的浏览器权限（manifest 的 `permissions`）时才必须发新版扩展，而且用户要重新同意，尽量少加。

**能力和协议版本**：扩展新增的方法写进 `background.js` 的 `CAPABILITIES`，在握手时告诉应用，应用用 `BrowserConnection.can('…')` 判断后再用，旧扩展照样能连。只有改了已有消息的含义、旧的一方会理解错时，才把 `background.js` 的 `BRIDGE` 和 `BrowserBridge.protocol` 一起加一。版本对不上的连接，应用不用它，并在 设置 → 浏览器 里提示用户更新扩展或更新 BaoCode。商店版扩展会自动更新，通常比应用新；所以改协议时尽量让应用同时兼容旧版，先发应用、再发扩展。

**应用这边的 host**：浏览器按 native messaging 启动应用自带的 host，host 再去连应用。macOS 是 `macos/BrowserBridge/host.c`，Xcode 编进 `Contents/MacOS`，应用每次启动把 manifest 写进各浏览器的 `NativeMessagingHosts` 目录，经 Unix socket 连接。Windows 是 `windows/BrowserBridge/host.cpp`，`flutter build windows` 时编成 `baocode-browser-host.exe`，和 manifest `dev.baocode.browser.json` 一起放在 `baocode.exe` 旁边；安装包在 Chrome、Edge、Chromium 的注册表键里指向这个 manifest，卸载时删掉（Brave、Vivaldi 等读 Chrome 的键）。Windows 上 Dart 没有 Unix socket，应用改为监听 127.0.0.1 的随机端口，端口和每次启动新生成的 token 写在临时目录的 `baocode-browser.port`，host 握手时必须带上 token，否则应用直接断开。没经过安装包的本地构建没有注册表键，要测就手动加一条：`reg add HKCU\Software\Google\Chrome\NativeMessagingHosts\dev.baocode.browser /ve /d <构建目录>\dev.baocode.browser.json /f`。改扩展 ID 时 Windows 的 manifest 要一起改，`test/browser/browser_bridge_test.dart` 会检查两边一致。Linux 用的也是 `host.c`：`linux/BrowserBridge/CMakeLists.txt` 在 `flutter build linux` 时把它编成 `baocode-browser-host`，放在 `baocode` 旁边（deb 里是 `/opt/baocode/`）；应用每次启动把 manifest 写进 `~/.config/<浏览器>/NativeMessagingHosts`（设了 `XDG_CONFIG_HOME` 就用它）。socket 放在 `$XDG_RUNTIME_DIR`（只有本用户能进），没有才退回 `$TMPDIR` 或 `/tmp`；`/tmp` 是所有用户共用的，所以 host 连上后会用 `SO_PEERCRED` 核对对方是不是同一个用户，不是就断开，免得别的用户抢先占住 socket、截走浏览器的消息。Snap 版 Chromium 和 Flatpak 装的浏览器有沙箱，启动不了沙箱外的 host，暂不支持，设置 → 浏览器 里会提示改用官方 deb/rpm 包。CI 的 Linux 任务装上 deb 启动后，会检查 manifest 写对了位置，并真的跑一遍 host 连上应用。

# 桌面扩展

在本地工作区打开 Fast IDE，进入扩展视图中的 **VS Code 扩展**。可从 Open VSX 安装，也可用命令面板的 **Install from VSIX…** 选择本地文件，或把 VSIX 拖到工作区窗口。安装的扩展及启用状态保存在应用的数据目录里。

桌面工作台按需下载并校验固定版本的 VSCodium 运行时。打开已安装代码扩展的工作区后，扩展宿主按项目激活扩展。扩展命令出现在命令面板中，扩展的输出显示在 **输出** 面板。工作区信任设置决定哪些扩展可以激活。 扩展提供的树视图可从左侧活动栏打开，适用于当前文件的命令会出现在编辑器或资源管理器的右键菜单里。编辑器会调用扩展为当前语言注册的补全、悬停和格式化等功能。

已有的原生语言服务器和调试器仍可从工作台使用。扩展所需的 VS Code API 因扩展而异，依赖 Webview 的界面目前只显示占位提示。宿主 API 实现进度见 [协议对照](extensions/EXTHOST_PARITY.md)。

## Salesforce CLI 扩展

在含有 `sfdx-project.json` 的工作区安装 Salesforce CLI 和 Salesforce Services。若从 [Salesforce 官方发行页](https://github.com/forcedotcom/salesforcedx-vscode/releases) 下载 VSIX，可先导入同版本的 Services，再导入 CLI。扩展可用后，在命令面板搜索 Salesforce 或 SFDX。

回归测试使用官方 68.12.0 的 Core 和 Services，在临时本地工作区校验安装、激活、命令发现和 `sf.config.list` 调用。运行测试时可将两个文件分别命名为 `core.vsix` 和 `services.vsix`，用 `BAOCODE_SALESFORCE_VSIX_DIR` 指向所在目录并设置 `BAOCODE_EXTHOST_DIR`。

```sh
flutter test --run-skipped -t exthost test/extensions/acceptance/salesforce_exthost_test.dart
```

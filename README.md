<p align="center">
  <img src="https://github.com/user-attachments/assets/fe853809-ba8b-400b-83ab-a9a0da25be8a" alt="GhosttyCN" width="128">
</p>

<h1 align="center">GhosttyCN</h1>

<p align="center">
  适用于 macOS 的 Ghostty 中文增强版
  <br>
  简体中文界面 · 可视化设置 · 终端文件侧栏
</p>

<p align="center">
  <a href="https://github.com/vein-cyber/ghostty-cn/releases/latest">下载最新版</a>
  ·
  <a href="https://github.com/vein-cyber/ghostty-cn/releases">更新记录</a>
  ·
  <a href="https://ghostty.org/docs">使用文档</a>
</p>

## 主要功能

- **简体中文界面**：菜单、设置、提示和命令面板支持中文，跟随 macOS 语言设置。
- **可视化设置**：整合 [Ghostty Config](https://github.com/zerebos/ghostty-config)，支持分类、搜索和配置编辑，离线可用。
- **文件侧栏**：浏览本地及当前 SSH 主机的文件，自动跟随终端目录，支持预览、上传下载、新建、重命名和删除。
- **原生终端体验**：支持多窗口、标签页、分屏，以及主题、终端字体和透明背景设置。
- **应用内更新**：通过本仓库的 GitHub Release 获取更新，不会替换为官方原版。
- **与原版并存**：可与 Ghostty 同时安装，共享终端配置，应用偏好和系统权限独立管理。

## 下载与安装

支持 **macOS 13 及以上版本**，安装包同时适用于 Apple Silicon 和 Intel Mac。

1. 在 [Releases](https://github.com/vein-cyber/ghostty-cn/releases/latest) 下载通用版 ZIP 并解压。
2. 退出旧版，将 `GhosttyCN.app` 放入“应用程序”后打开。

应用未经过 Apple 公证，首次启动若被拦截，请在“系统设置 → 隐私与安全性”中确认打开。
后续可通过“GhosttyCN → 检查更新”升级；`v0.2.x` 用户需手动安装一次。

请从本仓库下载；Ghostty 官方下载页面提供的是原版，不包含本项目的增强功能。

## 快速使用

- **打开设置**：按 `⌘,` 或选择“GhosttyCN → 设置”，修改后点击“应用并重新加载”；也可编辑原始配置。
- **打开文件侧栏**：点击窗口右上角的侧栏图标，或选择“显示 → 文件管理”。支持左右放置、调整宽度，并保存偏好。
- **切换中文**：在“系统设置 → 通用 → 语言与地区 → 应用程序”中为 GhosttyCN 选择“简体中文”，退出并重新启动后生效。

## 项目来源与开发

GhosttyCN 基于 [Ghostty](https://github.com/ghostty-org/ghostty) 开发，
可视化设置整合自 [Ghostty Config](https://github.com/zerebos/ghostty-config)。感谢上游项目及贡献者。

- [Ghostty 使用文档](https://ghostty.org/docs)
- [开发说明](HACKING.md) · [贡献指南](CONTRIBUTING.md) · [许可证](LICENSE)

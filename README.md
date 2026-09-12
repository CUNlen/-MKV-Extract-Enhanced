# MKV Extract Enhanced

**专业 · 高效 · 简单好用的 MKV 媒体提取工具**

![Version](https://img.shields.io/badge/Version-1.0-ff4fa3?style=flat-square) ![64-bit](https://img.shields.io/badge/64--bit-Windows-4c9aff?style=flat-square) ![Python](https://img.shields.io/badge/Python-PySide6-3776AB?style=flat-square) ![License](https://img.shields.io/badge/License-MIT-22c55e?style=flat-square)
<img width="941" height="1672" alt="image" src="https://github.com/user-attachments/assets/a7e38a1e-aa90-4f05-9189-b2c782168fd8" />

> OPDAer Media Tools · 让好片更好看

## ✨ 主要功能

- 🚀 **极速字幕提取** — 智能解析 Matroska 结构，优先处理 S_TEXT/UTF8
- 📦 **批量 Track** — 支持批量选择字幕、音频、视频轨道
- 📊 **实时进度** — 提取过程实时显示，日志窗口可放大查看
- 🔄 **自动回退** — 特殊结构自动回退到标准 `mkvextract tracks`
- 🌐 **网络存储** — 支持本地路径以及 NAS / SMB / WebDAV 场景
- 🪟 **Windows 64-bit** — PySide6 图形界面，专属程序图标
- 🎬 **格式覆盖** — MKV / MKA / MKS / WEBM，以及 SRT / ASS / SSA / PGS / VobSub 等

## 🖼️ 项目视觉

正式 1.0 宣传海报与 GitHub 展示图位于 [`assets/`](assets/)。

> 海报资源会与源码、图标、构建文件一起作为项目资产维护。

## 📁 项目结构

```text
MKV-Extract-Enhanced/
├── docs/                         # 文档与截图
├── src/                          # 1.0 源码与 PyInstaller 配置
├── assets/                       # 海报、图标、界面素材
├── dist/                         # Windows 64-bit 构建产物
├── build/                        # 构建 / 快速启动脚本
├── LICENSE                       # MIT License
└── README.md
```

## 🔧 构建

环境：**64-bit Python 3.x + PySide6 + PyInstaller + MKVToolNix**。

进入 `src/` 使用 `MKV_Extract_Enhanced_1.0.spec`，或运行 `build/01_BUILD_FINAL.bat`。

构建目标：`MKV Extract Enhanced 1.0 x64`（onedir、无 UPX、内嵌 ICO）。

## 📦 1.0 正式版

**MKV Extract Enhanced 1.0【图标彻底修正版】 FINAL**

本版本重点修复 Windows 任务栏 / 窗口图标问题，并保持 64-bit、onedir 构建方案。

## 📄 License

MIT License

© OPDAer Media Tools

# 超级一键部署脚本

适用于 Ubuntu/Debian 系统的全能部署工具，一条命令即可完成 Nginx HTTPS 网站或 WebDAV 文件服务器的搭建，自动优化软件源与 DNS，新手友好。

[![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04%20%7C%2022.04%20%7C%2020.04-orange)](https://ubuntu.com/)
[![Debian](https://img.shields.io/badge/Debian-12%20%7C%2011%20%7C%2010-blue)](https://www.debian.org/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

## ✨ 功能特性

- 🔄 **自动换源**：一键更换为阿里云镜像源，加速软件包下载。
- 🌐 **DNS 修复**：禁用 systemd-resolved，使用稳定公共 DNS（阿里云 + Google）。
- 🌍 **Nginx HTTPS**：支持静态网站托管或反向代理 Docker/本地服务，自动申请 Let's Encrypt 免费 SSL 证书并配置自动续期。
- 📁 **WebDAV 服务**：基于 Apache2 搭建私有云盘，支持大文件上传（5GB 限制）、Basic 认证、`.txt` 文件免密且强制 UTF-8 编码避免乱码。
- 💬 **交互式菜单**：清晰的中文提示，按需选择功能，所有关键参数均可自定义。

## 📋 使用前提

- 一台运行 **Ubuntu 16.04+** 或 **Debian 9+** 的服务器（推荐 Ubuntu 24.04）。
- 拥有 `sudo` 权限的普通用户或 `root` 账户。
- 若需部署 HTTPS，请确保域名已解析到服务器 IP，且防火墙/安全组已放行 **80** 与 **443** 端口。
- 若部署 WebDAV，请确保防火墙/安全组已放行 **80** 端口（如需 HTTPS 可后续单独配置）。

## 🚀 一条命令安装

在服务器终端执行以下命令，脚本会自动下载并启动：

```bash
curl -fsSL -o all-in-one.sh https://raw.githubusercontent.com/expfukck/zzzzzzzz/refs/heads/main/all-in-one.sh && chmod +x all-in-one.sh && sudo ./all-in-one.sh

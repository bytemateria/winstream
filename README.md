# Winstream
A lightweight WinPE environment designed to fetch and deploy full Windows ISO/WIM images over the network and using Cloud Environments

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011%20%7C%20Server-0078D6.svg)](https://www.microsoft.com/windows)

An automated utility for building a lightweight Windows Preinstallation Environment (WinPE) that dynamically fetches and installs full Windows images over the network.

---

## Overview

**Winstream** streamlines system imaging by separating the boot environment from the OS payload. Instead of carrying large 6GB+ USB drives with static Windows images, this tool creates a minimal WinPE boot disk (or PXE image) that boots up, establishes a network connection, downloads the latest full Windows OS image (`.wim`, `.esd`, or `.iso`), and initiates the deployment automatically.

### Key Features

* **Network-First Deployment:** Downloads Windows payloads on-demand via HTTP/HTTPS, SMB, or custom network shares.
* **Lightweight Boot Media:** Minimal WinPE footprint fits on small USB drives or network boot servers.
* **Automated Disk Formatting:** Includes PowerShell scripts to handle GPT/MBR partition layouts automatically.
* **DISM-Based Extraction:** Applies OS images directly using native Windows Deployment Image Servicing and Management tools.
* **Customizable Payloads:** Easily configure source URLs, target OS editions, and unattend answer files (`unattend.xml`).

---

## Prerequisites

Before building the WinPE image, ensure your host environment has:

* **Windows 10 / 11** or **Windows Server 2019+**
* **Windows Assessment and Deployment Kit (ADK)**
* **WinPE Add-on for Windows ADK**
* **PowerShell 5.1+** (running with Administrator privileges)

---

## Quick Start

### 1. Clone the Repository
```powershell
git clone [https://github.com/bytemateria/winstream.git](https://github.com/bytemateria/winstream.git)
cd winstream

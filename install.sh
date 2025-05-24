#!/bin/sh
set -e

# 1. 确保以 root（或有 sudo 权限）运行
if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 用户或 sudo 运行此脚本"
  exit 1
fi

# 2. 更新 apk 索引
echo ">> apk update"
apk update

# 3. 安装 Python3、pip 以及编译扩展所需工具
echo ">> apk add python3 py3-pip build-base musl-dev libffi-dev openssl-dev --no-cache"
apk add --no-cache python3 py3-pip build-base musl-dev libffi-dev openssl-dev

# 4. 确保 pip 最新
echo ">> pip3 install --upgrade pip"
pip3 install --no-cache-dir --upgrade pip

# 5. 安装脚本所需的所有 Python 包
echo ">> pip3 install requests pycryptodome selenium"
pip3 install requests pycryptodome selenium

echo "✅ 安装完成"

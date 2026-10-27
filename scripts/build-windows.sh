#!/bin/bash
# 在 macOS 上交叉编译 Windows 版，产物是 build/Boundless-Windows.zip（内含 Boundless.exe）
# 需要：rustup target add x86_64-pc-windows-gnu；brew install mingw-w64
set -euo pipefail
cd "$(dirname "$0")/../windows"

command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "缺少 mingw-w64，请先执行：brew install mingw-w64"; exit 1; }
rustup target list --installed | grep -q x86_64-pc-windows-gnu || rustup target add x86_64-pc-windows-gnu

cargo build --release --target x86_64-pc-windows-gnu -p boundless
mkdir -p ../build/windows
cp target/x86_64-pc-windows-gnu/release/boundless.exe ../build/windows/Boundless.exe
rm -f ../build/Boundless-Windows.zip
(cd ../build/windows && zip -q ../Boundless-Windows.zip Boundless.exe)
echo "已生成 build/windows/Boundless.exe 和 build/Boundless-Windows.zip"

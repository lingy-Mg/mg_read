# Android Node 进程库

`arm64-v8a/libnode.so` 来自用户提供的
`nodejs-mobile-android-24.21.0-0.zip`，构建发布于
[fogtape/nodejs-mobile v24.21.0-0](https://github.com/fogtape/nodejs-mobile/releases/tag/v24.21.0-0)。
它基于 Node.js 源码并带有移动端补丁，**不是 Node.js 官方 Android 二进制**。

- 原始 ZIP SHA-256：`e3cd29a1be03405f11dd5c857af8cd3ad13f84f1409ea648f5328f0bada5bd76`
- `libnode.so` SHA-256：`955b308b1dfdf7662e8fe5ee4eb8c0c7d0a313f2d306387f2307529993c4bc32`
- 架构：arm64-v8a；新进程后端仅支持该架构。
- 入口：JNI 通过 `node::Start(int, char**)` 启动固定 Core CLI；库不能作为可执行文件启动。
- 运行依赖：`libc++_shared.so` 及 Android 系统库；构建时由 NDK 打包 C++ 共享运行库。

此目录的 `.gitattributes` 将大体积二进制交给 Git LFS 管理。

# 悦听听书增量规则

- 加密目录由 `src/encrypted-payload.mts` 解码；固定 `@noble/ciphers` 的 XChaCha20-Poly1305
  随单文件来源内联，Node/Android/Bun 共用同一实现，不依赖 Bun 未实现的 Node cipher。
- 解密必须先验证认证标签，再解析 JSON；拒绝损坏、截断、非法十六进制及未知版本，不记录原始响应。
- `test/encrypted-payload.test.mjs` 的固定密文由旧 Node/OpenSSL 独立生成，覆盖版本 1/2 与篡改拒绝。
  来源离线与 artifact 测试必须在 Node 和 Bun 均执行；真实站点结果另由快速/实际检查记录。

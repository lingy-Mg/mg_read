# MgRead Plugin Cache

`@mgread/plugin-cache` 是仓库内数据源使用的有界展示投影缓存。它保存可重复 GET 的发现、搜索、详情和目录
投影。

```js
import { createPluginCache } from '@mgread/plugin-cache';
```

公开导出以 [`index.d.ts`](index.d.ts) 为准；容量、过期、stale、single-flight 和损坏降级行为由直接测试定义。

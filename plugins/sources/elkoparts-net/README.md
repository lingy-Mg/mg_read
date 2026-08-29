# 饿狼小说 MgRead 数据源

将用户提供的旧版 `elkoparts.net` 规则转换为标准 Node.js 24 MgRead 插件。生产代码只通过
`ctx.http` 请求公开页面，并通过 `ctx.resource` 代理封面；不使用登录、浏览器会话或站点私有凭据。

开发验证使用仓库固定 Node：`npm.cmd ci`、`npm.cmd test`、`npm.cmd run verify`；线上结构验证另行
执行 `npm.cmd run test:live`。


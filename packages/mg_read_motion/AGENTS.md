# mg_read_motion 增量规则

根 `AGENTS.md` 适用。本 package 只提供共享 Flutter 动效策略和控件，不拥有设置、IO、路由或播放状态。

- 公开入口为 `lib/mg_read_motion.dart`，只消费 `MediaQuery.disableAnimations`；宿主负责合并系统与应用偏好。
- 无动画使用静态控件与即时终态，不能冻结整棵业务树；交互、焦点、语义和真实进度必须保留。
- 按修改范围选择控件行为回归，优先验证实际故障；无需为每个小改动扩展测试矩阵或跑完整套测试。
- 验证入口为 `test/`；只分析改动文件并运行直接相关测试。

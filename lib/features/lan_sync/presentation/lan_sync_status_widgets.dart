/// 临时数据同步的阶段与进度投影。
part of 'lan_sync_page.dart';

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.state});
  final LanSyncViewState state;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Card(
      child: ListTile(
        leading: state.busy
            ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(
                state.phase == LanSyncPhase.completed
                    ? Icons.check_circle_rounded
                    : state.phase == LanSyncPhase.failed
                    ? Icons.error_outline_rounded
                    : Icons.sync_rounded,
              ),
        title: Text(state.message),
        subtitle: _StatusDetail(state: state),
      ),
    ),
  );
}

class _StatusDetail extends StatelessWidget {
  const _StatusDetail({required this.state});

  final LanSyncViewState state;

  @override
  Widget build(BuildContext context) {
    final progressLabel = state.message.startsWith('正在校验')
        ? '已校验'
        : state.message.startsWith('正在写入')
        ? '已写入'
        : '已接收';
    final transferred = state.transferredBytes > 0 ? '${_formatBytes(state.transferredBytes)} $progressLabel' : null;
    final detail = state.message.startsWith('正在校验')
        ? '正在校验文件完整性，校验通过后才会交给数据源 Runtime。'
        : state.message.startsWith('正在写入')
        ? '校验已通过，正在写入受控入箱。'
        : switch (state.message) {
            '正在传输插件' => '正在从发送端接收插件文件。',
            '正在完成插件安装' => '正在让数据源 Runtime 冷启动并确认插件可用。',
            '正在写入书架和阅读进度' => '插件已处理，正在单事务写入选中的书架和进度。',
            _ => null,
          };
    if (transferred == null && detail == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[if (transferred != null) Text(transferred), if (detail != null) Text(detail)],
    );
  }
}

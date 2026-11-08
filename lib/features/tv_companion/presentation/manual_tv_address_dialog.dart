/// Shared manual LAN endpoint dialog. Its state owns the text controllers so
/// they stay alive for the route's reverse transition after submission.
/// Validation reuses the LAN endpoint policy; network connection is caller-owned.
library;

import 'package:flutter/material.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/lan_sync/domain/lan_endpoint_policy.dart';

typedef ManualTvAddress = ({String address, int port});

Future<ManualTvAddress?> showManualTvAddressDialog(BuildContext context) =>
    showDialog<ManualTvAddress>(context: context, builder: (_) => const _ManualTvAddressDialog());

final class _ManualTvAddressDialog extends StatefulWidget {
  const _ManualTvAddressDialog();

  @override
  State<_ManualTvAddressDialog> createState() => _ManualTvAddressDialogState();
}

final class _ManualTvAddressDialogState extends State<_ManualTvAddressDialog> {
  final TextEditingController _address = TextEditingController();
  final TextEditingController _port = TextEditingController();
  final _form = GlobalKey<FormState>();

  void _submit() {
    if (_form.currentState?.validate() != true) return;
    Navigator.pop(context, (address: _address.text.trim(), port: int.parse(_port.text.trim())));
  }

  @override
  void dispose() {
    _address.dispose();
    _port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('手动连接 TV'),
    content: Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('在电视上打开“局域网 TV 播放”，将页面显示的地址和端口填在下方。'),
          const SizedBox(height: AppSpacing.section),
          TextFormField(
            key: const Key('companion-manual-address'),
            controller: _address,
            decoration: const InputDecoration(
              labelText: 'TV 的局域网地址',
              hintText: '例如 192.168.1.20',
              prefixIcon: Icon(Icons.tv_rounded),
              errorMaxLines: 3,
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.next,
            autocorrect: false,
            validator: (value) => isLanSyncPrivateIpv4((value ?? '').trim()) ? null : '请输入有效的局域网 IPv4 地址',
          ),
          const SizedBox(height: AppSpacing.comfortable),
          TextFormField(
            key: const Key('companion-manual-port'),
            controller: _port,
            decoration: const InputDecoration(
              labelText: '端口',
              hintText: '填写 TV 上显示的端口',
              prefixIcon: Icon(Icons.lan_outlined),
              errorMaxLines: 3,
            ),
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _submit(),
            validator: (value) {
              final port = int.tryParse((value ?? '').trim());
              return port != null && port > 0 && port <= 65535 ? null : '请输入 1–65535 之间的端口';
            },
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(key: const Key('companion-manual-connect'), onPressed: _submit, child: const Text('连接')),
    ],
  );
}

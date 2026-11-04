/// Shared manual LAN endpoint dialog. Its state owns the text controllers so
/// they stay alive for the route's reverse transition after submission.
library;

import 'package:flutter/material.dart';

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
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const Key('companion-manual-address'),
          controller: _address,
          decoration: const InputDecoration(labelText: '局域网 IPv4 地址'),
          keyboardType: TextInputType.number,
        ),
        TextField(
          key: const Key('companion-manual-port'),
          controller: _port,
          decoration: const InputDecoration(labelText: '端口'),
          keyboardType: TextInputType.number,
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(
        key: const Key('companion-manual-connect'),
        onPressed: () {
          final parsedPort = int.tryParse(_port.text.trim());
          final address = _address.text.trim();
          if (parsedPort == null || parsedPort < 1 || parsedPort > 65535 || address.isEmpty) return;
          Navigator.pop(context, (address: address, port: parsedPort));
        },
        child: const Text('连接'),
      ),
    ],
  );
}

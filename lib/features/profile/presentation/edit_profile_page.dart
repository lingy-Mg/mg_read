/// 本地个人资料编辑页。
///
/// 职责：
/// - 编辑资料卡展示的昵称和个性签名。
/// - 明确说明资料仅保存在当前设备，并呈现持久化结果。
///
/// 注意：
/// - 内置头像仅用于本地展示，本页不申请相册权限或上传文件。
/// - 保存失败时保留用户输入，不自动退出页面。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/profile/application/profile_identity_store.dart';
import 'package:mg_read/features/profile/domain/profile_identity.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

final class EditProfilePage extends ConsumerStatefulWidget {
  const EditProfilePage({required this.onBackRequested, super.key});

  final VoidCallback onBackRequested;

  @override
  ConsumerState<EditProfilePage> createState() => _EditProfilePageState();
}

final class _EditProfilePageState extends ConsumerState<EditProfilePage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _displayNameController;
  late final TextEditingController _mottoController;
  bool _initialized = false;
  bool _saving = false;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    _displayNameController = TextEditingController();
    _mottoController = TextEditingController();
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _mottoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final identity = ref.watch(profileIdentityProvider).asData?.value ?? ProfileIdentity.defaults;
    if (!_initialized) {
      _initialized = true;
      _displayNameController.text = identity.displayName;
      _mottoController.text = identity.motto;
    }
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              AppSecondaryPageTopBar(title: '编辑资料', onBack: widget.onBackRequested),
              Expanded(
                child: Form(
                  key: _formKey,
                  child: ListView(
                    key: const Key('edit-profile-content'),
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.fromLTRB(
                      AppDetailMetrics.horizontalPadding,
                      AppSpacing.regular,
                      AppDetailMetrics.horizontalPadding,
                      AppSpacing.section,
                    ),
                    children: <Widget>[
                      const _LocalProfileHeader(),
                      const SizedBox(height: AppSpacing.section),
                      _ProfileFieldsCard(
                        displayNameController: _displayNameController,
                        mottoController: _mottoController,
                        enabled: !_saving,
                      ),
                      if (_saveError != null) ...<Widget>[
                        const SizedBox(height: AppSpacing.regular),
                        _ProfileSaveNotice(key: const Key('edit-profile-save-error'), message: _saveError!, isError: true),
                      ],
                      const SizedBox(height: AppSpacing.regular),
                      const _ProfileSaveNotice(message: '资料只保存在当前设备，用于“我的”页面本地显示，不会上传或同步。'),
                    ],
                  ),
                ),
              ),
              _ProfileSaveBar(saving: _saving, onPressed: _saving ? null : _save),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final identity = ProfileIdentity(displayName: _displayNameController.text.trim(), motto: _mottoController.text.trim());
    try {
      await ref.read(profileIdentityStoreProvider).save(identity);
      if (mounted) widget.onBackRequested();
    } on Object {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = '资料保存失败，请稍后重试。';
      });
    }
  }
}

class _LocalProfileHeader extends StatelessWidget {
  const _LocalProfileHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      key: const Key('edit-profile-local-header'),
      decoration: BoxDecoration(
        color: tokens.featureSurface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.accent.withValues(alpha: 0.14)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.comfortable),
        child: Row(
          children: <Widget>[
            ClipOval(
              child: Image.asset(
                'assets/profile/profile-traveler-avatar.webp',
                width: 64,
                height: 64,
                fit: BoxFit.cover,
                cacheWidth: 128,
                cacheHeight: 128,
                errorBuilder: (_, _, _) => const ColoredBox(color: Color(0xFFEDE7DE), child: SizedBox(width: 64, height: 64)),
              ),
            ),
            const SizedBox(width: AppSpacing.regular),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('本地资料', style: theme.textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.unit),
                  Text('内置头像 · 仅当前设备可见', style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText)),
                ],
              ),
            ),
            Icon(Icons.phone_android_rounded, color: tokens.accent),
          ],
        ),
      ),
    );
  }
}

class _ProfileFieldsCard extends StatelessWidget {
  const _ProfileFieldsCard({required this.displayNameController, required this.mottoController, required this.enabled});

  final TextEditingController displayNameController;
  final TextEditingController mottoController;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.comfortable),
        child: Column(
          children: <Widget>[
            TextFormField(
              key: const Key('edit-profile-display-name'),
              controller: displayNameController,
              enabled: enabled,
              maxLength: ProfileIdentity.displayNameMaxLength,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: '昵称', hintText: '请输入昵称', prefixIcon: Icon(Icons.person_outline_rounded)),
              validator: (String? value) {
                final text = value?.trim() ?? '';
                if (text.isEmpty) return '昵称不能为空';
                if (text.length > ProfileIdentity.displayNameMaxLength) {
                  return '昵称不能超过 ${ProfileIdentity.displayNameMaxLength} 个字符';
                }
                return null;
              },
            ),
            const SizedBox(height: AppSpacing.compact),
            TextFormField(
              key: const Key('edit-profile-motto'),
              controller: mottoController,
              enabled: enabled,
              maxLength: ProfileIdentity.mottoMaxLength,
              minLines: 2,
              maxLines: 3,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: '个性签名',
                hintText: '写下一句喜欢的话',
                alignLabelWithHint: true,
                prefixIcon: Icon(Icons.edit_note_rounded),
              ),
              validator: (String? value) {
                final text = value?.trim() ?? '';
                if (text.isEmpty) return '个性签名不能为空';
                if (text.length > ProfileIdentity.mottoMaxLength) {
                  return '个性签名不能超过 ${ProfileIdentity.mottoMaxLength} 个字符';
                }
                return null;
              },
              onFieldSubmitted: (_) {
                if (enabled) FocusScope.of(context).unfocus();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileSaveNotice extends StatelessWidget {
  const _ProfileSaveNotice({required this.message, this.isError = false, super.key});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    final color = isError ? theme.colorScheme.error : tokens.mutedText;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(isError ? Icons.error_outline_rounded : Icons.lock_outline_rounded, size: 18, color: color),
        const SizedBox(width: AppSpacing.compact),
        Expanded(
          child: Text(message, style: theme.textTheme.bodySmall?.copyWith(color: color, height: 1.45)),
        ),
      ],
    );
  }
}

class _ProfileSaveBar extends StatelessWidget {
  const _ProfileSaveBar({required this.saving, required this.onPressed});

  final bool saving;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.pageBackground,
        border: Border(top: BorderSide(color: tokens.divider)),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(
          AppDetailMetrics.horizontalPadding,
          AppSpacing.regular,
          AppDetailMetrics.horizontalPadding,
          AppSpacing.regular,
        ),
        child: FilledButton(
          key: const Key('edit-profile-save'),
          onPressed: onPressed,
          child: saving ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('保存资料'),
        ),
      ),
    );
  }
}

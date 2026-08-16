import 'package:flutter/material.dart';

import '../config_store.dart';
import '../theme.dart';

/// 连接模式选择器:公网服务器(默认、推荐)与局域网直连(折叠)两张卡片。
///
/// 替代旧版「RadioListTile + ExpansionTile」双控件混用:
/// - 选中的模式卡片展开,内部渲染对应表单字段;
/// - 未选中的模式卡片只保留一行摘要(局域网直连默认折叠);
/// - 只有卡片头部可点击切换模式,表单区域独立接收输入手势。
class ConnectionModeSelector extends StatelessWidget {
  const ConnectionModeSelector({
    super.key,
    required this.value,
    required this.onChanged,
    required this.publicFields,
    required this.lanFields,
  });

  final ConnectionMode value;
  final ValueChanged<ConnectionMode> onChanged;

  /// 公网模式选中时展示的表单字段。
  final Widget publicFields;

  /// 局域网模式选中时展示的表单字段。
  final Widget lanFields;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ModeCard(
          selected: value == ConnectionMode.public,
          icon: Icons.public,
          title: '公网服务器(推荐)',
          subtitle: '通过域名 + 手机口令接入云端中继',
          badge: '推荐',
          onTap: () => onChanged(ConnectionMode.public),
          child: value == ConnectionMode.public ? publicFields : null,
        ),
        const SizedBox(height: DshTokens.space3),
        _ModeCard(
          selected: value == ConnectionMode.lan,
          icon: Icons.lan,
          title: '局域网直连',
          subtitle: '次要模式:直连局域网内 DSH 服务器',
          onTap: () => onChanged(ConnectionMode.lan),
          child: value == ConnectionMode.lan ? lanFields : null,
        ),
      ],
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.selected,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.badge,
    this.child,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final String? badge;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final borderColor = selected
        ? scheme.primary
        : scheme.outlineVariant.withValues(alpha: 0.55);

    return AnimatedContainer(
      duration: DshTokens.motionNormal,
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: selected
            ? scheme.primaryContainer.withValues(alpha: 0.55)
            : scheme.surface,
        border: Border.all(color: borderColor, width: selected ? 1.4 : 1),
        borderRadius: BorderRadius.circular(DshTokens.radiusL),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  DshTokens.space4,
                  DshTokens.space3 + 2,
                  DshTokens.space3,
                  DshTokens.space3 + 2,
                ),
                child: Row(
                  children: [
                    Icon(
                      icon,
                      size: 22,
                      color: selected ? scheme.primary : DshTokens.inkMuted,
                    ),
                    const SizedBox(width: DshTokens.space3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  title,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: selected
                                        ? scheme.primary
                                        : scheme.onSurface,
                                  ),
                                ),
                              ),
                              if (badge != null) ...[
                                const SizedBox(width: DshTokens.space2),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: DshTokens.space2,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: scheme.primary,
                                    borderRadius: BorderRadius.circular(
                                      DshTokens.radiusS,
                                    ),
                                  ),
                                  child: Text(
                                    '推荐',
                                    style: TextStyle(
                                      color: scheme.onPrimary,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: DshTokens.space2),
                    Icon(
                      selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      size: 20,
                      color: selected ? scheme.primary : DshTokens.inkMuted,
                    ),
                  ],
                ),
              ),
            ),
            if (child != null)
              AnimatedSize(
                duration: DshTokens.motionNormal,
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    DshTokens.space4,
                    0,
                    DshTokens.space4,
                    DshTokens.space4,
                  ),
                  child: child!,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

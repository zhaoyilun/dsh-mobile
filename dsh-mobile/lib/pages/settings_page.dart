import 'package:flutter/material.dart';

import '../config_store.dart';
import '../theme.dart';
import '../widgets/connection_mode_selector.dart';

/// 设置页返回结果:保存的新配置,或"已清除配置"标记。
class SettingsResult {
  const SettingsResult.saved(AppConfig this.config) : cleared = false;

  const SettingsResult.cleared() : config = null, cleared = true;

  final AppConfig? config;
  final bool cleared;
}

/// 旧凭据是否允许「留空复用」:只有连接模式不变且服务器 origin
/// (scheme/host/port)完全一致时才允许。模式或服务器变化必须重输,
/// 防止把手机口令/配对令牌静默发送到新端点。
bool canReuseStoredCredential(
  AppConfig? initial,
  ConnectionMode mode,
  String serverUrl,
) {
  if (initial == null || initial.mode != mode) {
    return false;
  }
  return isSameOriginUrl(initial.serverUrl, serverUrl);
}

/// 设置页:查看/修改连接模式、服务器地址与访问凭据,清除配置回到首次配置。
///
/// 安全(见 DESIGN.md §6):
/// - 凭据经 [ConfigStore] 写入 flutter_secure_storage(Keystore),不明文落盘;
/// - 编辑场景不回显凭据;仅模式与服务器 origin 均未变化时,留空才复用旧凭据;
/// - 凭据绝不写入日志。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.initial});

  /// 已保存的配置(编辑场景)。
  final AppConfig? initial;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _serverController;
  final _credentialController = TextEditingController();
  late ConnectionMode _mode;
  bool _obscureCredential = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.initial?.mode ?? ConnectionMode.public;
    _serverController = TextEditingController(
      text: widget.initial?.serverUrl ?? '',
    );
  }

  @override
  void dispose() {
    _serverController.dispose();
    _credentialController.dispose();
    super.dispose();
  }

  String get _credentialBase =>
      _mode == ConnectionMode.public ? '手机口令' : '配对令牌';

  String get _credentialLabel {
    if (widget.initial == null) {
      return _credentialBase;
    }
    final canReuse = canReuseStoredCredential(
      widget.initial,
      _mode,
      _serverController.text.trim(),
    );
    return canReuse ? '$_credentialBase(留空保持不变)' : _credentialBase;
  }

  Future<void> _save() async {
    if (_saving) {
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final serverUrl = _serverController.text.trim();
    var credential = _credentialController.text.trim();
    if (credential.isEmpty &&
        canReuseStoredCredential(widget.initial, _mode, serverUrl)) {
      credential = widget.initial!.token; // 同模式同 origin 才允许留空复用
    }
    if (credential.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('请输入$_credentialBase')));
      return;
    }
    setState(() => _saving = true);
    final config = AppConfig(
      mode: _mode,
      serverUrl: serverUrl,
      token: credential,
    );
    try {
      await ConfigStore().save(config);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('保存失败,请重试')));
      return;
    }
    if (!mounted) {
      return;
    }
    // 返回新配置,由主页/根路由重建 WebView。
    Navigator.of(context).pop(SettingsResult.saved(config));
  }

  Future<void> _clearConfig() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除配置?'),
        content: const Text('将删除连接模式、服务器地址与访问凭据,回到首次配置页。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await ConfigStore().clear();
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('清除失败,请重试')));
      return;
    }
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(const SettingsResult.cleared());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initial = widget.initial;
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        leading: BackButton(onPressed: () => Navigator.of(context).pop()),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: AutofillGroup(
            child: ListView(
              padding: const EdgeInsets.all(DshTokens.space4),
              children: [
                if (initial != null) ...[
                  _CurrentConnectionCard(config: initial),
                  const SizedBox(height: DshTokens.space5),
                ],
                Text('连接模式', style: theme.textTheme.labelLarge),
                const SizedBox(height: DshTokens.space2),
                ConnectionModeSelector(
                  value: _mode,
                  onChanged: (value) {
                    if (value == _mode) {
                      return;
                    }
                    setState(() {
                      // 模式变化后旧凭据不得跨模式复用,清掉已输入内容。
                      _credentialController.clear();
                      _mode = value;
                    });
                  },
                  publicFields: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        controller: _serverController,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.url],
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: '服务器地址',
                          hintText: 'https://relay.example.com',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.link),
                        ),
                        validator: (value) =>
                            validateModeServerUrl(ConnectionMode.public, value),
                      ),
                      const SizedBox(height: DshTokens.space4),
                      _credentialField(),
                    ],
                  ),
                  lanFields: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        controller: _serverController,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.url],
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: '服务器地址',
                          hintText: 'http://192.168.1.5:3080 或 https://…',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.link),
                        ),
                        validator: (value) =>
                            validateModeServerUrl(ConnectionMode.lan, value),
                      ),
                      const SizedBox(height: DshTokens.space4),
                      _credentialField(),
                    ],
                  ),
                ),
                const SizedBox(height: DshTokens.space5),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('保存'),
                ),
                const SizedBox(height: DshTokens.space2),
                OutlinedButton.icon(
                  onPressed: _clearConfig,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('清除配置'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
                const SizedBox(height: DshTokens.space4),
                Text(
                  '· 口令/令牌经 Android Keystore 加密存储,不明文落盘;\n'
                  '· 修改模式或服务器后,旧凭据不会自动复用到新端点;\n'
                  '· 清除配置会删除本地保存的模式、地址与凭据。',
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _credentialField() {
    return TextFormField(
      controller: _credentialController,
      obscureText: _obscureCredential,
      autocorrect: false,
      enableSuggestions: false,
      textInputAction: TextInputAction.done,
      autofillHints: const [AutofillHints.password],
      onFieldSubmitted: (_) => _save(),
      decoration: InputDecoration(
        labelText: _credentialLabel,
        hintText: _mode == ConnectionMode.public
            ? '云端中继配置的 phone-pass'
            : '服务器打印的配对 URL 中的 token',
        border: const OutlineInputBorder(),
        prefixIcon: const Icon(Icons.key),
        suffixIcon: IconButton(
          tooltip: _obscureCredential ? '显示凭据' : '隐藏凭据',
          icon: Icon(
            _obscureCredential ? Icons.visibility_off : Icons.visibility,
          ),
          onPressed: () =>
              setState(() => _obscureCredential = !_obscureCredential),
        ),
      ),
      validator: (value) {
        if ((value == null || value.trim().isEmpty) && widget.initial == null) {
          return '请输入$_credentialBase';
        }
        return null;
      },
    );
  }
}

/// 当前连接摘要卡片:只展示模式与 origin,绝不展示凭据。
class _CurrentConnectionCard extends StatelessWidget {
  const _CurrentConnectionCard({required this.config});

  final AppConfig config;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(DshTokens.space4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.25),
        ),
        borderRadius: BorderRadius.circular(DshTokens.radiusL),
      ),
      child: Row(
        children: [
          Icon(Icons.dns_outlined, color: theme.colorScheme.primary),
          const SizedBox(width: DshTokens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '当前连接',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${config.modeLabel} · ${config.displayOrigin}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

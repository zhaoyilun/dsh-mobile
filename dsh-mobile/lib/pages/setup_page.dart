import 'package:flutter/material.dart';

import '../config_store.dart';
import '../theme.dart';
import '../widgets/connection_mode_selector.dart';
import '../widgets/dsh_brand_mark.dart';

/// 首次配置页:选择连接模式,输入服务器地址 + 访问凭据,校验后保存并进入主页。
///
/// - 默认选中「公网服务器(推荐)」:URL 仅允许 https://,凭据为手机口令;
/// - 「局域网直连」为折叠卡片(次要模式):URL 允许 http/https,凭据为配对令牌;
/// - 凭据经 [ConfigStore] 写入 flutter_secure_storage(Keystore),不明文落盘;
/// - 凭据绝不写入日志/崩溃报告。
class SetupPage extends StatefulWidget {
  const SetupPage({super.key, this.onSaved});

  /// 保存成功后的回调(根路由据此重新加载配置并进入主页)。
  final VoidCallback? onSaved;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final _formKey = GlobalKey<FormState>();
  // 首次配置默认填入用户自己的公网入口,只需输入手机口令。
  final _serverController = TextEditingController(text: '');

  // 公网口令与局域网令牌分开保存,切换模式不会把一种凭据带进另一种模式。
  final _publicCredentialController = TextEditingController();
  final _lanCredentialController = TextEditingController();

  bool _obscureCredential = true;
  bool _saving = false;
  ConnectionMode _mode = ConnectionMode.public; // 默认公网(推荐)

  TextEditingController get _credentialController =>
      _mode == ConnectionMode.public
      ? _publicCredentialController
      : _lanCredentialController;

  @override
  void dispose() {
    _serverController.dispose();
    _publicCredentialController.dispose();
    _lanCredentialController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) {
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final config = AppConfig(
      mode: _mode,
      serverUrl: _serverController.text.trim(),
      token: _credentialController.text.trim(),
    );
    setState(() => _saving = true);
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
    widget.onSaved?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('连接设置')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: AutofillGroup(
            child: ListView(
              padding: const EdgeInsets.all(DshTokens.space4),
              children: [
                const SizedBox(height: DshTokens.space2),
                const Center(child: DshBrandMark(size: 56)),
                const SizedBox(height: DshTokens.space3),
                Text(
                  'DSH · 移动端',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: DshTokens.space2),
                Text(
                  '默认通过公网服务器接入,也可直连局域网内的 DSH 服务器。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: DshTokens.space5),
                Text('连接模式', style: theme.textTheme.labelLarge),
                const SizedBox(height: DshTokens.space2),
                ConnectionModeSelector(
                  value: _mode,
                  onChanged: (value) {
                    if (value != _mode) {
                      setState(() => _mode = value);
                    }
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
                      TextFormField(
                        controller: _publicCredentialController,
                        obscureText: _obscureCredential,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.password],
                        onFieldSubmitted: (_) => _save(),
                        decoration: InputDecoration(
                          labelText: '手机口令',
                          hintText: '云端中继配置的 phone-pass',
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.key),
                          suffixIcon: IconButton(
                            tooltip: _obscureCredential ? '显示口令' : '隐藏口令',
                            icon: Icon(
                              _obscureCredential
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                            ),
                            onPressed: () => setState(
                              () => _obscureCredential = !_obscureCredential,
                            ),
                          ),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return '请输入手机口令';
                          }
                          return null;
                        },
                      ),
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
                      TextFormField(
                        controller: _lanCredentialController,
                        obscureText: _obscureCredential,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.password],
                        onFieldSubmitted: (_) => _save(),
                        decoration: InputDecoration(
                          labelText: '配对令牌',
                          hintText: '服务器打印的配对 URL 中的 token',
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.key),
                          suffixIcon: IconButton(
                            tooltip: _obscureCredential ? '显示令牌' : '隐藏令牌',
                            icon: Icon(
                              _obscureCredential
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                            ),
                            onPressed: () => setState(
                              () => _obscureCredential = !_obscureCredential,
                            ),
                          ),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return '请输入配对令牌';
                          }
                          return null;
                        },
                      ),
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
                      : const Text('保存并进入'),
                ),
                const SizedBox(height: DshTokens.space4),
                Text(
                  '· 手机口令/配对令牌仅在首次配对 URL 中出现,302 后即被剥除;\n'
                  '· 口令/令牌经 Android Keystore 加密存储,不明文落盘、不写日志;\n'
                  '· 公网服务器请务必使用 https://,避免凭据明文传输。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.6,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

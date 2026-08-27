import 'package:flutter/material.dart';

import '../config_store.dart';
import '../theme.dart';
import '../widgets/connection_mode_selector.dart';

/// 添加设备页:与首次配置页同构,但保存后把新设备加入设备列表并设为当前。
class DeviceEditorPage extends StatefulWidget {
  const DeviceEditorPage({super.key});

  @override
  State<DeviceEditorPage> createState() => _DeviceEditorPageState();
}

class _DeviceEditorPageState extends State<DeviceEditorPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _serverController = TextEditingController();
  final _credentialController = TextEditingController();
  bool _obscureCredential = true;
  bool _saving = false;
  ConnectionMode _mode = ConnectionMode.public;

  @override
  void dispose() {
    _nameController.dispose();
    _serverController.dispose();
    _credentialController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final config = AppConfig(
      mode: _mode,
      serverUrl: _serverController.text.trim(),
      token: _credentialController.text.trim(),
      name: _nameController.text.trim(),
    );
    setState(() => _saving = true);
    try {
      await ConfigStore().save(config);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('保存失败,请重试')),
      );
      return;
    }
    if (!mounted) return;
    final active = await ConfigStore().load();
    if (mounted && active != null) {
      Navigator.of(context).pop(active);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('添加设备')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: AutofillGroup(
            child: ListView(
              padding: const EdgeInsets.all(DshTokens.space4),
              children: [
                TextFormField(
                  controller: _nameController,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '设备名称(可选)',
                    hintText: 'Mac mini / Windows / Linux 开发机',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.computer),
                  ),
                ),
                const SizedBox(height: DshTokens.space4),
                Text('连接模式', style: theme.textTheme.labelLarge),
                const SizedBox(height: DshTokens.space2),
                ConnectionModeSelector(
                  value: _mode,
                  onChanged: (value) {
                    if (value == _mode) return;
                    setState(() {
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
                      : const Text('保存并切换到此设备'),
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
      onFieldSubmitted: (_) => _save(),
      decoration: InputDecoration(
        labelText: _mode == ConnectionMode.public ? '手机口令' : '配对令牌',
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
        if (value == null || value.trim().isEmpty) {
          return '请输入${_mode == ConnectionMode.public ? '手机口令' : '配对令牌'}';
        }
        return null;
      },
    );
  }
}

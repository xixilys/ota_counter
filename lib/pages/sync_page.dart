import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/sync_service.dart';
import '../widgets/app_page_background.dart';

class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();
  SyncSettings? _settings;
  Map<String, dynamic>? _serverStatus;
  bool _loading = true;
  bool _busy = false;
  bool _obscureToken = true;
  bool _autoSync = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final settings = await SyncService.loadSettings();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _urlController.text = settings.baseUrl;
      _tokenController.text = settings.token;
      _autoSync = settings.autoSync;
      _loading = false;
    });
    if (settings.isConfigured) {
      await _refreshStatus(silent: true);
    }
  }

  Future<SyncSettings> _persist() async {
    final current = _settings ??
        const SyncSettings(
          baseUrl: '',
          token: '',
          deviceId: '',
          autoSync: false,
          lastSyncAt: '',
        );
    final next = current.copyWith(
      baseUrl: _urlController.text.trim(),
      token: _tokenController.text.trim(),
      autoSync: _autoSync,
    );
    final saved = await SyncService.saveSettings(next);
    if (mounted) {
      setState(() {
        _settings = saved;
      });
    }
    return saved;
  }

  Future<void> _refreshStatus({bool silent = false}) async {
    final settings = _settings;
    if (settings == null || !settings.isConfigured) {
      if (!silent && mounted) {
        _showMessage('请先填写服务地址和 Token', isError: true);
      }
      return;
    }
    try {
      final status = await SyncService.testConnection(settings);
      if (!mounted) return;
      setState(() {
        _serverStatus = status;
        if (!silent) {
          _message = '连接正常';
          _messageIsError = false;
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _serverStatus = null;
        if (!silent) {
          _message = '$error';
          _messageIsError = true;
        }
      });
    }
  }

  Future<void> _testConnection() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await _persist();
      await _refreshStatus();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final settings = await _persist();
      final result = await SyncService.syncNow(settings);
      await _refreshStatus(silent: true);
      final refreshed = await SyncService.loadSettings();
      if (mounted) {
        setState(() => _settings = refreshed);
      }
      if (!mounted) return;
      setState(() {
        _message = result.hasFailures
            ? '同步完成，但 ${result.failures.length} 条操作需要处理'
            : '同步完成：应用 ${result.applied} 条，待执行 ${result.pending} 条';
        _messageIsError = result.hasFailures;
      });
      if (result.hasFailures) {
        await _showFailures(result.failures);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = '$error';
          _messageIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uploadOnly() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final settings = await _persist();
      final result = await SyncService.pushSnapshot(settings);
      await _refreshStatus(silent: true);
      final refreshed = await SyncService.loadSettings();
      if (mounted) {
        setState(() => _settings = refreshed);
      }
      if (!mounted) return;
      setState(() {
        _message = '快照已上传，服务端版本 ${result['rev'] ?? '-'}';
        _messageIsError = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = '$error';
          _messageIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pullOnly() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final settings = await _persist();
      final actions = await SyncService.pullActions(settings);
      final result = await SyncService.applyActions(settings, actions);
      if (!mounted) return;
      setState(() {
        _message = '拉取 ${actions.length} 条，应用 ${result.applied} 条';
        _messageIsError = result.hasFailures;
      });
      if (result.hasFailures) {
        await _showFailures(result.failures);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = '$error';
          _messageIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showFailures(List<SyncActionFailure> failures) async {
    if (!mounted || failures.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('部分操作未应用'),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final failure in failures.take(8))
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    '${failure.actionId}\n${failure.message}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (failures.length > 8) Text('还有 ${failures.length - 8} 条…'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  void _showMessage(String message, {required bool isError}) {
    setState(() {
      _message = message;
      _messageIsError = isError;
    });
  }

  Future<void> _copyMcpConfig() async {
    final config = '''{
  "mcpServers": {
    "ota-counter": {
      "command": "dart",
      "args": [
        "/path/to/ota_counter/mcp_server/bin/ota_sync_server.dart",
        "mcp"
      ]
    }
  }
}''';
    await Clipboard.setData(ClipboardData(text: config));
    if (mounted) {
      _showMessage('MCP 配置已复制，把路径换成仓库实际位置', isError: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('MCP 同步'),
        actions: [
          IconButton(
            onPressed: _busy ? null : () => _refreshStatus(),
            tooltip: '刷新服务状态',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: AppPageBackground(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
                children: [
                  _HeroCard(
                    configured: _settings?.isConfigured ?? false,
                  ),
                  const SizedBox(height: 14),
                  _SettingsCard(
                    urlController: _urlController,
                    tokenController: _tokenController,
                    obscureToken: _obscureToken,
                    autoSync: _autoSync,
                    onToggleToken: () {
                      setState(() => _obscureToken = !_obscureToken);
                    },
                    onAutoSyncChanged: (value) {
                      setState(() => _autoSync = value);
                    },
                    onSave: () async {
                      await _persist();
                      if (context.mounted) {
                        _showMessage('设置已保存', isError: false);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('设置已保存')),
                        );
                      }
                    },
                  ),
                  const SizedBox(height: 14),
                  _ActionCard(
                    busy: _busy,
                    onSync: _syncNow,
                    onUpload: _uploadOnly,
                    onPull: _pullOnly,
                    onTest: _testConnection,
                  ),
                  if (_message != null) ...[
                    const SizedBox(height: 12),
                    _MessageBar(
                      message: _message!,
                      isError: _messageIsError,
                    ),
                  ],
                  const SizedBox(height: 14),
                  _StatusCard(
                    status: _serverStatus,
                    settings: _settings,
                  ),
                  const SizedBox(height: 14),
                  _GuideCard(
                    onCopy: _copyMcpConfig,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '本服务只监听你启动的地址；所有私有接口都需要 Bearer Token。'
                    'Token 保存在本机 SharedPreferences 与服务端数据目录中。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  final bool configured;

  const _HeroCard({required this.configured});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          colors: [
            scheme.primaryContainer,
            scheme.secondaryContainer,
          ],
        ),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.16)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: scheme.surface.withValues(alpha: 0.7),
            ),
            child: Icon(
              Icons.hub_rounded,
              color: scheme.primary,
              size: 24,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  configured ? '已配置同步服务' : '连接你的 AI 助手',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '在电脑上运行 mcp_server，把地址和 Token 填进来。'
                  'Grok Bot / Hermes 通过 MCP 读取数据，新的切奇会回到 App 里执行。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.45,
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

class _SettingsCard extends StatelessWidget {
  final TextEditingController urlController;
  final TextEditingController tokenController;
  final bool obscureToken;
  final bool autoSync;
  final VoidCallback onToggleToken;
  final ValueChanged<bool> onAutoSyncChanged;
  final Future<void> Function() onSave;

  const _SettingsCard({
    required this.urlController,
    required this.tokenController,
    required this.obscureToken,
    required this.autoSync,
    required this.onToggleToken,
    required this.onAutoSyncChanged,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '连接设置',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlController,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '服务地址',
                hintText: 'http://192.168.1.20:8787',
                prefixIcon: Icon(Icons.link_rounded),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: tokenController,
              obscureText: obscureToken,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Token',
                hintText: 'mcp_server 启动时打印的 token',
                prefixIcon: const Icon(Icons.key_rounded),
                suffixIcon: IconButton(
                  onPressed: onToggleToken,
                  tooltip: obscureToken ? '显示 Token' : '隐藏 Token',
                  icon: Icon(
                    obscureToken
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded,
                  ),
                ),
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: autoSync,
              onChanged: onAutoSyncChanged,
              title: const Text('启动时自动同步'),
              subtitle: const Text('拉取待执行操作，并回传最新快照'),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onSave,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('保存设置'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final bool busy;
  final Future<void> Function() onSync;
  final Future<void> Function() onUpload;
  final Future<void> Function() onPull;
  final Future<void> Function() onTest;

  const _ActionCard({
    required this.busy,
    required this.onSync,
    required this.onUpload,
    required this.onPull,
    required this.onTest,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              onPressed: busy ? null : onSync,
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync_rounded, size: 19),
              label: Text(busy ? '同步中…' : '一键同步'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : onPull,
                    icon: const Icon(Icons.download_rounded, size: 17),
                    label: const Text('拉取操作'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : onUpload,
                    icon: const Icon(Icons.upload_rounded, size: 17),
                    label: const Text('上传快照'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: busy ? null : onTest,
              icon: const Icon(Icons.wifi_tethering_rounded, size: 17),
              label: const Text('测试连接'),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final Map<String, dynamic>? status;
  final SyncSettings? settings;

  const _StatusCard({required this.status, required this.settings});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final snapshot = status?['snapshot'];
    final snapshotMap =
        snapshot is Map ? Map<String, dynamic>.from(snapshot) : null;
    final actions = status?['actions'];
    final actionsMap =
        actions is Map ? Map<String, dynamic>.from(actions) : null;
    final lastSync = settings?.lastSyncAt ?? '';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '同步状态',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 12),
            if (status == null)
              Text(
                '尚未连接到同步服务。填好地址和 Token 后点“测试连接”。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else ...[
              _StatusRow(
                label: '服务版本',
                value: '${status?['name'] ?? '-'} ${status?['version'] ?? ''}',
              ),
              _StatusRow(
                label: '服务端版本号',
                value: '${status?['rev'] ?? '-'}',
              ),
              _StatusRow(
                label: '快照时间',
                value: _formatTime(
                  snapshotMap?['received_at'] ?? snapshotMap?['exported_at'],
                ),
              ),
              _StatusRow(
                label: '成员 / 记录',
                value: '${snapshotMap?['members'] ?? '-'} / '
                    '${snapshotMap?['records'] ?? '-'}',
              ),
              _StatusRow(
                label: '待执行 / 已应用',
                value: '${actionsMap?['pending'] ?? 0} / '
                    '${actionsMap?['applied'] ?? 0}',
              ),
            ],
            if (lastSync.isNotEmpty)
              _StatusRow(label: '本机上次同步', value: _formatTime(lastSync)),
          ],
        ),
      ),
    );
  }

  static String _formatTime(Object? value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '');
    if (parsed == null) return value?.toString() ?? '-';
    String two(int number) => number.toString().padLeft(2, '0');
    return '${parsed.year}-${two(parsed.month)}-${two(parsed.day)} '
        '${two(parsed.hour)}:${two(parsed.minute)}';
  }
}

class _StatusRow extends StatelessWidget {
  final String label;
  final String value;

  const _StatusRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            textAlign: TextAlign.right,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBar extends StatelessWidget {
  final String message;
  final bool isError;

  const _MessageBar({required this.message, required this.isError});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = isError ? scheme.error : scheme.tertiary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? Icons.error_outline_rounded : Icons.check_circle_outline,
            color: color,
            size: 19,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: color, fontSize: 12.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _GuideCard extends StatelessWidget {
  final VoidCallback onCopy;

  const _GuideCard({required this.onCopy});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '接入 Grok Bot / Hermes',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '1. 在电脑上运行 mcp_server（stdio 或 HTTP）。\n'
              '2. 把 stdio 配置加入 MCP 客户端，或把 HTTP 地址填到支持 HTTP MCP 的位置。\n'
              '3. App 里点“一键同步”即可读写同一份数据。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onCopy,
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text('复制 stdio MCP 配置'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/services/devices/dingtalk_a1/identity.dart';
import 'package:memorion/services/devices/dingtalk_a1/identity_file.dart';
import 'package:memorion/services/devices/dingtalk_a1/identity_store.dart';
import 'package:memorion/services/devices/dingtalk_a1/protocol.dart';
import 'package:memorion/services/devices/dingtalk_a1_connection.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';

String a1ErrorText(BuildContext context, Object? error) {
  final issue = error is A1Exception ? error.issue : null;
  return switch (issue) {
    A1Issue.identityRequired =>
      revampText(context, en: 'Sign in and add authorized A1 credentials to connect.', zh: '请登录并配置已获授权的 A1 设备凭据。'),
    A1Issue.authentication => revampText(context,
        en: 'A1 did not accept these credentials. Check its bound account.',
        zh: 'A1 鉴权失败，请核对设备绑定账号和凭据。'), // i18n-ignore: Bilingual via revampText.
    A1Issue.encryptedAudio => revampText(context,
        en: 'Encrypted recording. The original is kept; this format cannot be imported yet.',
        zh: '此录音已加密，原文件已保留，暂时无法导入。'),
    A1Issue.unsupportedAudio =>
      revampText(context, en: 'Unsupported or incomplete audio. The original is kept.', zh: '音频格式暂不支持或内容不完整，原文件已保留。'),
    A1Issue.busy =>
      revampText(context, en: 'A1 is busy or recording. Try after recording stops.', zh: 'A1 正在忙碌或录音，请在录音结束后重试。'),
    A1Issue.incompleteList => revampText(context,
        en: 'A1 returned an incomplete directory. Reconnect and refresh.', zh: 'A1 返回的文件目录不完整，请重新连接后刷新。'),
    A1Issue.retention => revampText(context,
        en: 'Check in DingTalk that automatic deletion after transfer is off, then retry. A1 has not confirmed that it will keep the original.',
        zh: '请在钉钉中确认已关闭传输后自动删除，再重试。A1 尚未确认会保留设备原文件。'),
    A1Issue.timeout || A1Issue.disconnected => revampText(context,
        en: 'Wake A1, release it in other apps, then reconnect.', zh: '请唤醒 A1，关闭其他 App 对它的连接，然后重新连接。'),
    _ => revampText(context,
        en: 'The operation did not finish. Reconnect or retry; device recordings are kept.',
        zh: '操作未完成，请重新连接或重试，设备上的录音会保留。'),
  };
}

Future<bool> ensureA1Identity(BuildContext context, BtDevice device) async {
  if (device.type != DeviceType.dingtalkA1) return true;
  final owner = A1DeviceConnection.currentOwner();
  if (owner.isNotEmpty) {
    try {
      if (await const A1IdentityStore().read(owner, device.id) != null) return true;
    } catch (_) {}
  }
  if (!context.mounted) return false;
  return await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => A1SetupPage(device: device))) == true;
}

class A1SetupPage extends StatefulWidget {
  final BtDevice device;
  final A1IdentityStore store;
  final String Function()? currentOwner;
  final Future<A1Identity?> Function()? pickIdentity;
  final Future<bool> Function(Uri)? openGuide;
  const A1SetupPage({
    super.key,
    required this.device,
    this.store = const A1IdentityStore(),
    this.currentOwner,
    this.pickIdentity,
    this.openGuide,
  });
  @override
  State<A1SetupPage> createState() => _A1SetupPageState();
}

class _A1SetupPageState extends State<A1SetupPage> {
  final _credentials = TextEditingController();
  bool _saving = false;
  bool _manual = false;
  bool _openingGuide = false;
  bool _guideFailed = false;
  String? _error;
  late final String _owner = (widget.currentOwner ?? A1DeviceConnection.currentOwner)();

  Uri get _guideUri => Uri.https(
      'memorion.me', '/${Localizations.localeOf(context).languageCode == 'zh' ? 'zh' : 'en'}/docs/dingtalk-a1');

  Future<void> _openGuide() async {
    if (_saving || _openingGuide) return;
    setState(() {
      _openingGuide = true;
      _guideFailed = false;
    });
    try {
      final opened =
          await (widget.openGuide?.call(_guideUri) ?? launchUrl(_guideUri, mode: LaunchMode.externalApplication));
      if (mounted) setState(() => _guideFailed = !opened);
    } catch (_) {
      if (mounted) setState(() => _guideFailed = true);
    } finally {
      if (mounted) setState(() => _openingGuide = false);
    }
  }

  @override
  void dispose() {
    _credentials.clear();
    _credentials.dispose();
    super.dispose();
  }

  Future<void> _save({bool fromFile = false}) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_owner.isEmpty || _owner != (widget.currentOwner ?? A1DeviceConnection.currentOwner)()) {
        throw const A1Exception(A1Issue.identityRequired);
      }
      final identity = fromFile
          ? await (widget.pickIdentity ?? pickA1IdentityFile)()
          : A1Identity.fromJson(_credentials.text.trim());
      if (!mounted || identity == null) return;
      if (_owner != (widget.currentOwner ?? A1DeviceConnection.currentOwner)()) {
        throw const A1Exception(A1Issue.identityRequired);
      }
      await widget.store.save(_owner, widget.device.id, identity);
      // Replacing credentials never silently enables upload of a prior owner's files.
      await widget.store.setAutoSync(_owner, widget.device.id, false);
      if (_owner != (widget.currentOwner ?? A1DeviceConnection.currentOwner)()) {
        throw const A1Exception(A1Issue.identityRequired);
      }
      _credentials.clear();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _error = fromFile && e is! A1Exception
            ? revampText(context,
                en: 'Could not import this authorization file. Choose the JSON file exported for this A1.',
                zh: '无法导入此授权文件，请选择为这台 A1 导出的 JSON 文件。')
            : e is FormatException
                ? revampText(context,
                    en: 'Check the JSON fields did, corp_id and device_secret (32 characters).',
                    zh: '请核对 JSON 中的 did、corp_id 和 device_secret（32 个字符）。')
                : a1ErrorText(context, e));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: JXB.bgApp,
        appBar: AppBar(
            backgroundColor: JXB.bgApp,
            foregroundColor: JXB.textPrimary,
            title: Text(revampText(context, en: 'Connect DingTalk A1', zh: '连接钉钉 A1'))),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          const Icon(Icons.laptop_mac_rounded, size: 40, color: JXB.brandPrimary),
          const SizedBox(height: 20),
          Text(
              revampText(context,
                  en: 'First-time setup needs a Mac.', zh: '首次配置需要一台 Mac。'), // i18n-ignore: Bilingual via revampText.
              style: JXB.body),
          const SizedBox(height: 12),
          Text(revampText(context,
              en: 'Follow the website guide on your Mac to create an authorization file, then send it to this phone and return here. No keys to type or JSON to edit. Everyday connections work directly over Bluetooth.',
              zh: '按官网指引在 Mac 生成授权文件，发送到这台手机，再回到这里导入。无需填写密钥或编辑 JSON；日常使用直接通过蓝牙连接。')),
          const SizedBox(height: 20),
          FilledButton.icon(
              key: const ValueKey('a1_setup_guide'),
              onPressed: _saving || _openingGuide ? null : _openGuide,
              icon: const Icon(Icons.open_in_new),
              label: Text(_openingGuide
                  ? revampText(context, en: 'Opening…', zh: '正在打开…')
                  : revampText(context, en: 'Open first-time setup guide', zh: '查看首次配置指引'))),
          if (_guideFailed) ...[
            const SizedBox(height: 12),
            Text(revampText(context,
                en: 'Could not open the browser. Copy the address below into Safari:',
                zh: '未能打开浏览器，请复制下方网址到 Safari 中打开：')),
            SelectableText(_guideUri.toString(), key: const ValueKey('a1_setup_guide_fallback')),
          ],
          const SizedBox(height: 24),
          Text(revampText(context, en: 'Already have the authorization file?', zh: '已经准备好授权文件？')),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
              key: const ValueKey('a1_import_credentials'),
              onPressed: _saving || _openingGuide ? null : () => _save(fromFile: true),
              icon: const Icon(Icons.file_open_outlined),
              label: Text(_saving
                  ? revampText(context, en: 'Saving…', zh: '保存中…')
                  : revampText(context, en: 'Import authorization file', zh: '导入授权文件'))),
          if (_error != null)
            Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(_error!, style: const TextStyle(color: JXB.error))),
          TextButton(
              key: const ValueKey('a1_manual_credentials'),
              onPressed: _saving
                  ? null
                  : () => setState(() {
                        _manual = !_manual;
                        _credentials.clear();
                        _error = null;
                      }),
              child: Text(_manual
                  ? revampText(context, en: 'Hide manual entry', zh: '收起手动输入')
                  : revampText(context, en: 'Advanced: paste credentials', zh: '高级：手动粘贴凭据'))),
          if (_manual) ...[
            TextField(
                key: const ValueKey('a1_credentials'),
                controller: _credentials,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                enabled: !_saving,
                decoration: InputDecoration(
                    labelText: revampText(context, en: 'Device credentials (JSON)', zh: '设备凭据（JSON）'),
                    helperText:
                        revampText(context, en: 'did · corp_id · device_secret', zh: 'did · corp_id · device_secret'),
                    border: const OutlineInputBorder())),
            const SizedBox(height: 12),
            OutlinedButton(
                key: const ValueKey('a1_save_credentials'),
                onPressed: _saving ? null : () => _save(),
                child: Text(revampText(context, en: 'Save credentials', zh: '保存凭据'))),
          ],
          const SizedBox(height: 16),
          Text(revampText(context,
              en: 'Credentials stay in secure storage on this phone. Choose which recordings to import after connecting; automatic sync starts off.',
              zh: '凭据保存在本机安全存储中。连接后可选择要导入的录音，自动同步默认关闭。')),
        ]),
      );
}

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/services/devices/plaud/identity.dart';
import 'package:memorion/services/devices/plaud/identity_file.dart';
import 'package:memorion/services/devices/plaud/identity_store.dart';
import 'package:memorion/services/devices/plaud/protocol.dart';
import 'package:memorion/services/devices/plaud_connection.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';

Uri plaudSetupGuideUri(BuildContext context) =>
    Uri.https('memorion.me', '/${Localizations.localeOf(context).languageCode == 'zh' ? 'zh' : 'en'}/docs/plaud-note');

String plaudErrorText(BuildContext context, Object? error) {
  final issue = error is PlaudException ? error.issue : null;
  return switch (issue) {
    PlaudIssue.identityRequired => revampText(context,
        en: 'Sign in to Memorion and import the authorization file for this Note.',
        zh: '请登录 Memorion，并导入这台 Note 的授权文件。'),
    PlaudIssue.authentication => revampText(context,
        en: 'Authorization does not match this Note. Use the PLAUD account already bound to it.',
        zh: '授权与这台 Note 不匹配，请使用设备原来绑定的 PLAUD 账号。'),
    PlaudIssue.unsupportedAudio => revampText(context,
        en: 'This audio format is not supported yet. The original is kept. Try a recording without short button presses.',
        zh: '此音频格式暂不支持，原文件已保留。可尝试录制一段中途不短按按键的录音。'),
    // i18n-ignore: English and Chinese are paired with revampText below.
    PlaudIssue.busy => revampText(context,
        en: 'Note is busy. Try again after the current operation finishes.', zh: 'Note 正在忙碌，请等待当前操作结束后重试。'),
    PlaudIssue.timeout || PlaudIssue.disconnected => revampText(context,
        en: 'Wake Note, close the official PLAUD app, then reconnect.', zh: '请唤醒 Note，关闭 PLAUD 官方 App，然后重新连接。'),
    _ => revampText(context,
        en: 'The operation did not finish. Reconnect and retry; device recordings are kept.',
        zh: '操作未完成，请重新连接后重试，设备上的录音会保留。'),
  };
}

Future<bool> ensurePlaudIdentity(BuildContext context, BtDevice device) async {
  if (device.type != DeviceType.plaudNote) return true;
  final owner = PlaudDeviceConnection.currentOwner();
  if (owner.isNotEmpty) {
    try {
      final identity = await const PlaudIdentityStore().read(owner, device.id);
      if (identity != null && identity.serial == device.plaudSerial) return true;
    } catch (_) {}
  }
  if (!context.mounted) return false;
  return await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => PlaudSetupPage(device: device))) ==
      true;
}

class PlaudSetupPage extends StatefulWidget {
  final BtDevice device;
  final PlaudIdentityStore store;
  final String Function()? currentOwner;
  final Future<PlaudIdentity?> Function()? pickIdentity;
  final Future<bool> Function(Uri)? openGuide;
  const PlaudSetupPage(
      {super.key,
      required this.device,
      this.store = const PlaudIdentityStore(),
      this.currentOwner,
      this.pickIdentity,
      this.openGuide});
  @override
  State<PlaudSetupPage> createState() => _PlaudSetupPageState();
}

class _PlaudSetupPageState extends State<PlaudSetupPage> {
  bool _saving = false, _openingGuide = false;
  String? _error;
  late final String _owner = (widget.currentOwner ?? PlaudDeviceConnection.currentOwner)();
  Uri get _guideUri => plaudSetupGuideUri(context);
  void _checkOwner() {
    if (_owner.isEmpty || _owner != (widget.currentOwner ?? PlaudDeviceConnection.currentOwner)()) {
      throw const PlaudException(PlaudIssue.identityRequired);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      _checkOwner();
      final identity = await (widget.pickIdentity ?? pickPlaudIdentityFile)();
      if (!mounted || identity == null) return;
      _checkOwner();
      if (identity.serial != widget.device.plaudSerial) throw const PlaudException(PlaudIssue.authentication);
      await widget.store.save(_owner, widget.device.id, identity);
      _checkOwner();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is PlaudException
            ? plaudErrorText(context, e)
            : revampText(context,
                en: 'Could not import this authorization file. Choose the file created for this Note.',
                zh: '无法导入此授权文件，请选择为这台 Note 生成的文件。'));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openGuide() async {
    if (_openingGuide) return;
    setState(() {
      _openingGuide = true;
      _error = null;
    });
    try {
      final opened =
          await (widget.openGuide?.call(_guideUri) ?? launchUrl(_guideUri, mode: LaunchMode.externalApplication));
      if (!opened) throw const FormatException();
    } catch (_) {
      if (mounted) {
        // i18n-ignore: English and Chinese are paired with revampText below.
        setState(() => _error = revampText(context,
            en: 'Could not open the guide. Copy the address below into your browser.', zh: '未能打开指引，请复制下方网址到浏览器。'));
      }
    } finally {
      if (mounted) setState(() => _openingGuide = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: JXB.bgApp,
        appBar: AppBar(
            backgroundColor: JXB.bgApp,
            foregroundColor: JXB.textPrimary,
            title: Text(revampText(context, en: 'Connect PLAUD Note', zh: '连接 PLAUD Note'))),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          const Icon(Icons.contactless_outlined, size: 40, color: JXB.brandPrimary),
          const SizedBox(height: 20),
          Text(revampText(context, en: 'Original Note', zh: '原版 Note'), style: JXB.body),
          const SizedBox(height: 12),
          Text(revampText(context,
              en: 'First-time setup uses a Mac and the PLAUD account already bound to your Note. Create an authorization file, send it to this phone, then import it here. Everyday transfers work directly over Bluetooth.',
              zh: '首次配置需在 Mac 上登录 Note 原来绑定的 PLAUD 账号，生成授权文件并发送到这台手机，再在此导入。日常传输直接通过蓝牙完成。')),
          const SizedBox(height: 20),
          OutlinedButton.icon(
              key: const ValueKey('plaud_setup_guide'),
              onPressed: _saving || _openingGuide ? null : _openGuide,
              icon: const Icon(Icons.open_in_new),
              label: Text(revampText(context, en: 'Open setup guide', zh: '查看配置指引'))),
          const SizedBox(height: 12),
          FilledButton.icon(
              key: const ValueKey('plaud_import_credentials'),
              onPressed: _saving || _openingGuide ? null : _save,
              icon: const Icon(Icons.file_open_outlined),
              label: Text(_saving
                  ? revampText(context, en: 'Saving…', zh: '保存中…')
                  : revampText(context, en: 'Import authorization file', zh: '导入授权文件'))),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: const TextStyle(color: JXB.error)),
            SelectableText(_guideUri.toString()),
          ],
          const SizedBox(height: 20),
          Text(revampText(context,
              en: 'Authorization stays in secure storage on this phone. Once connected, completed recordings automatically sync to Memorion for transcription and summaries. Close the official PLAUD app before connecting.',
              zh: '授权保存在本机安全存储中。连接后，已完成的录音会自动同步到 Memorion，生成转录和总结。连接前请关闭 PLAUD 官方 App。')),
        ]),
      );
}

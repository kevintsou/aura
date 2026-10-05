import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aura_core/aura_core.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';

const accountIcons = <String, (String, IconData)>{
  'wallet': ('錢包', Icons.account_balance_wallet_outlined),
  'cash': ('現金', Icons.payments_outlined),
  'bank': ('銀行', Icons.account_balance_outlined),
  'card': ('信用卡', Icons.credit_card_outlined),
  'phone': ('電子支付', Icons.phone_android_outlined),
  'investment': ('投資', Icons.trending_up),
  'savings': ('儲蓄', Icons.savings_outlined),
  'travel': ('旅遊', Icons.flight_outlined),
  'work': ('工作', Icons.work_outline),
  'home': ('家庭', Icons.home_outlined),
};

String accountIconKey(String id) => 'ui.accountIcon.$id';

String defaultAccountIcon(AccountType type) => switch (type) {
  AccountType.cash => 'cash',
  AccountType.bank => 'bank',
  AccountType.credit => 'card',
  AccountType.epay => 'phone',
  AccountType.securities => 'investment',
  AccountType.other => 'wallet',
};

class AccountIcon extends StatelessWidget {
  const AccountIcon({super.key, required this.value, required this.type, this.size = 32});
  final String? value;
  final AccountType type;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Icon(accountIcons[value]?.$2 ?? accountIcons[defaultAccountIcon(type)]!.$2, size: size);
    if (value?.startsWith('image:') ?? false) {
      try {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            base64Decode(value!.substring(6)),
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => fallback,
          ),
        );
      } on FormatException {
        return fallback;
      }
    }
    return fallback;
  }
}

/// Produces a small square PNG without retaining the source metadata.
Future<String> prepareAccountImage(Uint8List bytes) async {
  if (bytes.length > 10 * 1024 * 1024) throw const FormatException('請選擇 10 MB 以下的圖片');
  final codec = await ui.instantiateImageCodec(bytes, targetWidth: 256);
  try {
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final side = image.width < image.height ? image.width.toDouble() : image.height.toDouble();
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawImageRect(
        image,
        Rect.fromLTWH((image.width - side) / 2, (image.height - side) / 2, side, side),
        const Rect.fromLTWH(0, 0, 128, 128),
        Paint(),
      );
      final picture = recorder.endRecording();
      try {
        final thumbnail = await picture.toImage(128, 128);
        try {
          final data = await thumbnail.toByteData(format: ui.ImageByteFormat.png);
          return 'image:${base64Encode(data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes))}';
        } finally {
          thumbnail.dispose();
        }
      } finally {
        picture.dispose();
      }
    } finally {
      image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

class AccountIconField extends StatefulWidget {
  const AccountIconField({
    super.key,
    required this.app,
    required this.value,
    required this.type,
    required this.onChanged,
  });
  final AppState app;
  final String? value;
  final AccountType type;
  final ValueChanged<String?> onChanged;

  @override
  State<AccountIconField> createState() => _AccountIconFieldState();
}

class _AccountIconFieldState extends State<AccountIconField> {
  bool _busy = false;
  String? _error;

  Future<void> _upload() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await widget.app.lock.whileAway(() => widget.app.photoPicker.pick(camera: false));
      if (bytes == null || !mounted) return;
      final value = await prepareAccountImage(bytes);
      if (mounted) widget.onChanged(value);
    } on Object {
      if (mounted) setState(() => _error = '無法讀取圖片，請選擇 10 MB 以下的有效圖片');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('帳戶圖示', style: theme.textTheme.titleSmall),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(16)),
            child: Row(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: scheme.surface, borderRadius: BorderRadius.circular(12)),
                  child: AccountIcon(value: widget.value, type: widget.type, size: 40),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      OutlinedButton.icon(
                        key: const Key('uploadAccountIcon'),
                        onPressed: _busy ? null : _upload,
                        icon: const Icon(Icons.upload_outlined, size: 18),
                        label: Text(_busy ? '處理中…' : '上傳自己的圖片'),
                      ),
                      const SizedBox(height: 6),
                      Text('置中裁成正方形，按儲存後套用。', style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final columns = (constraints.maxWidth / 100).floor().clamp(3, 6);
                  final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
                  Widget option(String? value, String label, IconData icon, {Key? key}) {
                    final selected = widget.value == value;
                    final color = selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
                    return SizedBox(
                      width: width,
                      child: Semantics(
                        selected: selected,
                        button: true,
                        child: Material(
                          color: selected ? scheme.secondaryContainer : scheme.surface,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color: selected ? scheme.primary : scheme.outlineVariant,
                              width: selected ? 1.5 : 1,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            key: key,
                            onTap: _busy ? null : () => widget.onChanged(value),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                              child: Column(
                                children: [
                                  Icon(icon, size: 26, color: color),
                                  const SizedBox(height: 8),
                                  Text(
                                    label,
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.labelMedium?.copyWith(color: color),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }

                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      option(null, '依帳戶類型', Icons.auto_awesome_outlined),
                      for (final entry in accountIcons.entries)
                        option(entry.key, entry.value.$1, entry.value.$2, key: Key('accountIcon-${entry.key}')),
                    ],
                  );
                },
              ),
            ),
          ),
          if (_error != null) ...[const SizedBox(height: 12), Text(_error!, style: TextStyle(color: scheme.error))],
        ],
      ),
    );
  }
}

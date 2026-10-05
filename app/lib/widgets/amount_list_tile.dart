import 'package:flutter/material.dart';

/// Keeps the amount readable when the row is narrow or text is enlarged.
class AmountListTile extends StatelessWidget {
  const AmountListTile({
    super.key,
    required this.title,
    required this.trailing,
    this.subtitle,
    this.leading,
    this.onTap,
    this.contentPadding,
    this.isThreeLine = false,
  });
  final Widget title;
  final Widget trailing;
  final Widget? subtitle;
  final Widget? leading;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? contentPadding;
  final bool isThreeLine;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final stacked = constraints.maxWidth < 480 || MediaQuery.textScalerOf(context).scale(18) > 23;
      return ListTile(
        contentPadding: contentPadding,
        leading: leading,
        onTap: onTap,
        isThreeLine: !stacked && isThreeLine,
        title: stacked
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [title, const SizedBox(height: 6), trailing],
              )
            : title,
        subtitle: subtitle,
        trailing: stacked ? null : trailing,
        minVerticalPadding: 12,
      );
    },
  );
}

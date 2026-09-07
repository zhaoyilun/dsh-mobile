import 'package:flutter/material.dart';

import '../theme.dart';

/// 原生壳统一品牌标识:蓝底 DNS/节点图标,配置页与加载页共用。
///
/// 图标沿用 dc-mobile 设置页的 `Icons.dns_outlined`,在原生壳中保持
/// 同一视觉记忆点,不额外引入图片资源。
class DshBrandMark extends StatelessWidget {
  const DshBrandMark({super.key, this.size = 48});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: DshTokens.kleinBlueSoft,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.dns_outlined,
        size: size * 0.52,
        color: DshTokens.kleinBlue,
      ),
    );
  }
}

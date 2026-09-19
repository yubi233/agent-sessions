import 'package:flutter/material.dart';

/// v0.5 resident conversation shell。
///
/// 该组件只负责固定页面骨架：header、conversation scroll owner 和 sticky composer seat。
/// Chat / Trajectory / Composer 的业务动作仍由各自 controller 处理，避免 root 直接拼写命令。
class SessionConversationRoot extends StatelessWidget {
  const SessionConversationRoot({
    required this.header,
    required this.activeView,
    required this.composer,
    super.key,
  });

  final Widget header;
  final Widget activeView;
  final Widget composer;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: true,
      child: Column(
        key: const Key('session-conversation-root'),
        children: [
          header,
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  children: [
                    // V094-20（收口）：conversation 滚动区与 composer seat 弹性
                    // 共享剩余高度——基准字号下 seat 自然高（≤144 预算）优先，
                    // conversation 拿走其余；大字/重 dock 下 seat 自然高超过
                    // 分配额时 seat 内部滚动（loose flex 收缩），不再溢出。
                    Expanded(
                      flex: 3,
                      child: KeyedSubtree(
                        key: const Key('session-conversation-scroll-owner'),
                        child: activeView,
                      ),
                    ),
                    Flexible(
                      flex: 2,
                      child: KeyedSubtree(
                        key: const Key('session-composer-seat'),
                        child: ConstrainedBox(
                          // v0.5/P1：composer seat 是 sticky 边界；pending 面板或附件增高时只在 seat 内滚动，
                          // 不能把 conversation view 挤到负高度或触发 RenderFlex overflow。
                          constraints: const BoxConstraints(maxHeight: 300),
                          child: SingleChildScrollView(
                            primary: false,
                            child: composer,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

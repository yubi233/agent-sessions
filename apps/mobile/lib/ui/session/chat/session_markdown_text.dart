// 会话消息 Markdown 渲染器（v0.8.6 D 组 / G10）。
//
// 使用 Dart 官方 `markdown` 包把 GFM 文本解析为 AST 后自建 Widget 树：
// - 语法面：多级标题、GFM 表格、有序/无序/嵌套列表、引用块、代码块、
//   水平线、行内粗体/斜体/行内代码/删除线/链接；
// - display-safe 边界（fail-closed，与仓库口径一致）：
//   * 原始 HTML 一律不渲染（白名单标签之外的节点只渲染其纯文本子节点）；
//   * 图片不渲染、不发起任何网络请求（只显示 alt 文本占位）；
//   * 链接渲染为带下划线的文本，不注册点击导航（避免静默外跳）。
// - 流式安全：partial 文本（未闭合 `**`、未完成表格行）按普通段落降级，
//   不会抛错；上层以 ~2Hz 快照合并频率重渲染，无需额外节流。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_theme.dart';
import 'package:markdown/markdown.dart' as md;

/// 单条会话消息的 Markdown 渲染入口。
class SessionMarkdownText extends StatelessWidget {
  const SessionMarkdownText({
    required this.text,
    this.color,
    this.baseStyle,
    this.maxWidth = 640,
    super.key,
  });

  final String text;
  final Color? color;
  final TextStyle? baseStyle;

  /// 表格等块级内容的最大宽度约束，防止超宽表格把气泡撑破。
  final double maxWidth;

  /// 危险 HTML 标签黑名单：整棵子树直接丢弃（连纯文本都不显示）。
  static const _droppedHtmlTags = {'script', 'style', 'iframe', 'object', 'embed'};

  static final md.Document _document = md.Document(
    encodeHtml: false,
    extensionSet: md.ExtensionSet.gitHubFlavored,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // V094-17（UI-17）：前景色参数必须参与默认 style——旧实现 color 参数被
    // 忽略，深色气泡（用户消息 primaryContainer）里的 Markdown 回退主题
    // 默认前景色，暗色主题下对比度错误。
    final style = (baseStyle ?? theme.textTheme.bodyMedium)?.copyWith(
      color: color ?? (baseStyle ?? theme.textTheme.bodyMedium)?.color,
    );
    final nodes = _document.parseLines(text.split('\n'));
    return Column(
      key: const Key('session-assistant-markdown'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final node in nodes) _buildBlock(context, node, style),
      ],
    );
  }

  Widget _buildBlock(BuildContext context, md.Node node, TextStyle? style) {
    // v0.8.6 D：原始 HTML 块（UnparsedContent）整体丢弃——display-safe
    // fail-closed，绝不让脚本内容以任何形式进入时间线。
    if (node is md.UnparsedContent) return const SizedBox.shrink();
    if (node is md.Element && _droppedHtmlTags.contains(node.tag)) {
      return const SizedBox.shrink();
    }
    if (node is md.Text) {
      // markdown 包把原始 HTML 块投影为纯 Text 节点（转义文本）。启发式：
      // 整段形如 "<...>" 的节点视为原始 HTML，整体丢弃而不是当正文显示。
      if (_looksLikeRawHtml(node.text)) return const SizedBox.shrink();
      return Text(node.text, style: style);
    }
    if (node is! md.Element) {
      return const SizedBox.shrink();
    }
    final tag = node.tag;
    switch (tag) {
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        final level = int.parse(tag.substring(1));
        return Padding(
          padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.micro),
          child: Text(
            _inlinePlainText(node),
            style: _headingStyle(context, level, style),
          ),
        );
      case 'p':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.micro),
          child: _buildInline(context, node, style),
        );
      case 'ul':
      case 'ol':
        return _buildList(context, node, style, ordered: tag == 'ol');
      case 'blockquote':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.micro),
          child: Container(
            padding: const EdgeInsets.fromLTRB(AppSpacing.sm, AppSpacing.xs, AppSpacing.sm, AppSpacing.xs),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  width: 3,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            ),
            child: _buildInline(context, node, style),
          ),
        );
      case 'pre':
        // 围栏代码块：AST 中 pre 的唯一子节点是 code element；
        // V094-13（UI-13）：语言信息在 code.attributes['class']
        // （形如 language-bash）——只展示该可信来源，缺失时显示「代码」。
        final code = _inlinePlainText(node);
        var language = '';
        for (final child in node.children ?? const <md.Node>[]) {
          if (child is md.Element && child.tag == 'code') {
            final cssClass = child.attributes['class'] ?? '';
            if (cssClass.startsWith('language-')) {
              language = cssClass.substring('language-'.length).trim();
            }
          }
        }
        return _MarkdownCodeBlock(text: code, language: language);
      case 'hr':
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Divider(),
        );
      case 'table':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          // V094-12（UI-12）：表格宽度从 LayoutBuilder 的实际可用宽度派生
          // （不再固定 640），仅在真正溢出时显示横滚提示。
          child: _OverflowAwareTable(
            buildTable: (maxWidth) => _buildTable(context, node, style, maxWidth: maxWidth),
          ),
        );
      default:
        // 未知块级节点（含 raw HTML）：只渲染其纯文本子节点，标签与属性
        // 一概丢弃——HTML 注入在渲染层被结构性排除。
        final text = _inlinePlainText(node);
        return text.isEmpty
            ? const SizedBox.shrink()
            : Text(text, style: style);
    }
  }

  TextStyle? _headingStyle(BuildContext context, int level, TextStyle? style) {
    final base = Theme.of(context).textTheme;
    final sized = switch (level) {
      1 => base.titleLarge,
      2 => base.titleMedium,
      3 => base.titleSmall,
      _ => base.labelLarge,
    };
    return (sized ?? style)?.copyWith(
      fontWeight: FontWeight.w700,
      color: style?.color,
    );
  }

  /// 无序列表：`-` 行；有序列表：AST 中 li 的 marker 文本由列表类型决定。
  Widget _buildList(
    BuildContext context,
    md.Element node,
    TextStyle? style, {
    required bool ordered,
  }) {
    final children = <Widget>[];
    var index = 0;
    for (final child in node.children ?? const <md.Node>[]) {
      if (child is! md.Element || child.tag != 'li') continue;
      index += 1;
      final marker = ordered ? '$index. ' : '• ';
      final nested = child.children
          ?.whereType<md.Element>()
          .where((element) => element.tag == 'ul' || element.tag == 'ol')
          .toList();
      final textOnly = md.Element('p', child.children);
      children.add(
        Padding(
          key: ValueKey('md-li-$index-${child.textContent.hashCode}'),
          padding: const EdgeInsets.only(left: AppSpacing.xs, top: AppSpacing.micro),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(marker, style: style),
              Expanded(child: _buildInline(context, textOnly, style)),
            ],
          ),
        ),
      );
      // 嵌套列表：递归渲染并整体缩进。
      for (final element in nested ?? const <md.Element>[]) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.lg),
            child: _buildList(
              context,
              element,
              style,
              ordered: element.tag == 'ol',
            ),
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  /// GFM 表格：首行 thead，其后 tbody 行；列数以表头为准。
  /// V094-12（UI-12）：列内容按实际可用宽度换行；单元格含长无空格 token
  /// （TextPainter 单行测量超过列上限）时该 cell 内部横向滚动（maxLines 1，
  /// 不靠视觉折行改变内容），并在表格下方显示仅溢出时出现的滚动提示。
  Widget _buildTable(
    BuildContext context,
    md.Element node,
    TextStyle? style, {
    required double maxWidth,
  }) {
    final head = node.children?.whereType<md.Element>().firstOrNull;
    final body = node.children
            ?.whereType<md.Element>()
            .skip(1)
            .expand((element) => element.children ?? const <md.Node>[])
            .whereType<md.Element>()
            .toList() ??
        const <md.Element>[];
    final headerCells = head?.children
            ?.expand(
              (element) => element is md.Element
                  ? element.children ?? const <md.Node>[]
                  : const <md.Node>[],
            )
            .whereType<md.Element>()
            .toList() ??
        const <md.Element>[];
    if (headerCells.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final headerStyle = (style ?? theme.textTheme.bodyMedium)
        ?.copyWith(fontWeight: FontWeight.w700);
    final borderWidth = BorderSide(color: theme.dividerColor);
    // 每列内容宽上限：可用宽度 / 列数（下限 96dp，防极窄列完全不可读）。
    final cellMax = (maxWidth / headerCells.length).clamp(96.0, maxWidth);

    // 溢出判定：单行自然宽度超过列上限 → 该 cell 单行横滚。
    bool overflows(String plainText, TextStyle? effectiveStyle) {
      if (plainText.isEmpty) return false;
      final painter = TextPainter(
        text: TextSpan(text: plainText, style: effectiveStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width > cellMax - AppSpacing.sm * 2;
    }

    Widget cellContent(
      md.Element cell, {
      required TextStyle? effectiveStyle,
    }) {
      final plain = cell.textContent;
      if (overflows(plain, effectiveStyle)) {
        // 长无空格内容：单行 + 内部横向滚动（不换行、不裁切语义）。
        return SizedBox(
          width: cellMax - AppSpacing.sm * 2,
          child: SingleChildScrollView(
            key: const Key('session-table-cell-scroll'),
            scrollDirection: Axis.horizontal,
            child: Text(plain, style: effectiveStyle, maxLines: 1),
          ),
        );
      }
      return _buildInline(context, cell, effectiveStyle);
    }

    final hasOverflow = headerCells.any(
          (cell) => overflows(cell.textContent, headerStyle),
        ) ||
        body.any(
          (row) => (row.children ?? const <md.Node>[]).any(
            (cell) => overflows(
              cell is md.Element ? cell.textContent : '',
              style,
            ),
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Table(
          border: TableBorder(
            horizontalInside: borderWidth,
            verticalInside: borderWidth,
            top: borderWidth,
            bottom: borderWidth,
            left: borderWidth,
            right: borderWidth,
          ),
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          columnWidths: {
            for (var i = 0; i < headerCells.length; i++)
              i: FixedColumnWidth(cellMax),
          },
          children: [
            TableRow(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh,
              ),
              children: [
                for (final cell in headerCells)
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    child: cellContent(cell, effectiveStyle: headerStyle),
                  ),
              ],
            ),
            for (final row in body)
              TableRow(
                children: [
                  for (final cell in row.children ?? const <md.Node>[])
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.sm),
                      child: cellContent(
                        cell is md.Element ? cell : md.Element('p', [cell]),
                        effectiveStyle: style,
                      ),
                    ),
                ],
              ),
          ],
        ),
        // 仅溢出时出现的滚动提示（计划 §3.3：不修改表格语义）。
        if (hasOverflow)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.micro),
            child: Row(
              key: const Key('session-table-overflow-hint'),
              children: [
                Icon(
                  Icons.swipe_left_outlined,
                  size: AppSizes.iconSm,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.micro),
                Text(
                  '表格超宽，左右滑动查看',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 行内内容：遍历 AST 子节点拼 InlineSpan；链接渲染为下划线文本（不导航），
  /// 图片降级为 alt 文本，HTML 子树只取纯文本。
  Widget _buildInline(BuildContext context, md.Node node, TextStyle? style) {
    final spans = _inlineSpans(context, node, style);
    return Text.rich(TextSpan(style: style, children: spans));
  }

  List<InlineSpan> _inlineSpans(
    BuildContext context,
    md.Node node,
    TextStyle? style,
  ) {
    final theme = Theme.of(context);
    final spans = <InlineSpan>[];
    // 行内原始 HTML 同样丢弃；危险标签整棵子树不显示。
    if (node is md.UnparsedContent) return spans;
    if (node is md.Element && _droppedHtmlTags.contains(node.tag)) {
      return spans;
    }
    if (node is md.Text) {
      if (_looksLikeRawHtml(node.text)) return spans;
      spans.add(TextSpan(text: node.text, style: style));
      return spans;
    }
    if (node is! md.Element) return spans;
    switch (node.tag) {
      case 'strong':
        spans.add(
          TextSpan(
            text: node.textContent,
            style: style?.copyWith(fontWeight: FontWeight.w700),
          ),
        );
      case 'em':
        spans.add(
          TextSpan(
            text: node.textContent,
            style: style?.copyWith(fontStyle: FontStyle.italic),
          ),
        );
      case 'code':
        spans.add(
          TextSpan(
            text: node.textContent,
            style: style?.copyWith(
              fontFamily: 'monospace',
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        );
      case 'del':
        spans.add(
          TextSpan(
            text: node.textContent,
            style: style?.copyWith(decoration: TextDecoration.lineThrough),
          ),
        );
      case 'a':
        // 链接 fail-closed：显示带下划线的可读文本，不注册任何点击导航。
        spans.add(
          TextSpan(
            text: node.textContent,
            style: style?.copyWith(
              color: theme.colorScheme.primary,
              decoration: TextDecoration.underline,
            ),
          ),
        );
      case 'img':
        // 图片不渲染、不加载：只显示 alt 文本占位（markdown 包把 alt 放在
        // attributes.alt，children 为空）。
        final alt = node.attributes['alt'];
        spans.add(
          TextSpan(
            text: '［图片：${alt ?? node.textContent}］',
            style: style?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        );
      default:
        for (final child in node.children ?? const <md.Node>[]) {
          spans.addAll(_inlineSpans(context, child, style));
        }
    }
    return spans;
  }
}

/// 判断文本是否是"整段原始 HTML"（以 < 开头、以 > 结尾且不含空白间隙外
/// 的普通结尾）。启发式仅用于丢弃判定；误伤面极小（正常消息不会整体
/// 包裹成尖括号）。
bool _looksLikeRawHtml(String text) {
  final trimmed = text.trim();
  return trimmed.startsWith('<') && trimmed.endsWith('>');
}

/// 提取节点内全部纯文本（忽略标签与属性），供标题/未知块降级渲染。
String _inlinePlainText(md.Element node) => node.textContent;

/// V094-12（UI-12）：表格容器。表格本体按实际可用宽度换行布局；
/// 仅当存在无法断行的超宽内容（长无空格 token）时该列内部横向滚动，
/// 并显示「左右滑动查看」提示（不修改表格语义）。
class _OverflowAwareTable extends StatelessWidget {
  const _OverflowAwareTable({required this.buildTable});

  final Widget Function(double maxWidth) buildTable;

  @override
  Widget build(BuildContext context) {
    // 宽度约束来自 bubble 内实际可用宽度；无界约束（极窄场景）回退保守值。
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 320.0;
        return buildTable(maxWidth);
      },
    );
  }
}

/// V094-13（UI-13）围栏代码块：可信语言标签（缺失显示「代码」）+ 一键复制
/// 原始文本（保留换行/缩进）+ 长代码展开/收起；长行内部横向滚动，
/// 不靠视觉折行改变复制值。display-safe 边界不变（不执行、不导航）。
class _MarkdownCodeBlock extends StatefulWidget {
  const _MarkdownCodeBlock({required this.text, required this.language});

  final String text;

  /// 来自 fence info string 的可信语言名；空串表示未声明。
  final String language;

  @override
  State<_MarkdownCodeBlock> createState() => _MarkdownCodeBlockState();
}

class _MarkdownCodeBlockState extends State<_MarkdownCodeBlock> {
  static const _maxHeight = 240.0;
  bool _expanded = false;
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 长代码判定：估算行数 × 单行高（mono 13/1.3 ≈ 18dp）超过限高即提供展开。
    final lineCount = '\n'.allMatches(widget.text).length + 1;
    final needsExpand = lineCount * 18 > _maxHeight;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        key: const Key('session-code-block'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 头部：语言标签（缺失显示「代码」）+ 复制 + 展开/收起。
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.sm, AppSpacing.micro, AppSpacing.xs, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.language.isEmpty ? '代码' : widget.language,
                    key: const Key('session-code-language'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('session-code-copy'),
                  tooltip: '复制代码',
                  visualDensity: VisualDensity.compact,
                  iconSize: AppSizes.iconSm,
                  onPressed: () async {
                    // 复制原始文本：保留换行/缩进，不因渲染折行改变内容。
                    await Clipboard.setData(ClipboardData(text: widget.text));
                    if (!mounted) return;
                    setState(() => _copied = true);
                    await Future<void>.delayed(const Duration(seconds: 2));
                    if (mounted) setState(() => _copied = false);
                  },
                  icon: Icon(
                    _copied ? Icons.check_outlined : Icons.copy_outlined,
                    size: AppSizes.iconSm,
                    color: _copied ? theme.colorScheme.primary : null,
                  ),
                ),
                if (needsExpand)
                  IconButton(
                    key: const Key('session-code-expand'),
                    tooltip: _expanded ? '收起代码' : '展开全部代码',
                    visualDensity: VisualDensity.compact,
                    iconSize: AppSizes.iconSm,
                    onPressed: () => setState(() => _expanded = !_expanded),
                    icon: Icon(
                      _expanded
                          ? Icons.unfold_less_outlined
                          : Icons.unfold_more_outlined,
                      size: AppSizes.iconSm,
                    ),
                  ),
              ],
            ),
          ),
          Flexible(
            child: Container(
              constraints: _expanded
                  ? const BoxConstraints(maxHeight: 600)
                  : const BoxConstraints(maxHeight: _maxHeight - 32),
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: SingleChildScrollView(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  // 长行内部横向滚动：不靠视觉折行改变复制值（计划 §3.3）。
                  child: SelectableText(
                    widget.text,
                    style: AppTypography.mono.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

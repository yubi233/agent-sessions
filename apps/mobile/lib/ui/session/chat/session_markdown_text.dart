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
    final style = baseStyle ?? theme.textTheme.bodyMedium;
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
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Text(
            _inlinePlainText(node),
            style: _headingStyle(context, level, style),
          ),
        );
      case 'p':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: _buildInline(context, node, style),
        );
      case 'ul':
      case 'ol':
        return _buildList(context, node, style, ordered: tag == 'ol');
      case 'blockquote':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 4, 8, 4),
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
        // 围栏代码块：AST 中 pre 的唯一子节点是 code element。
        final code = _inlinePlainText(node);
        return _MarkdownCodeBlock(text: code);
      case 'hr':
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Divider(),
        );
      case 'table':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _buildTable(context, node, style),
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
          padding: const EdgeInsets.only(left: 4, top: 2),
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
            padding: const EdgeInsets.only(left: 16),
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
  Widget _buildTable(BuildContext context, md.Element node, TextStyle? style) {
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
    final headerStyle = (style ?? Theme.of(context).textTheme.bodyMedium)
        ?.copyWith(fontWeight: FontWeight.w700);
    final borderWidth = BorderSide(color: Theme.of(context).dividerColor);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: maxWidth * 0.6, maxWidth: maxWidth),
        child: Table(
          border: TableBorder(
            horizontalInside: borderWidth,
            verticalInside: borderWidth,
            top: borderWidth,
            bottom: borderWidth,
            left: borderWidth,
            right: borderWidth,
          ),
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            TableRow(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
              ),
              children: [
                for (final cell in headerCells)
                  Padding(
                    padding: const EdgeInsets.all(6),
                    child: _buildInline(context, cell, headerStyle),
                  ),
              ],
            ),
            for (final row in body)
              TableRow(
                children: [
                  for (final cell in row.children ?? const <md.Node>[])
                    Padding(
                      padding: const EdgeInsets.all(6),
                      child: _buildInline(
                        context,
                        cell is md.Element ? cell : md.Element('p', [cell]),
                        style,
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
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

/// 围栏代码块容器：等宽字体 + 可滚动 + 可选择，限高防止长代码占满气泡。
class _MarkdownCodeBlock extends StatelessWidget {
  const _MarkdownCodeBlock({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    constraints: const BoxConstraints(maxHeight: 240),
    margin: const EdgeInsets.symmetric(vertical: 4),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
    ),
    child: SingleChildScrollView(
      child: SelectableText(
        text,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      ),
    ),
  );
}

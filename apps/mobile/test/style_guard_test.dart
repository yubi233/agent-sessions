// v0.9.0 B3（V090-12）：样式规范机器执法守卫（Wave 1）。
// 基于 Dart analyzer AST 扫描 `lib/**/*.dart`（`lib/protocol/` 生成代码豁免），
// 禁止用正则或手写字符串剥离判断语法节点（注释/字符串/嵌套表达式不误报）。
//
// Wave 1 规则（规范 §8）：
//   - 禁 `Color(0x…)` 字面量（豁免：app_theme.dart，token 唯一定义点）；
//   - 禁裸 `Colors.*`（`Colors.transparent` 除外）；
//   - 禁 `fontSize:`（豁免：token 定义点）；
//   - 禁带数字参数的 `BorderRadius.circular(` / `Radius.circular(`。
//
// Wave 2 规则（规范 §8，B5 追加）：SizedBox(height/width:) 与 EdgeInsets.*
// 通用间距必须引用 AppSpacing.*（0 允许、具名布局常量 AppLayout.* 允许）；
// Icon(size:)/IconButton(iconSize:) 必须引用 AppSizes.*。
// 正负 fixture 见 main 内用例：违规样例被拦截、token 样例放行、注释与字符串不误报。
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:flutter_test/flutter_test.dart';

/// token 定义点豁免（规范 §8 Wave 1）。
const tokenDefinitionFiles = {'app_theme.dart'};

/// 生成代码豁免目录（协议生成物不可手写，也不参与样式执法）。
const excludedDirSegments = {'protocol'};

void main() {
  test('Wave 1 守卫：lib/** 全量扫描零违规（色彩/字号/圆角）', () {
    final libDir = Directory('lib');
    final files = libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where(
          (f) => !excludedDirSegments.any((segment) => f.path.contains(segment)),
        )
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final violations = <String>[];
    for (final file in files) {
      final fileName = file.uri.pathSegments.last;
      violations.addAll(
        scanWave1(
          file.path,
          file.readAsStringSync(),
          isTokenFile: tokenDefinitionFiles.contains(fileName),
        ),
      );
    }

    expect(
      violations,
      isEmpty,
      reason: '样式规范 Wave 1 违规（豁免仅 token 定义点 app_theme.dart）：\n'
          '${violations.join('\n')}',
    );
  });

  test('Wave 1 正向 fixture：token 消费样例全部放行', () {
    const source = '''
import 'package:flutter/material.dart';

Widget ok(BuildContext context) {
  return DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(AppRadius.card),
    ),
    child: Text(
      'ok',
      style: Theme.of(context).textTheme.bodyMedium!
          .copyWith(color: Colors.transparent),
    ),
  );
}
''';
    expect(scanWave1('fixture_ok.dart', source), isEmpty);
  });

  test('Wave 1 负向 fixture：裸色/字号/圆角/十六进制色全部拦截，注释与字符串不误报', () {
    const source = '''
import 'package:flutter/material.dart';

// 注释里的 Color(0xff123456) 与 fontSize: 42 不应误报。
const literal = '字符串里的 Colors.red 也不应误报';
Widget bad(BuildContext context) {
  return DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xff123456),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(children: [
      Text('a', style: TextStyle(fontSize: 12)),
      Text('b', style: TextStyle(color: Colors.red)),
      const SizedBox(width: 999, child: Radius.circular(999)),
    ]),
  );
}
''';
    final violations = scanWave1('fixture_bad.dart', source);
    // Color 字面量 1 + 圆角 2 + fontSize 1 + 裸色 1 = 5 处。
    expect(violations, hasLength(5));
    expect(violations.every((v) => v.contains('fixture_bad.dart')), isTrue);
  });

  test('Wave 2 守卫：lib/** 全量扫描零违规（间距/图标 token）', () {
    final libDir = Directory('lib');
    final files = libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where(
          (f) => !excludedDirSegments.any((segment) => f.path.contains(segment)),
        )
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final violations = <String>[];
    for (final file in files) {
      violations.addAll(
        scanWave2(file.path, file.readAsStringSync()),
      );
    }

    expect(
      violations,
      isEmpty,
      reason: '样式规范 Wave 2 违规（允许：AppSpacing/AppSizes/AppLayout/0）：\n'
          '${violations.join('\n')}',
    );
  });

  test('Wave 2 负向 fixture：数字间距/图标尺寸被拦截，token/0/常量放行', () {
    const bad = '''
import 'package:flutter/material.dart';

Widget bad() {
  return Column(children: [
    const SizedBox(height: 8),
    Padding(padding: EdgeInsets.all(6), child: Text('x')),
    Padding(padding: EdgeInsets.symmetric(horizontal: 10), child: Text('x')),
    Padding(padding: EdgeInsets.only(top: 14), child: Text('x')),
    Padding(padding: EdgeInsets.fromLTRB(6, 8, 10, 12), child: Text('x')),
    Icon(Icons.add, size: 18),
    IconButton(iconSize: 20, onPressed: null, icon: const Icon(Icons.add)),
  ]);
}
''';
    final violations = scanWave2('fixture_bad2.dart', bad);
    // SizedBox 8 + all(6) + symmetric 10 + only 14 + fromLTRB 4 值 + Icon 18 + iconSize 20。
    expect(violations, hasLength(10));
  });

  test('Wave 2 正向 fixture：token/0/AppLayout 引用放行', () {
    const good = '''
import 'package:flutter/material.dart';

Widget good() {
  return Column(children: [
    const SizedBox(height: AppSpacing.sm),
    const SizedBox(height: 0),
    Padding(padding: EdgeInsets.all(AppSpacing.md), child: Text('x')),
    Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0,
      ),
      child: Text('x'),
    ),
    Padding(
      padding: EdgeInsets.only(bottom: AppLayout.keyboardScrollPadding),
      child: TextField(),
    ),
    const Icon(Icons.add, size: AppSizes.iconMd),
    IconButton(iconSize: AppSizes.iconLg, onPressed: null, icon: const Icon(Icons.add)),
  ]);
}
''';
    expect(scanWave2('fixture_good2.dart', good), isEmpty);
  });

  test('Wave 1 豁免：token 定义点允许档位字面量', () {
    const source = '''
import 'package:flutter/material.dart';

class AppRadius {
  static const double card = 8;
}

TextStyle build() => const TextStyle(fontSize: 13);
''';
    expect(
      scanWave1('app_theme.dart', source, isTokenFile: true),
      isEmpty,
    );
  });
}

/// 扫描单文件源码，返回 Wave 1 违规描述列表（文件名:行号 + 原因）。
List<String> scanWave1(
  String path,
  String source, {
  bool isTokenFile = false,
}) {
  final result = parseString(content: source);
  final violations = <String>[];
  final walker = _Wave1Walker(result.lineInfo, isTokenFile, path, violations);
  walker.walk(result.unit);
  return violations;
}

/// 递归遍历 childEntities：不依赖 analyzer 版本特定的 visitor 分发，
/// 按节点运行时类型做规则检查（AST 层面判断，非字符串剥离）。
class _Wave1Walker {
  _Wave1Walker(this.lineInfo, this.isTokenFile, this.fileName, this.violations);

  final LineInfo lineInfo;
  final bool isTokenFile;
  final String fileName;
  final List<String> violations;

  void walk(AstNode node) {
    _check(node);
    for (final child in node.childEntities) {
      if (child is AstNode) walk(child);
    }
  }

  void _violate(AstNode node, String message) {
    final line = lineInfo.getLocation(node.beginToken.offset).lineNumber;
    violations.add('  [$fileName:$line] $message');
  }

  void _check(AstNode node) {
    if (isTokenFile) return;
    final firstIsNumber = _firstNumericArgument(node);
    if (node is InstanceCreationExpression) {
      final name = node.constructorName.toString();
      final first = node.argumentList.arguments.isEmpty
          ? null
          : node.argumentList.arguments.first;
      if (name == 'Color' && first is IntegerLiteral) {
        _violate(node, '禁用 Color(0x…) 字面量，请消费 colorScheme/appColors 语义色（规范 §1）');
      }
      if ((name == 'BorderRadius.circular' || name == 'Radius.circular') &&
          firstIsNumber) {
        _violate(node, '圆角必须引用 AppRadius.* 档位（规范 §3）');
      }
      return;
    }
    if (node is MethodInvocation) {
      final target = node.target;
      final methodName = node.methodName.name;
      if (target == null && methodName == 'Color' && firstIsNumber) {
        _violate(node, '禁用 Color(0x…) 字面量，请消费 colorScheme/appColors 语义色（规范 §1）');
      }
      if (firstIsNumber &&
          target is SimpleIdentifier &&
          (target.name == 'BorderRadius' || target.name == 'Radius') &&
          methodName == 'circular') {
        _violate(node, '圆角必须引用 AppRadius.* 档位（规范 §3）');
      }
      return;
    }
    if (node is PrefixedIdentifier) {
      if (node.prefix.name == 'Colors' && node.identifier.name != 'transparent') {
        _violate(node, '禁用裸 Colors.*，请消费 colorScheme/appColors 语义色（规范 §1）');
      }
      return;
    }
    if (node is NamedArgument) {
      final expression = node.argumentExpression;
      if (node.name.lexeme == 'fontSize' &&
          (expression is IntegerLiteral || expression is DoubleLiteral)) {
        _violate(node, '字号必须经 textTheme/AppTypography 档位消费（规范 §4）');
      }
    }
  }

  bool _firstNumericArgument(AstNode node) {
    // 从 childEntities 里找 ArgumentList 的第一个表达式是否为数字字面量。
    for (final child in node.childEntities) {
      if (child is ArgumentList) {
        final first = child.arguments.isEmpty ? null : child.arguments.first;
        return first is IntegerLiteral || first is DoubleLiteral;
      }
    }
    return false;
  }
}

/// Wave 2：间距/图标数字字面量扫描。
/// 允许：AppSpacing.*/AppSizes.*/AppLayout.*/主题取值/0（零间距）。
List<String> scanWave2(String path, String source) {
  final result = parseString(content: source);
  final violations = <String>[];
  final walker = _Wave2Walker(result.lineInfo, path, violations);
  walker.walk(result.unit);
  return violations;
}

class _Wave2Walker {
  _Wave2Walker(this.lineInfo, this.fileName, this.violations);

  final LineInfo lineInfo;
  final String fileName;
  final List<String> violations;

  void walk(AstNode node) {
    _check(node);
    for (final child in node.childEntities) {
      if (child is AstNode) walk(child);
    }
  }

  void _violate(AstNode node, String message) {
    final line = lineInfo.getLocation(node.beginToken.offset).lineNumber;
    violations.add('  [$fileName:$line] $message');
  }

  bool _isTokenRef(AstNode? node) {
    if (node is! PrefixedIdentifier) return false;
    final prefix = node.prefix.name;
    return prefix == 'AppSpacing' || prefix == 'AppSizes' || prefix == 'AppLayout';
  }

  void _check(AstNode node) {
    // SizedBox(height/width: N)。
    if (node is InstanceCreationExpression) {
      final name = node.constructorName.toString();
      if (name == 'SizedBox') {
        for (final arg in node.argumentList.arguments) {
          if (arg is NamedArgument &&
              (arg.name.lexeme == 'height' || arg.name.lexeme == 'width')) {
            // 发丝分隔线（width: 1）按 §2.2 允许；档位外字面量一律拦截。
            if (_containsOffGridLiteral(arg)) {
              _violate(node, 'SizedBox 尺寸必须引用 AppSpacing.*（规范 §2/§8 Wave 2）');
            }
          }
        }
      }
      return;
    }
    // EdgeInsets.*（all/symmetric/only/fromLTRB 的数字实参）。
    if (node is MethodInvocation) {
      final target = node.target;
      final methodName = node.methodName.name;
      final isEdgeInsets = target is SimpleIdentifier && target.name == 'EdgeInsets';
      if (isEdgeInsets &&
          const {'all', 'symmetric', 'only', 'fromLTRB'}.contains(methodName)) {
        for (final arg in node.argumentList.arguments) {
          if (arg is NamedArgument) {
            _checkSpacingArgument(arg);
          } else if (arg is IntegerLiteral || arg is DoubleLiteral) {
            if (!_isZeroLiteral(arg)) {
              _violate(node, 'EdgeInsets 间距必须引用 AppSpacing.*（规范 §2/§8 Wave 2）');
            }
          } else if (_containsOffGridLiteral(arg)) {
            _violate(node, 'EdgeInsets 间距必须引用 AppSpacing.*（规范 §2/§8 Wave 2）');
          }
        }
      }
      return;
    }
    // Icon(size: N)。
    if (node is NamedArgument && node.name.lexeme == 'size') {
      final parent = node.parent;
      if (parent is ArgumentList && parent.parent is MethodInvocation) {
        final invocation = parent.parent as MethodInvocation;
        if (invocation.methodName.name == 'Icon' && invocation.target == null) {
          _checkIconSize(node);
        }
      }
    }
    // IconButton(iconSize: N)。
    if (node is NamedArgument && node.name.lexeme == 'iconSize') {
      _checkIconSize(node);
    }
  }

  void _checkSpacingArgument(NamedArgument arg) {
    // 递归检查表达式内任何非零数字字面量（覆盖二元/条件表达式）。
    if (_containsOffGridLiteral(arg)) {
      _violate(arg, 'EdgeInsets 间距必须引用 AppSpacing.*（规范 §2/§8 Wave 2）');
    }
  }

  void _checkIconSize(NamedArgument arg) {
    final expr = arg.argumentExpression;
    if (!_isTokenRef(expr) && expr is! PrefixExpression) {
      _violate(arg, '图标尺寸必须引用 AppSizes.*（规范 §5/§8 Wave 2）');
    }
  }

  bool _isZeroLiteral(AstNode node) => node is IntegerLiteral && node.value == 0;

  /// 表达式内是否含档位外数字字面量（>1 的数值即违规模板：0 为零间距、
  /// 1 为发丝分隔线/算术操作数，均按 §2.2 允许；token/主题引用允许）。
  bool _containsOffGridLiteral(AstNode node) {
    for (final child in node.childEntities) {
      if (child is IntegerLiteral && child.value! > 1) return true;
      if (child is DoubleLiteral && child.value > 1) return true;
      if (child is AstNode && _containsOffGridLiteral(child)) return true;
    }
    return false;
  }
}

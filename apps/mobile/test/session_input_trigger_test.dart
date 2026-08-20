import 'package:agent_sessions_mobile/domain/session_input_grammar.dart';
import 'package:flutter_test/flutter_test.dart';

/// MOBILE-V05-08 单元层：Input Trigger 纯语法回归。
///
/// 对应《迭代计划v0.5.md》第 3 节：
/// - `/` 避开 URL/路径中非触发位置（`https:/…`、`//`、词中）；
/// - `@` 避开 `user@host`，支持 `@"..."` 引用路径；
/// - 候选按 caret + draftRev 定位；claimed guard 抑制 `/`，frozen 全禁用。
void main() {
  group('slash trigger 边界', () {
    test('草稿开头 / 触发 slash', () {
      final hit = detectInputTrigger('/', 1);
      expect(hit, isNotNull);
      expect(hit!.isSlash, isTrue);
      expect(hit.query, '');
      expect(hit.leading, isTrue);
    });

    test('空白后 /skill 触发 slash', () {
      final hit = detectInputTrigger('先发消息 /ski', 9);
      expect(hit, isNotNull);
      expect(hit!.isSlash, isTrue);
      expect(hit.query, 'ski');
      expect(hit.leading, isFalse);
    });

    test('URL 中的 / 不触发（scheme:/…）', () {
      for (final url in ['https:/', 'https://x.com/y', 'a://b/c']) {
        final hit = detectInputTrigger(url, url.length);
        expect(hit, isNull, reason: '$url 不应触发 slash');
      }
    });

    test('双斜杠 // 中的 / 不触发', () {
      const text = 'path//x';
      final hit = detectInputTrigger(text, text.length);
      expect(hit, isNull);
    });

    test('词中的 / 不触发，整段无空白时继续退回', () {
      const text = 'C:/Users/x';
      final hit = detectInputTrigger(text, text.length);
      expect(hit, isNull);
    });

    test('claimed guard 抑制 slash', () {
      final hit = detectInputTrigger('/compact', 8, claimed: true);
      expect(hit, isNull);
    });

    test('frozen guard 全禁用', () {
      final hit = detectInputTrigger('/compact', 8, frozen: true);
      expect(hit, isNull);
    });

    test('可替换 span 覆盖 trigger 到 caret', () {
      const text = 'go /hel';
      final hit = detectInputTrigger(text, text.length);
      expect(hit, isNotNull);
      expect(hit!.start, 3);
      expect(hit.end, 7);
      expect(text.substring(hit.start, hit.end), '/hel');
    });
  });

  group('at trigger 边界', () {
    test('空白后 @file 触发引用', () {
      const text = '看看 @fi';
      final hit = detectInputTrigger(text, text.length);
      expect(hit, isNotNull);
      expect(hit!.isAt, isTrue);
      expect(hit.query, 'fi');
      expect(hit.quoted, isFalse);
    });

    test('user@host 不触发（@ 在词中）', () {
      const text = '发邮件给 user@host.com';
      final hit = detectInputTrigger(text, text.length);
      expect(hit, isNull);
    });

    test('@"quoted file with space 支持引用 token', () {
      const text = '读取 @"my report';
      final hit = detectInputTrigger(text, text.length);
      expect(hit, isNotNull);
      expect(hit!.isAt, isTrue);
      expect(hit.query, 'my report');
      expect(hit.quoted, isTrue);
    });

    test('闭合引号后的文本不触发引用', () {
      const text = '读取 @"done.txt" 后面';
      final hit = detectInputTrigger(text, text.length);
      expect(hit, isNull);
    });

    test('claimed guard 不抑制 at', () {
      const text = '看 @fi';
      final hit = detectInputTrigger(text, text.length, claimed: true);
      expect(hit, isNotNull);
      expect(hit!.isAt, isTrue);
    });
  });

  group('draftRev / caret 定位', () {
    test('中间编辑后 caret 指向新位置只取该处触发', () {
      const text = 'xx /abc yy';
      final hit = detectInputTrigger(text, 6);
      expect(hit, isNotNull);
      expect(hit!.query, 'ab');
      expect(hit.start, 3);
      expect(hit.end, 6);
    });

    test('caret 不在 trigger 后时不触发', () {
      const text = 'xx /abc yy';
      final hit = detectInputTrigger(text, 8); // caret 在 token 闭合后的空格
      expect(hit, isNull);
    });
  });
}

// Agent Sessions Android 控制端（P4 mock 控制壳）。
// 本壳演示登录态、mock 会话 start/stream/abort 的移动端入口与状态；
// 真实 Relay/Provider 在 P4 后续接入 mock 后替换为真实传输。
import 'package:flutter/material.dart';

void main() {
  runApp(const AgentSessionsApp());
}

class AgentSessionsApp extends StatelessWidget {
  const AgentSessionsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Agent Sessions',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const ControlShell(),
    );
  }
}

/// 会话状态。
enum SessionState { idle, starting, streaming, error }

/// 控制壳：登录（mock）+ 会话 start/abort 与流式消息展示。
class ControlShell extends StatefulWidget {
  const ControlShell({super.key});

  @override
  State<ControlShell> createState() => _ControlShellState();
}

class _ControlShellState extends State<ControlShell> {
  SessionState _state = SessionState.idle;
  String _status = '未连接。请先登录（mock）。';
  final List<String> _messages = [];

  // mock 登录：仅演示登录态切换，不携带真实凭据。
  void _login() {
    setState(() {
      _state = SessionState.idle;
      _status = '已登录（mock owner）。';
    });
  }

  // 启动 mock 会话：异步产生一条流式消息（模拟 turn）。
  Future<void> _startSession() async {
    setState(() {
      _state = SessionState.starting;
      _status = '正在启动 mock 会话…';
      _messages.clear();
    });
    await Future<void>.delayed(const Duration(milliseconds: 400));
    setState(() {
      _state = SessionState.streaming;
      _status = '会话运行中（mock）。';
      _messages.add('hello from mock');
    });
  }

  // 中止当前 turn。
  void _abort() {
    setState(() {
      _state = SessionState.idle;
      _status = '会话已中止（mock）。';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Agent Sessions 控制端')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('状态：$_status', key: const Key('session-status')),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton(
                  key: const Key('login-button'),
                  onPressed: _login,
                  child: const Text('登录(mock)'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('start-button'),
                  onPressed: _state == SessionState.starting ? null : _startSession,
                  child: const Text('新建会话'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  key: const Key('abort-button'),
                  onPressed: _state == SessionState.streaming ? _abort : null,
                  child: const Text('中止'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(
                key: const Key('message-list'),
                children: [
                  for (final m in _messages) ListTile(title: Text(m)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

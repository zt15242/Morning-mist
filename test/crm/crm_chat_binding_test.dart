import 'dart:io';

import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Kernel implements AgentKernel {
  _Kernel(this.sessionId);
  @override
  final String sessionId;
  @override
  Stream<KernelEvent> get events => const Stream.empty();
  final turns = <KernelTurn>[];
  @override
  void send(KernelTurn turn) => turns.add(turn);
  @override
  void dispose() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'keeps CRM selection for follow-ups, restores it, and clears it',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'crm-chat-binding-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final storage = GlobalStorage('${directory.path}/storage.json');
      ChatSession.crmBindingStorage = storage;
      addTearDown(() {
        ChatSession.crmBindingStorage = null;
        storage.dispose();
      });

      ChatSession chat(_Kernel kernel) {
        final descriptor = KernelDescriptor(
          id: 'claude-code',
          label: 'Claude Code',
          icon: Icons.chat,
          description: '',
          create: (_) => kernel,
        );
        final session = ChatSession(kernel: descriptor, historyCount: 0);
        addTearDown(session.dispose);
        return session;
      }

      final kernel = _Kernel('chat-a');
      final original = chat(kernel);
      original.send(
        const ComposerMessage(text: 'First query', crmConnectorIds: ['one']),
        from: UserPlace.computer,
      );
      original.send(
        const ComposerMessage(text: 'Follow-up'),
        from: UserPlace.computer,
      );
      expect(kernel.turns.last.crmConnectorIds, ['one']);
      original.send(const ComposerMessage(text: 'Internal task'));
      expect(kernel.turns.last.crmConnectorIds, isEmpty);
      original.send(
        const ComposerMessage(text: 'Switch', crmConnectorIds: ['two']),
        from: UserPlace.computer,
      );
      await storage.load();

      final reopened = _Kernel('chat-a');
      final resumed = chat(reopened);
      resumed.send(
        const ComposerMessage(text: 'Continue'),
        from: UserPlace.computer,
      );
      expect(reopened.turns.last.crmConnectorIds, ['two']);
      expect(chat(_Kernel('chat-b')).crmConnectorIds, isEmpty);
      resumed.clearCrmConnectors();
      resumed.send(
        const ComposerMessage(text: 'General question'),
        from: UserPlace.computer,
      );
      expect(reopened.turns.last.crmConnectorIds, isEmpty);
      await storage.load();
      expect(chat(_Kernel('chat-a')).crmConnectorIds, isEmpty);
    },
  );
}

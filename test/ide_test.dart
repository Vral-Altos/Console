import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:va_console/data/ide_connection.dart';
import 'package:va_console/data/models.dart';
import 'package:va_console/ui/ide/code_editing.dart';
import 'package:va_console/ui/ide/ide_page.dart';
import 'package:va_console/ui/projects_page.dart';

import 'fake_ide.dart';
import 'pages_test.dart' show host, overridesWith, size;

TextEditingValue at(String text, [int? offset]) =>
    TextEditingValue(text: text, selection: TextSelection.collapsed(offset: offset ?? text.length));

/// [old] with [ch] typed at its cursor.
TextEditingValue typed(TextEditingValue old, String ch) {
  final s = old.selection;
  final text = old.text.replaceRange(s.start, s.end, ch);
  return at(text, s.start + ch.length);
}

const ws = '/home/va/workspace';

Devstation devstation({String desired = 'running', String state = 'running'}) =>
    Devstation(id: 'aec', project: 'LuminaryAxisDashboard', state: state, desired: desired, ip: '10.20.0.3');

void main() {
  group('editing helpers', () {
    test('a new line keeps the indentation, one more after an opener', () {
      var v = at('  foo(');
      expect(assistEdit(v, typed(v, '\n'))!.text, '  foo(\n    ');
      v = at('  bar;');
      final r = assistEdit(v, typed(v, '\n'))!;
      expect(r.text, '  bar;\n  ');
      expect(r.selection.baseOffset, r.text.length);
      v = at('def f():');
      expect(assistEdit(v, typed(v, '\n'), language: 'python')!.text, 'def f():\n  ');
      v = at('x');
      expect(assistEdit(v, typed(v, '\n')), isNull); // nothing to add
    });

    test('Enter between a bracket pair splits it onto three lines', () {
      final v = at('if (a) {}', 8);
      final r = assistEdit(v, typed(v, '\n'))!;
      expect(r.text, 'if (a) {\n  \n}');
      expect(r.selection.baseOffset, 'if (a) {\n  '.length);
    });

    test('brackets close themselves and typing the closer steps over it', () {
      var v = at('f');
      var r = assistEdit(v, typed(v, '('))!;
      expect(r.text, 'f()');
      expect(r.selection.baseOffset, 2);
      r = assistEdit(r, typed(r, ')'))!;
      expect(r.text, 'f()');
      expect(r.selection.baseOffset, 3);
      v = at('fx', 1); // before a word: no closer
      expect(assistEdit(v, typed(v, '(')), isNull);
    });

    test('leaves pastes, IME composing and deletions alone', () {
      final v = at('abc');
      expect(assistEdit(v, at('abc\n\n')), isNull);
      expect(assistEdit(v, at('ab')), isNull);
      expect(
        assistEdit(v, const TextEditingValue(text: 'abc(', selection: TextSelection.collapsed(offset: 4), composing: TextRange(start: 3, end: 4))),
        isNull,
      );
    });

    test('Tab indents the cursor or every selected line; Shift-Tab outdents', () {
      expect(indentLines(at('ab', 1)).text, 'a  b');
      const v = TextEditingValue(text: 'a\nb\nc', selection: TextSelection(baseOffset: 0, extentOffset: 3));
      final r = indentLines(v);
      expect(r.text, '  a\n  b\nc');
      expect(indentLines(r, outdent: true).text, 'a\nb\nc');
      expect(indentLines(at('    x', 4), outdent: true).text, '  x');
    });

    test('word completion offers words from the file, then keywords', () {
      final c = WordCompleter();
      const text = 'final controller = 1; controller.dispose(); cont';
      expect(c.suggest(text, text.length, 'dart'), ['controller', 'continue']);
      expect(c.suggest('x c', 3, 'dart'), isEmpty); // one letter: too soon
      final v = acceptCompletion(at(text), 'controller');
      expect(v.text, 'final controller = 1; controller.dispose(); controller');
      expect(v.selection.baseOffset, v.text.length);
    });

    test('files get the right grammar', () {
      expect(languageForFile('main.dart'), 'dart');
      expect(languageForFile('main.tf'), 'ini');
      expect(languageForFile('Dockerfile'), 'dockerfile');
      expect(languageForFile('firestore.rules'), 'javascript');
      expect(languageForFile('README'), isNull);
    });
  });

  group('IdeConnection', () {
    late FakeIde ide;
    setUp(() => ide = FakeIde(files: {'$ws/a.txt': 'hello'}));

    IdeConnection conn() => IdeConnection(
          devstationId: 'aec',
          connect: ide.connect,
          token: () async => 'tok',
          gateway: 'wss://gw.example/',
          retryDelays: const [Duration(milliseconds: 10)],
        );

    test('signs in through the gateway and works with files', () async {
      final c = conn();
      await c.start();
      expect(c.phase, IdePhase.ready);
      expect(ide.opened.single.toString(), 'wss://gw.example/ide/aec');
      expect(c.workspace, ws);
      expect((await c.list(ws)).single.name, 'a.txt');
      final f = await c.read('$ws/a.txt');
      expect(f.content, 'hello');
      await c.write('$ws/a.txt', 'bye', mtime: f.mtime);
      expect(ide.files['$ws/a.txt'], 'bye');
      ide.touch('$ws/a.txt', 'theirs');
      await expectLater(c.write('$ws/a.txt', 'mine', mtime: f.mtime), throwsA(isA<IdeException>().having((e) => e.code, 'code', 'conflict')));
      c.dispose();
    });

    test('reconnects after a drop and reattaches its terminals', () async {
      final c = conn();
      await c.start();
      final out = <IdeTermEvent>[];
      c.terminalEvents.listen(out.add);
      final t = await c.openTerminal();
      await ide.last.drop();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.phase, IdePhase.ready);
      expect(ide.connections, hasLength(2));
      expect(ide.last.attached, {t});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(out.any((e) => e.replay && e.data == 'replayed-$t '), isTrue);
      // Requests made while reconnecting wait for it.
      final pending = ide.last.drop().then((_) => c.read('$ws/a.txt'));
      expect((await pending).content, 'hello');
      c.dispose();
    });

    test('stops trying when the Devstation is stopped or the account is wrong', () async {
      ide.refuse = (code: 'not-running', error: 'Devstation "aec" is stopped');
      final c = conn();
      await c.start();
      expect(c.phase, IdePhase.failed);
      expect(c.errorCode, 'not-running');
      await expectLater(c.list(ws), throwsA(isA<IdeException>()));
      ide.refuse = null;
      await c.retry();
      expect(c.phase, IdePhase.ready);
      c.dispose();

      final bad = IdeConnection(devstationId: 'aec', connect: ide.connect, token: () async => 'other');
      await bad.start();
      expect(bad.errorCode, 'auth');
      bad.dispose();
    });
  });

  group('IDE page', () {
    late FakeIde ide;
    setUp(() => ide = FakeIde(files: {
          '$ws/app/lib/main.dart': 'void main() {\n  run();\n}\n',
          '$ws/app/README.md': '# app\n',
          '$ws/notes.txt': 'notes',
          '$ws/logo.png': '\u0000PNG',
        }));

    List overrides({Devstation? d, List<Object>? extra}) => [
          ...overridesWith(devstations: [d ?? devstation()]),
          ideSocketFactoryProvider.overrideWithValue(ide.connect),
          ideTokenProvider.overrideWithValue(() async => 'tok'),
          ...?extra,
        ];

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('browses, edits with highlighting, saves, and runs a terminal (desktop)', (tester) async {
      size(tester, const Size(1400, 900));
      await tester.pumpWidget(host(const IdePage(devstationId: 'aec', project: 'LuminaryAxisDashboard'), overrides()));
      await settle(tester);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('app'), findsOneWidget);
      expect(find.text('notes.txt'), findsOneWidget);
      // A desktop opens a terminal straight away.
      expect(ide.terminals, hasLength(1));

      await tester.tap(find.text('app'));
      await settle(tester);
      await tester.tap(find.text('lib'));
      await settle(tester);
      await tester.tap(find.text('main.dart'));
      await settle(tester);
      expect(find.byKey(const ValueKey('tab-$ws/app/lib/main.dart')), findsOneWidget);

      final field = find.byKey(const ValueKey('code-field'));
      final ctl = tester.widget<TextField>(field).controller as CodeController;
      expect(ctl.language, 'dart');
      // Highlighted: the text is split into styled spans.
      final span = ctl.buildTextSpan(context: tester.element(field), style: const TextStyle(), withComposing: false);
      expect(span.children, isNotEmpty);

      await tester.tap(field);
      ctl.selection = const TextSelection.collapsed(offset: 'void main() {\n  run();'.length);
      await tester.pump();
      tester.testTextInput.updateEditingValue(typed(ctl.value, '\n'));
      await tester.pump();
      expect(ctl.text, 'void main() {\n  run();\n  \n}\n'); // indented
      tester.testTextInput.updateEditingValue(typed(ctl.value, 'ru'));
      await tester.pump();
      expect(find.byKey(const ValueKey('completions')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('completions')), matching: find.text('run')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(ctl.text, 'void main() {\n  run();\n  run\n}\n');
      expect(find.byIcon(Icons.circle), findsOneWidget); // unsaved

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await settle(tester);
      expect(ide.files['$ws/app/lib/main.dart'], 'void main() {\n  run();\n  run\n}\n');
      expect(find.byIcon(Icons.circle), findsNothing);

      // Someone else changed it: a save asks before overwriting.
      ide.touch('$ws/app/lib/main.dart', 'theirs');
      tester.testTextInput.updateEditingValue(typed(ctl.value, ';'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ide-save')));
      await settle(tester);
      expect(find.textContaining('changed on the Devstation'), findsOneWidget);
      await tester.tap(find.text('Discard mine, reload'));
      await settle(tester);
      expect(ctl.text, 'theirs');

      // Binary files are not opened as text.
      await tester.tap(find.text('logo.png'));
      await settle(tester);
      expect(find.textContaining('A binary file'), findsOneWidget);

      // The terminal sends what is typed.
      final t = ide.terminals.single;
      ide.input[t]!.clear();
      await tester.tap(find.byKey(const ValueKey('new-terminal')));
      await settle(tester);
      expect(ide.terminals, hasLength(2));
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
    });

    testWidgets('a phone shows one pane at a time with a terminal key bar', (tester) async {
      size(tester, const Size(390, 844));
      await tester.pumpWidget(host(const IdePage(devstationId: 'aec'), overrides()));
      await settle(tester);
      expect(find.byKey(const ValueKey('ide-panes')), findsOneWidget);
      expect(ide.terminals, isEmpty); // not until asked for
      expect(find.text('Open a file from Files.'), findsOneWidget);

      await tester.tap(find.text('Files'));
      await settle(tester);
      await tester.tap(find.text('notes.txt'));
      await settle(tester);
      expect(find.byKey(const ValueKey('code-field')), findsOneWidget); // back in the editor

      await tester.tap(find.text('Terminal'));
      await settle(tester);
      expect(ide.terminals, hasLength(1));
      expect(find.byKey(const ValueKey('terminal-keys')), findsOneWidget);
      final t = ide.terminals.single;
      await tester.tap(find.text('esc'));
      await tester.tap(find.text('^C'));
      await settle(tester);
      expect(ide.input[t].toString(), '\x1b\x03');
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
    });

    testWidgets('a stopped Devstation offers to start it', (tester) async {
      size(tester, const Size(1200, 800));
      ide.refuse = (code: 'not-running', error: 'Devstation "aec" is stopped');
      await tester.pumpWidget(host(const IdePage(devstationId: 'aec'), overrides(d: devstation(desired: 'stopped', state: 'stopped'))));
      await settle(tester);
      expect(find.text('aec is stopped'), findsOneWidget);
      expect(find.byKey(const ValueKey('ide-start')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
    });

    testWidgets('the Devstation card opens the IDE', (tester) async {
      size(tester, const Size(1400, 900));
      await tester.pumpWidget(host(DevstationCard(devstation: devstation()), overrides()));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('open-ide-aec')));
      await settle(tester);
      expect(find.byType(IdePage), findsOneWidget);
      expect(find.text('LuminaryAxisDashboard · IDE'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
    });
  });
}

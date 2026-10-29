import 'dart:async';
import 'dart:convert';

import 'package:dartchess/dartchess.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:lichess_mobile/src/db/secure_storage.dart';
import 'package:lichess_mobile/src/model/analysis/analysis_controller.dart';
import 'package:lichess_mobile/src/model/common/eval.dart';
import 'package:lichess_mobile/src/model/common/node.dart';
import 'package:lichess_mobile/src/model/engine/engine_utils.dart';
import 'package:lichess_mobile/src/model/engine/position_evaluator.dart';
import 'package:lichess_mobile/src/model/game/game_history.dart';
import 'package:lichess_mobile/src/view/analysis/retro_screen.dart';
import 'package:lichess_mobile/src/model/puzzle/puzzle_angle.dart';
import 'package:lichess_mobile/src/model/puzzle/puzzle_theme.dart';
import 'package:lichess_mobile/src/view/puzzle/puzzle_screen.dart';
import 'package:lichess_mobile/src/utils/navigation.dart';
import 'package:material_ui/material_ui.dart';

const _kKeyStorage = 'ai_coach_gemini_key';
const _kModelStorage = 'ai_coach_gemini_model';
const _kDefaultModel = 'gemini-3.5-flash';

// Move quality thresholds (centipawn loss for the side that moved, White/Black perspective fixed).
const _kInaccuracyCp = 50;
const _kMistakeCp = 100;
const _kBlunderCp = 200;

const _kSystemPrompt =
    'তুমি একজন ধৈর্যশীল দাবা কোচ। সহজ, সাধারণ বাংলায় উত্তর দাও। দাবার নোটেশন (যেমন Nf3) ইংরেজিতে রাখতে পারো। '
    'তোমাকে Stockfish ইঞ্জিনের যাচাই করা তথ্য দেওয়া হবে। ওই তথ্যের বাইরে নিজে থেকে কোনো স্কোর, সেরা চাল বা লাইন বানাবে না। '
    'ইঞ্জিনের তথ্য না থাকলে পরিষ্কার বলবে "ইঞ্জিন দিয়ে যাচাই করা যায়নি"। '
    'উত্তরে দুটো অংশ আলাদা রাখো: "ইঞ্জিনের যাচাই করা তথ্য" (শুধু দেওয়া তথ্য থেকে) এবং "আমার ব্যাখ্যা" (তোমার নিজের অনুমান ও বুঝিয়ে বলা)। '
    'উত্তর ছোট ও ফোনে পড়ার মতো রাখো।';

class AiCoachScreen extends ConsumerStatefulWidget {
  const AiCoachScreen({required this.options, super.key});

  final AnalysisOptions options;

  static Route<dynamic> buildRoute(AnalysisOptions options) =>
      buildScreenRoute(screen: AiCoachScreen(options: options));

  @override
  ConsumerState<AiCoachScreen> createState() => _AiCoachScreenState();
}

class _AiCoachScreenState extends ConsumerState<AiCoachScreen> {
  final _questionController = TextEditingController();
  final _puzzleController = TextEditingController();
  int _requestId = 0;
  bool _loading = false;
  String? _answer;
  String? _error;
  String? _lastQuestion;

  @override
  void dispose() {
    _requestId++;
    _questionController.dispose();
    _puzzleController.dispose();
    super.dispose();
  }

  void _cancel() {
    setState(() {
      _requestId++;
      _loading = false;
    });
  }

  Future<void> _ask(String facts, String question) async {
    final id = ++_requestId;
    _lastQuestion = question;
    setState(() {
      _loading = true;
      _error = null;
      _answer = null;
    });
    try {
      final key = await SecureStorage.instance.read(key: _kKeyStorage);
      if (key == null || key.trim().isEmpty) {
        throw const _AiCoachException('Gemini API Key দেওয়া নেই। উপরের সেটিংস (গিয়ার) আইকনে চেপে Key দিন।');
      }
      final model = (await SecureStorage.instance.read(key: _kModelStorage))?.trim();
      final text = await _askGemini(
        apiKey: key.trim(),
        model: (model == null || model.isEmpty) ? _kDefaultModel : model,
        prompt: '$facts\n\nপ্রশ্ন: $question',
      );
      if (!mounted || id != _requestId) return;
      setState(() {
        _answer = text;
        _loading = false;
      });
    } on _AiCoachException catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _error = 'কিছু একটা সমস্যা হয়েছে। ইন্টারনেট দেখে আবার চেষ্টা করুন।';
        _loading = false;
      });
    }
  }

  /// Gemini only picks the closest Lichess puzzle theme name from the app's own list.
  /// The puzzles themselves come from Lichess and are played on the app's normal puzzle board.
  Future<void> _openPuzzle() async {
    final wish = _puzzleController.text.trim();
    if (wish.isEmpty) return;
    final id = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
      _answer = null;
    });
    try {
      final key = await SecureStorage.instance.read(key: _kKeyStorage);
      if (key == null || key.trim().isEmpty) {
        throw const _AiCoachException('Gemini API Key দেওয়া নেই। উপরের সেটিংস (গিয়ার) আইকনে চেপে Key দিন।');
      }
      final model = (await SecureStorage.instance.read(key: _kModelStorage))?.trim();
      final names = PuzzleThemeKey.values.map((k) => k.name).join(', ');
      final reply = await _askGemini(
        apiKey: key.trim(),
        model: (model == null || model.isEmpty) ? _kDefaultModel : model,
        system:
            'তুমি একজন বাছাইকারী। তালিকা থেকে ব্যবহারকারীর চাওয়ার সবচেয়ে কাছের একটি থিমের নাম বেছে নাও। '
            'শুধু সেই নামটি ইংরেজিতে, তালিকার হুবহু বানানে লেখো। আর কিছু লিখবে না।',
        prompt: 'থিমের তালিকা: $names\nব্যবহারকারীর চাওয়া: $wish',
      );
      final themeKey = puzzleThemeNameMap.get(reply.trim().replaceAll(RegExp(r'[^A-Za-z0-9]'), ''));
      if (!mounted || id != _requestId) return;
      if (themeKey == null) {
        throw const _AiCoachException('এই ধরনের পাজল খুঁজে পাওয়া যায়নি। অন্যভাবে বলে দেখুন।');
      }
      setState(() => _loading = false);
      Navigator.of(context).push(PuzzleScreen.buildRoute(angle: PuzzleTheme(themeKey)));
    } on _AiCoachException catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _error = 'কিছু একটা সমস্যা হয়েছে। ইন্টারনেট দেখে আবার চেষ্টা করুন।';
        _loading = false;
      });
    }
  }

  Future<void> _openSettings() async {
    final keyController = TextEditingController();
    final modelController = TextEditingController(
      text: (await SecureStorage.instance.read(key: _kModelStorage)) ?? _kDefaultModel,
    );
    final hasKey = (await SecureStorage.instance.read(key: _kKeyStorage))?.isNotEmpty ?? false;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Gemini সেটিংস'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(hasKey ? 'Key সেভ করা আছে। নতুন Key দিলে বদলে যাবে।' : 'এখনো কোনো Key সেভ করা নেই।'),
            const SizedBox(height: 12),
            TextField(
              controller: keyController,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Gemini API Key'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: modelController,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Model'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await SecureStorage.instance.delete(key: _kKeyStorage);
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Key মুছুন'),
          ),
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('বাতিল')),
          FilledButton(
            onPressed: () async {
              final k = keyController.text.trim();
              final m = modelController.text.trim();
              if (k.isNotEmpty) await SecureStorage.instance.write(key: _kKeyStorage, value: k);
              await SecureStorage.instance.write(
                key: _kModelStorage,
                value: m.isEmpty ? _kDefaultModel : m,
              );
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('সেভ'),
          ),
        ],
      ),
    );
    keyController.dispose();
    modelController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final analysisState = ref.watch(analysisControllerProvider(widget.options)).requireValue;
    final localEval = ref
        .watch(
          engineEvaluationProvider((
            context: analysisState.evaluationContext,
            path: analysisState.currentPath,
          )),
        )
        .eval;
    final eval = pickBestClientEval(localEval: localEval, savedEval: analysisState.currentNode.eval);

    // The node before the current move: the last branch of the path without its final step.
    ViewNode parentNode = analysisState.analysisRoot;
    for (final branch in analysisState.analysisRoot.branchesOn(
      analysisState.currentPath.penultimate,
    )) {
      parentNode = branch;
    }
    final parentEval = parentNode.eval;

    final engineText = _buildEngineContext(
      fen: analysisState.currentPosition.fen,
      whiteToMove: analysisState.currentPosition.turn == Side.white,
      lastMoveSan: analysisState.currentNode.sanMove?.san,
      eval: eval,
      parentEval: parentEval,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Chess Coach'),
        actions: [
          IconButton(icon: const Icon(Icons.settings), onPressed: _openSettings),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                eval == null
                    ? 'ইঞ্জিনের বিশ্লেষণ এখনো নেই (যাচাই করা যায়নি)। আগের পর্দায় ইঞ্জিন চালু করে একটু অপেক্ষা করুন।'
                    : engineText,
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _loading || eval == null
                ? null
                : () => _ask(engineText, 'এই চালটা (বা এই পজিশনটা) কেন ভালো বা খারাপ, বুঝিয়ে বলো।'),
            child: const Text('এই চালটা ব্যাখ্যা করো'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _questionController,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'এই পজিশন নিয়ে প্রশ্ন (বা যেকোনো দাবার প্রশ্ন)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _loading
                ? null
                : () {
                    final q = _questionController.text.trim();
                    if (q.isEmpty) return;
                    _ask(
                      eval == null
                          ? 'FEN: ${analysisState.currentPosition.fen}\n(ইঞ্জিনের তথ্য নেই, যাচাই করা যায়নি)'
                          : engineText,
                      q,
                    );
                  },
            child: const Text('জিজ্ঞাসা করো'),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _puzzleController,
            decoration: const InputDecoration(
              labelText: 'কোন ধরনের পাজল খেলতে চান? (যেমন: ফর্ক, পিন, মিডলগেম)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _loading ? null : _openPuzzle,
            child: const Text('এই ধরনের পাজল খেলো'),
          ),
          const SizedBox(height: 16),
          if (_loading) ...[
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 8),
            Center(child: TextButton(onPressed: _cancel, child: const Text('বাতিল'))),
          ],
          if (_error != null) ...[
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            if (_lastQuestion != null)
              TextButton(
                onPressed: () => _ask(engineText, _lastQuestion!),
                child: const Text('আবার চেষ্টা করুন'),
              ),
          ],
          if (_answer != null) SelectableText(_answer!),
        ],
      ),
    );
  }
}

class _AiCoachException implements Exception {
  const _AiCoachException(this.message);
  final String message;
}

/// Builds the verified engine facts that are sent to the AI.
///
/// All scores are from White's point of view (positive = White is better), which is the
/// convention used by the app's engine evaluations.
String _buildEngineContext({
  required String fen,
  required bool whiteToMove,
  required String? lastMoveSan,
  required ClientEval? eval,
  required ClientEval? parentEval,
}) {
  final b = StringBuffer();
  b.writeln('ইঞ্জিনের যাচাই করা তথ্য (Stockfish):');
  b.writeln('FEN: $fen');
  b.writeln('এখন চাল দেওয়ার পালা: ${whiteToMove ? 'সাদা' : 'কালো'}');
  if (lastMoveSan != null) b.writeln('শেষ চাল: $lastMoveSan');
  if (eval != null) {
    b.writeln('গভীরতা: ${eval.depth}। স্কোর সবসময় সাদার দিক থেকে (+ মানে সাদা ভালো)।');
    var i = 1;
    for (final pv in eval.pvs.take(3)) {
      final line = pv.sanMoves(eval.position).take(8).join(' ');
      b.writeln('লাইন $i: ${pv.evalString} | $line');
      i++;
    }
    final prev = parentEval?.pvs.firstOrNull;
    final curr = eval.pvs.firstOrNull;
    if (lastMoveSan != null && prev?.cp != null && curr?.cp != null) {
      // The side that just moved is the opposite of the side to move now.
      final moverIsWhite = !whiteToMove;
      final before = prev!.cp!;
      final after = curr!.cp!;
      final loss = moverIsWhite ? before - after : after - before;
      final label = loss >= _kBlunderCp
          ? 'blunder'
          : loss >= _kMistakeCp
          ? 'mistake'
          : loss >= _kInaccuracyCp
          ? 'inaccuracy'
          : 'ঠিকঠাক';
      b.writeln('চালের আগের স্কোর: ${prev.evalString}, পরের স্কোর: ${curr.evalString}');
      b.writeln('চালদাতার ক্ষতি: প্রায় $loss সেন্টিপন, শ্রেণি: $label');
      final bestBefore = parentEval!.pvs.first.sanMoves(parentEval.position).firstOrNull;
      if (bestBefore != null) b.writeln('ইঞ্জিনের আগের সেরা চাল ছিল: $bestBefore');
    }
  }
  return b.toString();
}

Future<String> _askGemini({
  required String apiKey,
  required String model,
  required String prompt,
  String system = _kSystemPrompt,
}) async {
  final uri = Uri.https(
    'generativelanguage.googleapis.com',
    '/v1beta/models/$model:generateContent',
  );
  final http.Response res;
  try {
    res = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json', 'x-goog-api-key': apiKey},
          body: jsonEncode({
            'systemInstruction': {
              'parts': [
                {'text': system},
              ],
            },
            'contents': [
              {
                'role': 'user',
                'parts': [
                  {'text': prompt},
                ],
              },
            ],
          }),
        )
        .timeout(const Duration(seconds: 60));
  } on TimeoutException {
    throw const _AiCoachException('সময় শেষ হয়ে গেছে। আবার চেষ্টা করুন।');
  } catch (_) {
    throw const _AiCoachException('ইন্টারনেট সংযোগে সমস্যা। সংযোগ দেখে আবার চেষ্টা করুন।');
  }

  if (res.statusCode == 400 || res.statusCode == 401 || res.statusCode == 403) {
    throw const _AiCoachException('Key ভুল, অথবা Model-এর নাম ঠিক নেই। সেটিংসে গিয়ে দেখুন।');
  }
  if (res.statusCode == 429) {
    throw const _AiCoachException('ব্যবহারের সীমা শেষ। কিছুক্ষণ পরে আবার চেষ্টা করুন।');
  }
  if (res.statusCode != 200) {
    throw _AiCoachException('Gemini থেকে সমস্যা এসেছে (কোড ${res.statusCode})।');
  }
  try {
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final parts = (data['candidates'] as List).first['content']['parts'] as List;
    final text = parts.map((p) => (p as Map)['text'] ?? '').join().trim();
    if (text.isEmpty) throw const FormatException('empty');
    return text;
  } catch (_) {
    throw const _AiCoachException('AI-র উত্তর বোঝা যায়নি। আবার চেষ্টা করুন।');
  }
}

// ---------------------------------------------------------------------------
// Everywhere access: a small round button on every screen that opens a general AI chat.
// ---------------------------------------------------------------------------

bool _aiChatOpen = false;

const _kChatSystemPrompt =
    'তুমি একজন ধৈর্যশীল দাবা কোচ। সহজ, সাধারণ বাংলায় উত্তর দাও। দাবার নোটেশন ইংরেজিতে রাখতে পারো। '
    'সাধারণ দাবার প্রশ্ন (নিয়ম, ওপেনিং, কৌশল, অনুশীলনের পরামর্শ) বুঝিয়ে বলো। '
    'তোমার কাছে কোনো ইঞ্জিনের তথ্য নেই, তাই কোনো নির্দিষ্ট পজিশনের সেরা চাল বা স্কোর বানিয়ে বলবে না। '
    'সেক্ষেত্রে বলবে Analysis স্ক্রিনে AI Coach ব্যবহার করতে। '
    'চলমান বা র‍্যাঙ্কড খেলায় চাল বলে দেবে না, কারণ এটা Lichess-এর ন্যায্য খেলার নিয়মের বিরুদ্ধে। '
    'উত্তর ছোট ও ফোনে পড়ার মতো রাখো।';

/// Wraps the whole app and floats a small button above every screen.
class AiCoachOverlay extends StatelessWidget {
  const AiCoachOverlay({required this.navigatorKey, required this.child, super.key});

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Positioned(
          right: 8,
          bottom: 100,
          child: FloatingActionButton.small(
            heroTag: null,
            onPressed: () {
              if (_aiChatOpen) return;
              _aiChatOpen = true;
              navigatorKey.currentState
                  ?.push(AiChatScreen.buildRoute())
                  .whenComplete(() => _aiChatOpen = false);
            },
            child: const Icon(Icons.psychology_outlined),
          ),
        ),
      ],
    );
  }
}

class AiChatScreen extends StatefulWidget {
  const AiChatScreen({super.key});

  static Route<dynamic> buildRoute() => buildScreenRoute(screen: const AiChatScreen());

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  final _controller = TextEditingController();
  final _messages = <({String q, String a})>[];
  int _requestId = 0;
  bool _loading = false;
  String? _error;
  String? _lastQuestion;

  @override
  void dispose() {
    _requestId++;
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send(String question) async {
    final id = ++_requestId;
    _lastQuestion = question;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final key = await SecureStorage.instance.read(key: _kKeyStorage);
      if (key == null || key.trim().isEmpty) {
        throw const _AiCoachException('Gemini API Key দেওয়া নেই। উপরের সেটিংস (গিয়ার) আইকনে চেপে Key দিন।');
      }
      final model = (await SecureStorage.instance.read(key: _kModelStorage))?.trim();
      final recent = _messages.reversed.take(3).toList().reversed;
      final history = recent.map((m) => 'আগের প্রশ্ন: ${m.q}\nআগের উত্তর: ${m.a}').join('\n\n');
      final text = await _askGemini(
        apiKey: key.trim(),
        model: (model == null || model.isEmpty) ? _kDefaultModel : model,
        system: _kChatSystemPrompt,
        prompt: history.isEmpty ? question : '$history\n\nনতুন প্রশ্ন: $question',
      );
      if (!mounted || id != _requestId) return;
      setState(() {
        _messages.add((q: question, a: text));
        _loading = false;
        _controller.clear();
      });
    } on _AiCoachException catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _error = 'কিছু একটা সমস্যা হয়েছে। ইন্টারনেট দেখে আবার চেষ্টা করুন।';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Chess Coach'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => showAiSettingsDialog(context),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: OutlinedButton(
              onPressed: () => Navigator.of(context).push(buildScreenRoute(screen: const MyMistakesScreen())),
              child: const Text('আমার ভুল থেকে শেখো (নিজের গেম থেকে পাজল)'),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_messages.isEmpty && !_loading)
                  const Text(
                    'দাবা নিয়ে যেকোনো প্রশ্ন করুন। কোনো পজিশনের সেরা চাল জানতে Analysis স্ক্রিনের AI Coach ব্যবহার করুন। '
                    'চলমান খেলায় এটা ব্যবহার করবেন না।',
                  ),
                for (final m in _messages) ...[
                  Text(m.q, style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  SelectableText(m.a),
                  const SizedBox(height: 16),
                ],
                if (_loading) const Center(child: CircularProgressIndicator()),
                if (_error != null) ...[
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  if (_lastQuestion != null)
                    TextButton(
                      onPressed: () => _send(_lastQuestion!),
                      child: const Text('আবার চেষ্টা করুন'),
                    ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: 'আপনার প্রশ্ন লিখুন',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _loading
                      ? null
                      : () {
                          final q = _controller.text.trim();
                          if (q.isNotEmpty) _send(q);
                        },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _dateText(DateTime d) => '${d.day}/${d.month}/${d.year}';

/// Lists the user's recent games. Tapping one opens Lichess' own "Learn from your mistakes"
/// screen, which turns the mistakes found by the server analysis into puzzles.
class MyMistakesScreen extends ConsumerWidget {
  const MyMistakesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final games = ref.watch(myRecentGamesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('আমার ভুল থেকে শেখো')),
      body: games.when(
        data: (list) => list.isEmpty
            ? const Center(child: Text('কোনো গেম পাওয়া যায়নি।'))
            : ListView(
                children: [
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'একটা গেম বেছে নিন। আপনার ভুলগুলো পাজল হয়ে আসবে, আপনি বোর্ডে খেলবেন। '
                      '(Lichess সার্ভারের বিশ্লেষণ লাগে)',
                    ),
                  ),
                  for (final g in list)
                    ListTile(
                      title: Text(
                        '${g.game.speed.name} · ${_dateText(g.game.createdAt)} · ${g.pov == Side.white ? 'সাদা' : 'কালো'}',
                      ),
                      subtitle: Text(
                        g.game.winner == null
                            ? 'ড্র বা অন্য ফলাফল'
                            : (g.game.winner == g.pov ? 'জিতেছেন' : 'হেরেছেন'),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(
                        context,
                      ).push(RetroScreen.buildRoute((id: g.game.id, initialSide: g.pov))),
                    ),
                ],
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, s) => const Center(
          child: Text('গেমের তালিকা আনা যায়নি। ইন্টারনেট দেখে আবার চেষ্টা করুন।'),
        ),
      ),
    );
  }
}

Future<void> showAiSettingsDialog(BuildContext context) async {
  final keyController = TextEditingController();
  final modelController = TextEditingController(
    text: (await SecureStorage.instance.read(key: _kModelStorage)) ?? _kDefaultModel,
  );
  final hasKey = (await SecureStorage.instance.read(key: _kKeyStorage))?.isNotEmpty ?? false;
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Gemini সেটিংস'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(hasKey ? 'Key সেভ করা আছে। নতুন Key দিলে বদলে যাবে।' : 'এখনো কোনো Key সেভ করা নেই।'),
          const SizedBox(height: 12),
          TextField(
            controller: keyController,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Gemini API Key'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: modelController,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Model'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await SecureStorage.instance.delete(key: _kKeyStorage);
            if (ctx.mounted) Navigator.of(ctx).pop();
          },
          child: const Text('Key মুছুন'),
        ),
        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('বাতিল')),
        FilledButton(
          onPressed: () async {
            final k = keyController.text.trim();
            final m = modelController.text.trim();
            if (k.isNotEmpty) await SecureStorage.instance.write(key: _kKeyStorage, value: k);
            await SecureStorage.instance.write(key: _kModelStorage, value: m.isEmpty ? _kDefaultModel : m);
            if (ctx.mounted) Navigator.of(ctx).pop();
          },
          child: const Text('সেভ'),
        ),
      ],
    ),
  );
  keyController.dispose();
  modelController.dispose();
}

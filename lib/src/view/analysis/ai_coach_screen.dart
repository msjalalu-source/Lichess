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
  int _requestId = 0;
  bool _loading = false;
  String? _answer;
  String? _error;
  String? _lastQuestion;

  @override
  void dispose() {
    _requestId++;
    _questionController.dispose();
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
                {'text': _kSystemPrompt},
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

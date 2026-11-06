import '../i18n/strings.g.dart' as l10n;
import 'package:flutter/material.dart';
import 'karaoke_session.dart';
import 'karaoke_scoring.dart';

class KaraokePartyScreen extends StatefulWidget {
  const KaraokePartyScreen({super.key, required this.session});
  final KaraokeSession session;
  @override
  State<KaraokePartyScreen> createState() => _KaraokePartyScreenState();
}

class _KaraokePartyScreenState extends State<KaraokePartyScreen> {
  bool _busy = false;
  String? _error;
  KaraokeSession get s => widget.session;
  Future<void> command(String operation, [Map<String, dynamic> data = const {}]) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await s.host('party', {'operation': operation, 'data': data});
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> question() async {
    final prompt = TextEditingController(),
        options = TextEditingController(),
        answer = TextEditingController(text: '1');
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.t.karaokeUi.addAQuestionYouAuthoredOrMayUse),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              children: [
                TextField(
                  controller: prompt,
                  maxLength: 2000,
                  decoration: InputDecoration(labelText: l10n.t.karaokeUi.triviaLyricCompletionNameThatTunePrompt),
                ),
                TextField(
                  controller: options,
                  minLines: 3,
                  maxLines: 8,
                  decoration: InputDecoration(labelText: l10n.t.karaokeUi.optionsOnePerLine),
                ),
                TextField(
                  controller: answer,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: l10n.t.karaokeUi.correctOptionNumberStartingAt1),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.t.auth.quickConnectCancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.t.profiles.add)),
        ],
      ),
    );
    if (save == true) {
      await command('question', {
        'prompt': prompt.text,
        'options': options.text.split('\n').where((s) => s.trim().isNotEmpty).toList(),
        'answer': (int.tryParse(answer.text) ?? 0) - 1,
      });
    }
    prompt.dispose();
    options.dispose();
    answer.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: s,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: Text(l10n.t.karaokeUi.partyRounds)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          Text(l10n.t.karaokeUi.scoresStayPrivateLeaderboardsCompareReviewedChartsWithMatching),
          DropdownButton<String>(
            value: s.party.game,
            items: const [
              'no-score',
              'solo',
              'duet',
              'teams',
              'cooperative',
              'battle',
              'tournament',
              'medley',
              'quiz',
            ].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
            onChanged: _busy ? null : (v) => command('mode', {'game': v}),
          ),
          OutlinedButton(
            onPressed: _busy || s.singers.where((p) => !p.absent).length < 2
                ? null
                : () => command('tournament', {'singers': s.singers.where((p) => !p.absent).map((p) => p.id).toList()}),
            child: Text(l10n.t.karaokeUi.startARoundRobinTournamentWithPresentSingers),
          ),
          if (s.party.matches.isNotEmpty)
            Text(
              l10n.t.karaokeUi.round(value1: (s.party.round).toString()),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          for (var i = 0; i < s.party.matches.length; i++)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.t.karaokeUi.match(
                        value1: (i + 1).toString(),
                        value2:
                            (s.party.matches[i]
                                    .map((id) => s.singers.where((p) => p.id == id).firstOrNull?.name ?? id)
                                    .join(' vs '))
                                .toString(),
                      ),
                    ),
                    if (s.party.matchScores(s.party.matches[i]) case final scores?)
                      Text(l10n.t.karaokeUi.verifiedEligibleScores(value1: (scores.values.join(' – ')).toString())),
                    if (s.party.matchScores(s.party.matches[i]) == null)
                      Text(l10n.t.karaokeUi.eachSingerNeedsACalibratedUnassistedResultOnThe),
                    Wrap(
                      spacing: 12,
                      children: [
                        for (final id in s.party.matches[i])
                          TextButton(
                            onPressed: _busy || s.party.matchScores(s.party.matches[i]) == null
                                ? null
                                : () => command('winner', {'match': i, 'singerId': id}),
                            child: Text(
                              l10n.t.karaokeUi.winner(
                                value1: (s.singers.where((p) => p.id == id).firstOrNull?.name ?? id).toString(),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (!s.party.roundRobin && s.party.matches.isEmpty && s.party.winners.length == 1)
            Text(
              l10n.t.karaokeUi.winner(
                value1: (s.singers.where((p) => p.id == s.party.winners.single).firstOrNull?.name ?? '').toString(),
              ),
            ),
          if (s.party.roundRobin)
            for (final e in (s.party.wins.entries.toList()..sort((a, b) => b.value.compareTo(a.value))))
              ListTile(
                title: Text(s.singers.where((p) => p.id == e.key).firstOrNull?.name ?? e.key),
                trailing: Text(l10n.t.karaokeUi.wins(value1: (e.value).toString())),
              ),
          if (s.party.game == 'teams')
            for (final singer in s.singers)
              ListTile(
                title: Text(singer.name),
                trailing: DropdownButton<String>(
                  value: s.party.teams[singer.id],
                  hint: Text(l10n.t.karaokeUi.chooseTeam),
                  items: const [
                    'Team A',
                    'Team B',
                    'Team C',
                    'Team D',
                  ].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
                  onChanged: _busy ? null : (v) => command('team', {'singerId': singer.id, 'team': v}),
                ),
              ),
          if (s.track != null && s.current != null)
            for (final e
                in s.party.standings(s.track!.id, KaraokeScore.rulesVersion, s.current!.key, s.current!.tempo).entries)
              ListTile(
                title: Text(s.singers.where((p) => p.id == e.key).firstOrNull?.name ?? e.key),
                trailing: Text(l10n.t.karaokeUi.average(value1: (e.value.round()).toString())),
              ),
          if (s.party.game != 'tournament')
            TextButton(
              onPressed: _busy ? null : () => command('nextRound'),
              child: Text(l10n.t.karaokeUi.beginAFreshScoreRound),
            ),
          if (s.party.game == 'medley')
            FilledButton(
              onPressed: _busy || s.hasPerformance
                  ? null
                  : () async {
                      try {
                        await s.host('medley');
                      } catch (e) {
                        if (mounted) {
                          setState(() => _error = e.toString());
                        }
                      }
                    },
              child: Text(l10n.t.karaokeUi.startSectionsFromTheNextQueuedSongs),
            ),
          const Divider(),
          Text(l10n.t.karaokeUi.quizInterludes, style: Theme.of(context).textTheme.titleLarge),
          Wrap(
            spacing: 12,
            children: [
              OutlinedButton(onPressed: _busy ? null : question, child: Text(l10n.t.karaokeUi.addQuestion)),
              TextButton(
                onPressed: _busy ? null : () => command('reveal'),
                child: Text(l10n.t.karaokeUi.closeAndRevealAnswer),
              ),
              TextButton(
                onPressed: _busy ? null : () => command('endQuiz'),
                child: Text(l10n.t.karaokeUi.returnToSingerRotation),
              ),
            ],
          ),
          for (var i = 0; i < s.party.questions.length; i++)
            ListTile(
              title: Text(s.party.questions[i]['prompt'] as String),
              subtitle: Text((s.party.questions[i]['options'] as List).join(' · ')),
              trailing: TextButton(
                onPressed: _busy ? null : () => command('startQuestion', {'index': i, 'seconds': 30}),
                child: Text(l10n.t.karaokeUi.askPhones),
              ),
            ),
          for (final p in s.party.quizPoints.entries)
            ListTile(
              title: Text(s.singers.where((s) => s.id == p.key).firstOrNull?.name ?? p.key),
              trailing: Text('${p.value}'),
            ),
          const Divider(),
          Text(l10n.t.karaokeUi.recentPrivateScores, style: Theme.of(context).textTheme.titleLarge),
          for (final result in s.party.results.reversed.take(50))
            ListTile(
              title: Text(s.singers.where((p) => p.id == result['singerId']).firstOrNull?.name ?? ''),
              subtitle: Text(
                l10n.t.karaokeUi.keyTempo(
                  value1: (s.catalog[result['renditionId']]?.title ?? '').toString(),
                  value2: (result['rules']).toString(),
                  value3: (result['key']).toString(),
                  value4: (result['tempo']).toString(),
                ),
              ),
              trailing: Text(result['eligible'] == true ? '${result['score']}' : 'Practice'),
            ),
        ],
      ),
    ),
  );
}

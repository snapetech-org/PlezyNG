import 'dart:math';

/// Private, host-authored party state. Correct answers stay out of guest views.
/// Ranking requires the same rules/key/tempo, calibrated input and no assistance.
class KaraokeParty {
  KaraokeParty();
  final List<Map<String,dynamic>> results=[];
  final Map<String,int> quizPoints={};
  final Map<String,int> answers={};
  final List<Map<String,dynamic>> questions=[];
  List<List<String>> matches=[];
  final List<String> winners=[];
  final Map<String,String> teams={};
  final Map<String,int> wins={};
  bool roundRobin=false;
  String? medleyGroup;
  String game='no-score';
  int round=1,questionIndex=-1;
  int? questionClosesMs;
  bool revealed=false;
  Map<String,dynamic>? get question=>questionIndex>=0 && questionIndex<questions.length ? questions[questionIndex] : null;
  KaraokeParty.fromJson(Map<String,dynamic> j) {
    results.addAll((j['results'] as List? ?? []).map((v)=>Map<String,dynamic>.from(v as Map)));
    questions.addAll((j['questions'] as List? ?? []).map((v)=>Map<String,dynamic>.from(v as Map)));
    quizPoints.addAll(Map<String,int>.from(j['quizPoints'] as Map? ?? {}));
    matches=(j['matches'] as List? ?? []).map((v)=>List<String>.from(v as List)).toList();
    winners.addAll(List<String>.from(j['winners'] as List? ?? []));game=j['game'] as String? ?? 'no-score';round=j['round'] as int? ?? 1;
    teams.addAll(Map<String,String>.from(j['teams'] as Map? ?? {}));wins.addAll(Map<String,int>.from(j['wins'] as Map? ?? {}));roundRobin=j['roundRobin']==true;
    // Recover between questions; never silently reopen a timed answer window.
  }
  Map<String,dynamic> toJson()=>{'schema':1,'teams':teams,'wins':wins,'roundRobin':roundRobin,'results':results,'questions':questions,'quizPoints':quizPoints,'matches':matches,'winners':winners,'game':game,'round':round};
  Map<String,dynamic> view()=>{'game':game,'teams':teams,'wins':wins,'round':round,'matches':matches,'winners':winners,'points':quizPoints,
    'question':question==null ? null : {'prompt':question!['prompt'],'options':question!['options'],'kind':question!['kind'],
      'closesMs':questionClosesMs,'index':questionIndex,'revealed':revealed,if(revealed)'answer':question!['answer']}};
  void addResult(Map<String,dynamic> score,{required String singerId,required String requestId}) {
    if(game=='no-score')return;
    results.removeWhere((r)=>r['singerId']==singerId && r['requestId']==requestId);
    results.add({...score,'game':game,'round':round,'team':teams[singerId],'singerId':singerId,'requestId':requestId,'at':DateTime.now().toUtc().toIso8601String()});
    if(results.length>1000)results.removeAt(0);
  }
  List<Map<String,dynamic>> leaderboard(String renditionId,String rules,double key,double tempo) {
    final list=results.where((r)=>r['eligible']==true && r['assisted']!=true && (r['calibration'] as Map?)?['calibrated']==true &&
      r['renditionId']==renditionId && r['rules']==rules && r['key']==key && r['tempo']==tempo).toList();
    list.sort((a,b)=>(b['score'] as int).compareTo(a['score'] as int));return list;
  }
  Map<String,int>? matchScores(List<String> players) {
    if(players.length!=2)return null;
    final eligible=results.where((r)=>r['round']==round && players.contains(r['singerId']) && r['eligible']==true && r['assisted']!=true && (r['calibration'] as Map?)?['calibrated']==true).toList();
    final a=eligible.where((r)=>r['singerId']==players[0]).toList(),b=eligible.where((r)=>r['singerId']==players[1]).toList();
    if(a.isEmpty || b.isEmpty)return null;
    final left=a.last,right=b.last;
    if(left['renditionId']!=right['renditionId'] || left['rules']!=right['rules'] || left['key']!=right['key'] || left['tempo']!=right['tempo'])return null;
    return {players[0]:left['score'] as int,players[1]:right['score'] as int};
  }
  Map<String,double> standings(String renditionId,String rules,double key,double tempo) {
    final totals=<String,double>{},counts=<String,int>{};
    for(final result in leaderboard(renditionId,rules,key,tempo).where((r)=>r['round']==round)){
      final id=game=='cooperative' ? 'Everyone' : game=='teams' ? result['team'] as String? ?? 'Unassigned' : result['singerId'] as String;
      totals[id]=(totals[id] ?? 0)+(result['score'] as int);counts[id]=(counts[id] ?? 0)+1;
    }
    return {for(final e in totals.entries)e.key:e.value/counts[e.key]!};
  }
  void command(String action,Map<String,dynamic> data,{String? singerId}) {
    if(singerId!=null && action!='answer')throw StateError('Host permission required');
    switch(action) {
      case 'mode':
        final value=data['game'] as String;
        if(!{'no-score','solo','duet','teams','cooperative','battle','tournament','medley','quiz'}.contains(value))throw const FormatException('Unknown party mode');
        game=value;medleyGroup=null;if(value!='tournament'){matches=[];winners.clear();wins.clear();roundRobin=false;round=1;}
      case 'team':
        final singer=data['singerId'] as String,name=(data['team'] as String).trim();
        if(name.isEmpty || name.length>40 || teams.length>=64 && !teams.containsKey(singer))throw const FormatException('Invalid team');teams[singer]=name;
      case 'nextRound': round++;
      case 'tournament':
        final players=List<String>.from(data['singers'] as List).toSet().toList();
        if(players.length<2 || players.length>16)throw const FormatException('Select 2–16 singers');
        players.shuffle(Random.secure());matches=[];winners.clear();wins.clear();round=1;game='tournament';roundRobin=true;
        for(var i=0;i<players.length;i++){wins[players[i]]=0;for(var j=i+1;j<players.length;j++){matches.add([players[i],players[j]]);}}
      case 'winner':
        final index=data['match'] as int,winner=data['singerId'] as String;
        if(index<0 || index>=matches.length || !matches[index].contains(winner))throw const FormatException('Invalid match winner');
        final score=matchScores(matches[index]);if(score==null)throw StateError('Both singers need comparable calibrated scores first');
        if(score[winner]!<=score[matches[index].firstWhere((id)=>id!=winner)]!)throw StateError('The reviewed scores are tied; replay the matchup');
        winners.add(winner);matches.removeAt(index);wins[winner]=(wins[winner] ?? 0)+1;if(roundRobin && matches.isEmpty)round++;
        if(!roundRobin && matches.isEmpty && winners.length>1) {
          final next=winners.toList();winners.clear();round++;
          for(var i=0;i<next.length;i+=2){if(i+1==next.length)winners.add(next[i]);else matches.add([next[i],next[i+1]]);}
        }
      case 'question':
        final prompt=(data['prompt'] as String).trim(),options=List<String>.from(data['options'] as List),answer=data['answer'] as int;
        if(prompt.isEmpty || prompt.length>2000 || options.length<2 || options.length>8 || options.any((o)=>o.isEmpty || o.length>500) || answer<0 || answer>=options.length || questions.length>=100)throw const FormatException('Invalid question');
        questions.add({'prompt':prompt,'options':options,'answer':answer,'kind':data['kind'] ?? 'trivia','authorProvided':true});
      case 'startQuestion':
        final index=data['index'] as int;
        if(index<0 || index>=questions.length)throw const FormatException('Question not found');
        questionIndex=index;answers.clear();revealed=false;game='quiz';
        questionClosesMs=DateTime.now().millisecondsSinceEpoch+((data['seconds'] as int? ?? 30).clamp(5,120))*1000;
      case 'answer':
        final singer=singerId ?? data['singerId'] as String,option=data['option'] as int;
        if(question==null || revealed || DateTime.now().millisecondsSinceEpoch>questionClosesMs! || data['index']!=questionIndex)throw StateError('Question is closed');
        if(option<0 || option>=(question!['options'] as List).length)throw const FormatException('Invalid answer');
        if(answers.containsKey(singer))throw StateError('Answer already submitted');answers[singer]=option;
      case 'reveal':
        if(question==null || revealed)throw StateError('No open question');
        revealed=true;for(final answer in answers.entries){if(answer.value==question!['answer'])quizPoints[answer.key]=(quizPoints[answer.key] ?? 0)+1;}
      case 'endQuiz': questionIndex=-1;questionClosesMs=null;answers.clear();game='no-score';
      default:throw UnsupportedError('Unknown party command');
    }
  }
}

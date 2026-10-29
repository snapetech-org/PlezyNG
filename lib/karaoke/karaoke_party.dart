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
    // Recover between questions; never silently reopen a timed answer window.
  }
  Map<String,dynamic> toJson()=>{'schema':1,'results':results,'questions':questions,'quizPoints':quizPoints,'matches':matches,'winners':winners,'game':game,'round':round};
  Map<String,dynamic> view()=>{'game':game,'round':round,'matches':matches,'winners':winners,'points':quizPoints,
    'question':question==null ? null : {'prompt':question!['prompt'],'options':question!['options'],'kind':question!['kind'],
      'closesMs':questionClosesMs,'index':questionIndex,'revealed':revealed,if(revealed)'answer':question!['answer']}};
  void addResult(Map<String,dynamic> score,{required String singerId,required String requestId}) {
    if(results.any((r)=>r['singerId']==singerId && r['requestId']==requestId))return;
    results.add({...score,'singerId':singerId,'requestId':requestId,'at':DateTime.now().toUtc().toIso8601String()});
    if(results.length>1000)results.removeAt(0);
  }
  List<Map<String,dynamic>> leaderboard(String renditionId,String rules,double key,double tempo) {
    final list=results.where((r)=>r['eligible']==true && r['assisted']!=true && (r['calibration'] as Map?)?['calibrated']==true &&
      r['renditionId']==renditionId && r['rules']==rules && r['key']==key && r['tempo']==tempo).toList();
    list.sort((a,b)=>(b['score'] as int).compareTo(a['score'] as int));return list;
  }
  void command(String action,Map<String,dynamic> data,{String? singerId}) {
    if(singerId!=null && action!='answer')throw StateError('Host permission required');
    switch(action) {
      case 'mode':
        final value=data['game'] as String;
        if(!{'no-score','solo','duet','teams','cooperative','battle','tournament','medley','quiz'}.contains(value))throw const FormatException('Unknown party mode');
        game=value;
      case 'tournament':
        final players=List<String>.from(data['singers'] as List).toSet().toList();
        if(players.length<2 || players.length>64)throw const FormatException('Select 2–64 singers');
        players.shuffle(Random.secure());matches=[];winners.clear();round=1;game='tournament';
        for(var i=0;i<players.length;i+=2) { if(i+1==players.length)winners.add(players[i]);else matches.add([players[i],players[i+1]]); }
      case 'winner':
        final index=data['match'] as int,winner=data['singerId'] as String;
        if(index<0 || index>=matches.length || !matches[index].contains(winner))throw const FormatException('Invalid match winner');
        winners.add(winner);matches.removeAt(index);
        if(matches.isEmpty && winners.length>1) {
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

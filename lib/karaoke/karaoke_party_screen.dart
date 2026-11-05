import 'package:flutter/material.dart';
import 'karaoke_session.dart';
import 'karaoke_scoring.dart';

class KaraokePartyScreen extends StatefulWidget {
  const KaraokePartyScreen({super.key,required this.session});
  final KaraokeSession session;
  @override State<KaraokePartyScreen> createState()=>_KaraokePartyScreenState();
}
class _KaraokePartyScreenState extends State<KaraokePartyScreen> {
  bool _busy=false;
  String? _error;
  KaraokeSession get s=>widget.session;
  Future<void> command(String operation,[Map<String,dynamic> data=const {}]) async {
    if(_busy)return;setState(()=>_busy=true);
    try {await s.host('party',{'operation':operation,'data':data});}
    catch(e){_error=e.toString();}finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> question() async {
    final prompt=TextEditingController(),options=TextEditingController(),answer=TextEditingController(text:'1');
    final save=await showDialog<bool>(context:context,builder:(context)=>AlertDialog(title:const Text('Add a question you authored or may use'),
      content:SizedBox(width:500,child:SingleChildScrollView(child:Column(children:[
        TextField(controller:prompt,maxLength:2000,decoration:const InputDecoration(labelText:'Trivia / lyric completion / name that tune prompt')),
        TextField(controller:options,minLines:3,maxLines:8,decoration:const InputDecoration(labelText:'Options, one per line')),
        TextField(controller:answer,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Correct option number (starting at 1)')),
      ]))),actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('Cancel')),
        FilledButton(onPressed:()=>Navigator.pop(context,true),child:const Text('Add'))]));
    if(save==true)await command('question',{'prompt':prompt.text,'options':options.text.split('\n').where((s)=>s.trim().isNotEmpty).toList(),
      'answer':(int.tryParse(answer.text) ?? 0)-1});
    prompt.dispose();options.dispose();answer.dispose();
  }
  @override Widget build(BuildContext context)=>AnimatedBuilder(animation:s,builder:(context,_)=>Scaffold(
    appBar:AppBar(title:const Text('Party rounds')),body:ListView(padding:const EdgeInsets.all(16),children:[
      if(_busy)const LinearProgressIndicator(),if(_error!=null)Text(_error!,style:TextStyle(color:Theme.of(context).colorScheme.error)),
      const Text('Scores stay private. Leaderboards compare reviewed charts with matching settings and calibrated, unassisted input. No-score singing is always available.'),
      DropdownButton<String>(value:s.party.game,items:const ['no-score','solo','duet','teams','cooperative','battle','tournament','medley','quiz']
        .map((v)=>DropdownMenuItem(value:v,child:Text(v))).toList(),onChanged:_busy ? null : (v)=>command('mode',{'game':v})),
      OutlinedButton(onPressed:_busy || s.singers.where((p)=>!p.absent).length<2 ? null : ()=>command('tournament',
        {'singers':s.singers.where((p)=>!p.absent).map((p)=>p.id).toList()}),child:const Text('Start a round-robin tournament with present singers')),
      if(s.party.matches.isNotEmpty)Text('Round ${s.party.round}',style:Theme.of(context).textTheme.titleLarge),
      for(var i=0;i<s.party.matches.length;i++)Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text('Match ${i+1}: ${s.party.matches[i].map((id)=>s.singers.where((p)=>p.id==id).firstOrNull?.name ?? id).join(' vs ')}'),
        if(s.party.matchScores(s.party.matches[i]) case final scores?)Text('Verified eligible scores · ${scores.values.join(' – ')}'),
        if(s.party.matchScores(s.party.matches[i])==null)const Text('Each singer needs a calibrated, unassisted result on the same reviewed rendition and settings before this match can be resolved.'),
        Wrap(spacing:12,children:[for(final id in s.party.matches[i])TextButton(onPressed:_busy || s.party.matchScores(s.party.matches[i])==null ? null :
          ()=>command('winner',{'match':i,'singerId':id}),child:Text('Winner: ${s.singers.where((p)=>p.id==id).firstOrNull?.name ?? id}'))]),
      ]))),
      if(!s.party.roundRobin && s.party.matches.isEmpty && s.party.winners.length==1)Text('Winner: ${s.singers.where((p)=>p.id==s.party.winners.single).firstOrNull?.name ?? ''}'),
      if(s.party.roundRobin)for(final e in (s.party.wins.entries.toList()..sort((a,b)=>b.value.compareTo(a.value))))ListTile(
        title:Text(s.singers.where((p)=>p.id==e.key).firstOrNull?.name ?? e.key),trailing:Text('${e.value} wins')),
      if(s.party.game=='teams')for(final singer in s.singers)ListTile(title:Text(singer.name),trailing:DropdownButton<String>(value:s.party.teams[singer.id],
        hint:const Text('Choose team'),items:const ['Team A','Team B','Team C','Team D'].map((v)=>DropdownMenuItem(value:v,child:Text(v))).toList(),
        onChanged:_busy ? null : (v)=>command('team',{'singerId':singer.id,'team':v}))),
      if(s.track!=null && s.current!=null)for(final e in s.party.standings(s.track!.id,KaraokeScore.rulesVersion,s.current!.key,s.current!.tempo).entries)
        ListTile(title:Text(s.singers.where((p)=>p.id==e.key).firstOrNull?.name ?? e.key),trailing:Text('${e.value.round()} average')),
      if(s.party.game!='tournament')TextButton(onPressed:_busy ? null : ()=>command('nextRound'),child:const Text('Begin a fresh score round')),
      if(s.party.game=='medley')FilledButton(onPressed:_busy || s.hasPerformance ? null : ()async{try{await s.host('medley');}catch(e){if(mounted)setState(()=>_error=e.toString());}},child:const Text('Start sections from the next queued songs')),
      const Divider(),Text('Quiz interludes',style:Theme.of(context).textTheme.titleLarge),
      Wrap(spacing:12,children:[OutlinedButton(onPressed:_busy ? null : question,child:const Text('Add question')),
        TextButton(onPressed:_busy ? null : ()=>command('reveal'),child:const Text('Close and reveal answer')),
        TextButton(onPressed:_busy ? null : ()=>command('endQuiz'),child:const Text('Return to singer rotation'))]),
      for(var i=0;i<s.party.questions.length;i++)ListTile(title:Text(s.party.questions[i]['prompt'] as String),
        subtitle:Text((s.party.questions[i]['options'] as List).join(' · ')),trailing:TextButton(onPressed:_busy ? null :
          ()=>command('startQuestion',{'index':i,'seconds':30}),child:const Text('Ask phones'))),
      for(final p in s.party.quizPoints.entries)ListTile(title:Text(s.singers.where((s)=>s.id==p.key).firstOrNull?.name ?? p.key),trailing:Text('${p.value}')),
      const Divider(),Text('Recent private scores',style:Theme.of(context).textTheme.titleLarge),
      for(final result in s.party.results.reversed.take(50))ListTile(title:Text(s.singers.where((p)=>p.id==result['singerId']).firstOrNull?.name ?? ''),
        subtitle:Text('${s.catalog[result['renditionId']]?.title ?? ''} · ${result['rules']} · key ${result['key']} · tempo ${result['tempo']}'),
        trailing:Text(result['eligible']==true ? '${result['score']}' : 'Practice')),
    ])));
}

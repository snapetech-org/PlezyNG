import 'package:flutter/widgets.dart';

/// Stable keys with an explicit English fallback. Keep this small feature
/// catalog independent of generated Slang files until the next locale rebuild.
String karaokeText(BuildContext context,String key) {
  final locale=Localizations.localeOf(context).languageCode;
  return karaokeTranslations[locale]?[key] ?? karaokeTranslations['en']![key] ?? key;
}
const karaokeTranslations=<String,Map<String,String>>{
  'en':{
    'title':'Karaoke','sing':'Sing','host':'Host','practice':'Practice','library':'Songbook','queue':'Singers & queue',
    'import':'Import songs','search':'Search title, artist or collection','addSinger':'Add singer','singerName':'Singer name',
    'request':'Add to rotation','start':'Start','resume':'Resume','pause':'Pause','next':'Finish / next singer','stage':'Stage view',
    'stop':'End performance','approve':'Approve','reject':'Reject','absent':'Absent','favorite':'Favorite','editor':'Edit lyrics and notes',
    'key':'Key (semitones)','tempo':'Tempo','reset':'Reset','loopStart':'Set loop start','loopEnd':'Set loop end','clearLoop':'Clear loop',
    'skip':'Skip to singing','undoSkip':'Undo skip','save':'Save','cancel':'Cancel','export':'Export package','empty':'Import karaoke files or choose Sing from a music track.',
    'noLyrics':'No lyric track. Import timed lyrics in the editor.','untimed':'Untimed lyrics','countIn':'Get ready','upNext':'Up next',
    'fair':'Fair singer rotation','approval':'Approve guest requests','explicit':'Allow explicit songs','offline':'Local packages',
    'duets':'Duets','refresh':'Search media servers','guest':'Guest songbook','notScored':'Sing-along · no reviewed score chart',
    'reviewed':'Reviewed note chart','ready':'Ready','pending':'Awaiting host approval','close':'Close','settings':'Room settings',
    'imported':'Imported','noQueue':'Add a singer and request a song.','playing':'Singing now','return':'Return to host',
    'verify':'Check offline assets','remove':'Remove local package','error':'Karaoke could not complete the action',
  },
  'de':{'title':'Karaoke','sing':'Singen','host':'Moderieren','practice':'Üben','library':'Liederbuch','queue':'Sänger und Warteschlange',
    'import':'Lieder importieren','search':'Titel, Künstler oder Sammlung suchen','addSinger':'Sänger hinzufügen','singerName':'Name',
    'request':'Einreihen','start':'Starten','resume':'Fortsetzen','pause':'Pause','stage':'Bühnenansicht','stop':'Auftritt beenden',
    'approve':'Genehmigen','reject':'Ablehnen','favorite':'Favorit','key':'Tonart (Halbtöne)','tempo':'Tempo','reset':'Zurücksetzen',
    'save':'Speichern','cancel':'Abbrechen','close':'Schließen','settings':'Raumeinstellungen','guest':'Gäste-Liederbuch'},
  'es':{'title':'Karaoke','sing':'Cantar','host':'Organizar','practice':'Practicar','library':'Cancionero','queue':'Cantantes y cola',
    'import':'Importar canciones','search':'Buscar título, artista o colección','addSinger':'Añadir cantante','singerName':'Nombre',
    'request':'Añadir a la rotación','start':'Iniciar','resume':'Continuar','pause':'Pausa','stage':'Vista del escenario','stop':'Terminar actuación',
    'approve':'Aprobar','reject':'Rechazar','favorite':'Favorito','key':'Tonalidad (semitonos)','tempo':'Tempo','reset':'Restablecer',
    'save':'Guardar','cancel':'Cancelar','close':'Cerrar','settings':'Ajustes de la sala','guest':'Cancionero para invitados'},
  'fr':{'title':'Karaoké','sing':'Chanter','host':'Animer','practice':'Répéter','library':'Catalogue','queue':'Chanteurs et file',
    'import':'Importer des chansons','search':'Rechercher un titre, artiste ou recueil','addSinger':'Ajouter un chanteur','singerName':'Nom',
    'request':'Ajouter à la rotation','start':'Démarrer','resume':'Reprendre','pause':'Pause','stage':'Vue de scène','stop':'Terminer la prestation',
    'approve':'Approuver','reject':'Refuser','favorite':'Favori','key':'Tonalité (demi-tons)','tempo':'Tempo','reset':'Réinitialiser',
    'save':'Enregistrer','cancel':'Annuler','close':'Fermer','settings':'Réglages de la salle','guest':'Catalogue des invités'},
};

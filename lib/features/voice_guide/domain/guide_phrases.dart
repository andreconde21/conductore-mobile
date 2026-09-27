import 'package:conduit/features/voice/domain/voice_answers.dart';
import 'package:conduit/features/voice_guide/domain/guide_intent.dart';

/// The voice guide's offline commands: common phrases in English and
/// Portuguese matched on the phone, instantly. Anything else ([match]
/// returns null) goes to the brain machine.
///
/// Whole phrases only: "open" must start the utterance, so "the tests
/// that open a socket failed" is never a command.
abstract final class GuidePhrases {
  /// Lower case, punctuation gone (apostrophes and hyphens kept inside
  /// words), single spaces, polite openers and closers dropped.
  static String normalize(String text) {
    var s = text
        .toLowerCase()
        .replaceAll('’', "'")
        .replaceAll(RegExp(r"[^\p{L}\p{N}' -]", unicode: true), ' ')
        .replaceAll(RegExp(r"(?<!\p{L})['-]|['-](?!\p{L})", unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    for (var i = 0; i < 3; i++) {
      final before = s;
      s = s.replaceFirst(_opener, '').replaceFirst(_closer, '').trim();
      if (s == before) break;
    }
    return s;
  }

  static final _opener = RegExp(
    r'^(hey conductore|ok conductore|conductore|hey|ok|okay|please|'
    r'can you|could you|would you|i want to|i want you to|'
    r'por favor|podes|pode|consegues|quero)\s+',
  );
  static final _closer = RegExp(r'\s+(please|por favor|now|agora)$');

  static RegExp _re(String pattern) => RegExp('^(?:$pattern)\$', unicode: true);

  static final _stop = _re(
    r"stop|cancel|never ?mind|quiet|be quiet|shut up|that'?s all|that is all|"
    r'thanks|thank you|goodbye|bye|exit|close|done|'
    r'pára|para|parar|pare|cancela|cancelar|chega|obrigad[oa]|adeus|sai|'
    r'sair|silêncio|esquece|já está|ja esta',
  );

  static final _help = _re(
    r'help|what can (i|you) (say|do)|commands|ajuda|o que posso dizer|'
    r'o que (é que )?(sabes|podes) fazer',
  );

  static final _waiting = _re(
    r"(show me )?(what'?s|what is) (waiting|pending)( for me)?|what needs me|"
    r'what needs (my )?(attention|approval)|who needs me|'
    r'(is |does )?anything (waiting|need me|needs me)|'
    r"(what'?s|what is) (going on|up|happening)|status|"
    r'(o )?que (é que )?(está|esta|estão|estao) (à|a) espera|'
    r'(o )?que (é que )?precisa de mim|quem precisa de mim|'
    r'(há|ha) (algo|alguma coisa) (à|a) espera|'
    r'(o )?que (é que )?(há|ha) (de novo|pendente)|pendentes|estado',
  );

  static final _home = _re(
    r'(go )?(back )?home|(go to|back to|open)( the)? home( screen)?|'
    r'home screen|(vai|ir|volta|voltar) (para|ao) (o )?(início|inicio|ecrã inicial)|'
    r'início|inicio|ecrã inicial',
  );

  static final _chat = _re(
    r'((go|switch|back) to|open|show)( the)? chat( view| mode)?|chat( view| mode)?|'
    r'(vai|ir|muda|mudar|volta) (para|ao) (o )?(chat|modo chat)|'
    r'(abre|mostra) o chat|modo chat',
  );

  static final _terminal = _re(
    r'((go|switch|back) to|open|show)( the)? terminal|terminal|'
    r'(vai|ir|muda|mudar|volta) (para|ao) (o )?terminal|(abre|mostra) o terminal',
  );

  static final _approveAllSafe = _re(
    r'approve (all|everything)( the)? (safe|low[ -]risk)( ones| requests| ones too)?|'
    r'approve (all|everything)( of them)?|aprova(r)? (tudo|todos|todas)|'
    r'approve all( that is| that.s)? safe|approve (the )?safe (ones|requests)|'
    r'aprova(r)? (tudo|todos|todas)( o que é| os| as)? (seguro|seguros|seguras)|'
    r'aprova(r)? (os|as) (seguros|seguras)',
  );

  static final _approve = _decision(
    'approve|allow|accept|yes approve|aprova|aprovar|permite|permitir|'
    'autoriza|autorizar|aceita|aceitar',
  );

  static final _deny = _decision(
    'deny|reject|refuse|decline|block|nega|negar|recusa|recusar|rejeita|'
    'rejeitar|bloqueia|bloquear',
  );

  /// A verdict verb, then optionally "it", a preposition and a name:
  /// "approve", "approve it", "approve for api", "nega o pedido do web".
  static RegExp _decision(String verbs) => RegExp(
    '^(?:$verbs)'
    r'(?: (?:it|that|this|isso|isto|o pedido|the request|the one))?'
    r'(?: (?:for|on|from|of|para|de|do|da|no|na|ao|à))?'
    r'(?: (.+))?$',
    unicode: true,
  );

  static final _read = RegExp(
    r'^(?:read|read me|read out|say|repeat|what did|lê|le|lê-me|ler|repete)'
    r'(?: (?:me|the|a|o))?'
    r'(?: (?:last|latest|última|ultima))?'
    r' (?:reply|answer|message|response|resposta|mensagem)'
    r'(?: (?:from|of|by|do|da|de) (.+))?$',
    unicode: true,
  );

  static final _readWhatSaid = RegExp(
    r'^what did (.+?) (?:say|answer|reply)$|^o que (?:é que )?(?:o |a )?(.+?) disse$',
    unicode: true,
  );

  static final _trust = RegExp(
    r'^(?:trust|confia|confiar)(?: (?:em|no|na))?'
    r'(?: (.*?))?'
    r' (?:for|durante|por) (.+?) ?(minutes?|mins?|hours?|minutos?|horas?|hora)?$',
    unicode: true,
  );

  static final _send = RegExp(
    r'^(?:tell|ask) (.+?) (?:to|that) (.+)$|'
    r'^(?:diz|diga|dizer|pede|peça|peca|pedir|manda|mandar)'
    r' (?:ao |à |a |aos |às |o )?(.+?) (?:para|que) (.+)$',
    unicode: true,
  );

  static final _account = RegExp(
    r'^(?:switch|change)(?: (?:to|account to))?(?: the)? (.+?) account$|'
    r'^(?:switch|change) account(?: to)? (.+)$|'
    r'^(?:muda|mudar|troca|trocar)(?: de)? conta(?: para)? (?:a |o )?(.+)$|'
    r'^(?:muda|mudar|troca|trocar) para a conta (?:do |da |de )?(.+)$',
    unicode: true,
  );

  static final _usage = _re(
    r"(what'?s|what is|how'?s|how is|show|check|read)( me)?( my)?( the)? "
    r'(usage|limits?|quota)( left)?|(my )?usage|'
    r'how much (usage|quota|limit)( do i have)?( left)?|'
    r'(qual é|qual e|como está|como esta|mostra)( o| os)?( meu| meus)? '
    r'(uso|consumo|limites?)|(o )?(meu )?(uso|consumo)|quanto (uso|consumo|falta)',
  );

  static final _open = RegExp(
    r'^(?:open|show|show me|go to|switch to|take me to|jump to|bring up|'
    r'abre|abrir|abra|mostra|mostrar|mostra-me|vai para|ir para|vai ao|'
    r'vai à|leva-me ao|leva-me à|leva-me para|muda para)'
    r' (?:the |o |a |os |as )?(.+)$',
    unicode: true,
  );

  static final _kindWord = RegExp(
    r'\s+(agent|agents|workspace|project|machine|session|server|'
    r'agente|projeto|projecto|máquina|maquina|sessão|sessao|servidor)$',
    unicode: true,
  );

  static final _leadingKind = RegExp(
    r'^(the |o |a )?(agent|workspace|project|machine|session|agente|'
    r'projeto|projecto|máquina|maquina|sessão|sessao) ',
    unicode: true,
  );

  /// The intent of [spoken], or null when it is not a phrase the phone
  /// knows (the brain gets it).
  static GuideIntent? match(String spoken) {
    final text = normalize(spoken);
    if (text.isEmpty) return null;
    if (_stop.hasMatch(text)) return const GuideStop();
    if (VoiceAnswers.isMore(text)) return const GuideMore();
    if (_help.hasMatch(text)) return const GuideHelp();
    if (_waiting.hasMatch(text)) return const GuideWhatsWaiting();
    if (_home.hasMatch(text)) return const GuideHome();
    if (_chat.hasMatch(text)) return const GuideShowChat();
    if (_terminal.hasMatch(text)) return const GuideShowTerminal();
    if (_approveAllSafe.hasMatch(text)) return const GuideApproveAllSafe();
    if (_usage.hasMatch(text)) return const GuideUsage();
    if (_approve.firstMatch(text) case final m?) {
      return GuideDecide(allow: true, target: _ref(m.group(1)));
    }
    if (_deny.firstMatch(text) case final m?) {
      return GuideDecide(allow: false, target: _ref(m.group(1)));
    }
    if (_read.firstMatch(text) case final m?) {
      return GuideRead(_ref(m.group(1)));
    }
    if (_readWhatSaid.firstMatch(text) case final m?) {
      return GuideRead(_ref(m.group(1) ?? m.group(2)));
    }
    if (_trust.firstMatch(text) case final m?) {
      final minutes = _minutes(m.group(2)!, m.group(3));
      if (minutes != null) {
        final who = (m.group(1) ?? '').trim();
        final current =
            who.isEmpty ||
            const {
              'this',
              'it',
              'that',
              'isto',
              'isso',
              'this one',
              'nisto',
              'nisso',
            }.contains(who);
        return GuideTrust(minutes, current ? null : _ref(who));
      }
    }
    if (_send.firstMatch(text) case final m?) {
      final who = m.group(1) ?? m.group(3);
      final what = m.group(2) ?? m.group(4);
      final ref = _ref(who);
      if (ref != null && what != null && what.trim().isNotEmpty) {
        return GuideSend(ref, _prompt(what));
      }
    }
    if (_account.firstMatch(text) case final m?) {
      final account = [
        for (var i = 1; i <= m.groupCount; i++) ?m.group(i),
      ].firstOrNull;
      if (account != null) return GuideSwitchAccount(account.trim());
    }
    if (_open.firstMatch(text) case final m?) {
      final ref = _ref(m.group(1));
      if (ref != null) return GuideOpen(ref);
    }
    return null;
  }

  static GuideRef? _ref(String? raw) {
    if (raw == null) return null;
    var name = raw.trim().replaceFirst(_leadingKind, '').trim();
    name = name.replaceFirst(_kindWord, '').trim();
    name = name.replaceFirst(RegExp(r'^(the|o|a|os|as) '), '').trim();
    if (name.isEmpty ||
        const {'it', 'that', 'this', 'isso', 'isto', 'one'}.contains(name)) {
      return null;
    }
    return GuideByName(name);
  }

  /// The prompt as the agent should read it: first letter up, the rest as
  /// said.
  static String _prompt(String said) {
    final text = said.trim();
    return text[0].toUpperCase() + text.substring(1);
  }

  static const _numbers = <String, int>{
    'a': 1,
    'an': 1,
    'one': 1,
    'um': 1,
    'uma': 1,
    'two': 2,
    'dois': 2,
    'duas': 2,
    'three': 3,
    'três': 3,
    'tres': 3,
    'four': 4,
    'quatro': 4,
    'five': 5,
    'cinco': 5,
    'ten': 10,
    'dez': 10,
    'fifteen': 15,
    'quinze': 15,
    'twenty': 20,
    'vinte': 20,
    'thirty': 30,
    'trinta': 30,
    'forty': 40,
    'quarenta': 40,
    'forty-five': 45,
    'forty five': 45,
    'quarenta e cinco': 45,
    'sixty': 60,
    'sessenta': 60,
    'ninety': 90,
    'noventa': 90,
  };

  /// Minutes in "15 minutes", "an hour", "half an hour", "meia hora".
  static int? _minutes(String amount, String? unit) {
    var words = amount.trim();
    if (RegExp(r'^(half an|half a|meia)$').hasMatch(words) ||
        words == 'half an hour' ||
        words == 'meia hora') {
      return 30;
    }
    words = words.replaceFirst(
      RegExp(r'^(the next|next|os próximos|as próximas) '),
      '',
    );
    final n = int.tryParse(words) ?? _numbers[words];
    if (n == null || n <= 0) return null;
    final hours =
        unit != null && RegExp(r'^(hours?|horas?|hora)$').hasMatch(unit);
    final minutes = hours ? n * 60 : n;
    return unit == null && !hours ? null : minutes;
  }

  static const _yes = [
    'yes',
    'yeah',
    'yep',
    'yup',
    'sure',
    'ok',
    'okay',
    'confirm',
    'confirmed',
    'do it',
    'go ahead',
    'go',
    'correct',
    'right',
    'affirmative',
    'please do',
    'sim',
    'confirmo',
    'confirma',
    'pode',
    'podes',
    'claro',
    'isso',
    'certo',
    'avança',
    'avanca',
    'força',
    'forca',
  ];

  static const _no = [
    'no',
    'nope',
    'nah',
    'cancel',
    "don't",
    'do not',
    'stop',
    'negative',
    'wait',
    'não',
    'nao',
    'cancela',
    'cancelar',
    'espera',
    'pára',
    'para',
  ];

  /// A yes or no to a confirmation question, or null when unclear. "No"
  /// wins, so "no, don't" and "yes, no wait" are both a no.
  static bool? yesNo(String spoken) {
    final text = ' ${normalize(spoken)} ';
    if (text.trim().isEmpty) return null;
    if (_no.any((word) => text.contains(' $word '))) return false;
    if (_yes.any((word) => text.contains(' $word '))) return true;
    return null;
  }
}

import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/voice_guide/domain/guide_world.dart';

/// Everything the guide says, short, in English or Portuguese.
abstract class GuideStrings {
  const GuideStrings();

  /// Portuguese for a `pt` language tag, else English.
  factory GuideStrings.of(String language) =>
      language.toLowerCase().startsWith('pt')
      ? const _Portuguese()
      : const _English();

  String get code;

  String get listening;
  String get thinking;
  String get oneMoment;
  String get off;
  String get disabled;
  String get locked;
  String get ok;
  String get cancelled;
  String get sayYesOrNo;
  String get didNotCatch;
  String get noBrain;
  String brainFailed(String reason);
  String get micBusy;
  String get help;
  String get nothingMore;
  String get noAgentOnScreen;
  String get notAvailableTrust;
  String get notAvailableApproveAll;
  String get notAvailableAccounts;
  String get noSafeRequests;
  String get noRequests;
  String get requestGone;
  String get sent;
  String get approved;
  String get denied;
  String approvedCount(int count);
  String trusted(String agent, int minutes);
  String get home;
  String get noUsage;
  String get pickOnScreen;

  String notFound(String? name);
  String ended(String agent);
  String ambiguous(List<GuideAgent> agents);
  String severalRequests(int count);
  String opening(String what);
  String openingChat(String agent);
  String openingTerminal(String agent);
  String noChat(String agent);
  String noReply(String agent);
  String replyFrom(String agent, String text);
  String confirmApprove(GuidePending pending);
  String confirmDeny(GuidePending pending);
  String confirmApproveAll(int count);
  String confirmTrust(GuidePending pending, int minutes);
  String nothingToTrust(String agent);
  String get trustHighRisk;
  String confirmSend(String agent, String text);
  String failed(String what);
  String waiting(GuideWorld world);

  /// "api" or "api on VTM" when agents on several machines share the name.
  String agentName(GuideAgent agent, GuideWorld world) {
    final same = world.agents
        .where((other) => other.label == agent.label && !other.same(agent))
        .any((other) => other.hostId != agent.hostId);
    final many = {for (final a in world.agents) a.hostId}.length > 1;
    return same || many
        ? '${agent.label} $onWord ${agent.machineName}'
        : agent.label;
  }

  String get onWord;

  static String _cap(String text, int max) {
    final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length <= max ? t : '${t.substring(0, max - 1)}…';
  }

  /// [text] as the end of a question: its own ? kept, a . or ! turned
  /// into one.
  static String asQuestion(String text) {
    final t = _cap(text, 160);
    if (t.endsWith('?')) return t;
    return '${t.replaceFirst(RegExp(r'[.!…]+$'), '')}?';
  }

  /// The request in a few words: "npm test", else the tool name.
  static String requestLabel(PendingPermissionRequest request) {
    final summary = request.summary.trim();
    return _cap(summary.isNotEmpty ? summary : request.toolName, 80);
  }
}

class _English extends GuideStrings {
  const _English();

  @override
  String get code => 'en';
  @override
  String get onWord => 'on';
  @override
  String get listening => 'Listening…';
  @override
  String get thinking => 'Thinking…';
  @override
  String get oneMoment => 'One moment.';
  @override
  String get off => 'Guide off.';
  @override
  String get disabled => 'The voice guide is off in Settings.';
  @override
  String get locked => 'Unlock Conductore first.';
  @override
  String get ok => 'OK.';
  @override
  String get cancelled => 'Cancelled.';
  @override
  String get sayYesOrNo => 'Say yes or no.';
  @override
  String get didNotCatch =>
      "Sorry, I didn't get that. Say help for the commands.";
  @override
  String get noBrain =>
      'I only know the simple commands right now: no machine can answer '
      'the rest. Say help.';
  @override
  String brainFailed(String reason) => switch (reason) {
    'outdated' => 'The brain machine needs a companion update.',
    'claude-missing' => 'Claude Code is not installed on the brain machine.',
    'not-logged-in' => 'Claude is not logged in on the brain machine.',
    'timeout' => 'The brain machine took too long.',
    'busy' => 'The brain machine is busy. Try again.',
    'unreachable' => "I can't reach the brain machine.",
    _ => "Sorry, that didn't work.",
  };
  @override
  String get micBusy => 'The microphone is busy. Guide off.';
  @override
  String get help =>
      "Say: what's waiting, open and a name, approve, deny, tell an agent to "
      'do something, read the last reply, go to chat, go to terminal, home, '
      "what's my usage, or stop.";
  @override
  String get nothingMore => "That's all.";
  @override
  String get noAgentOnScreen => 'No agent is on screen. Say open and a name.';
  @override
  String get notAvailableTrust => "Trusting an agent isn't available yet.";
  @override
  String get notAvailableApproveAll => "Approve all safe isn't available yet.";
  @override
  String get notAvailableAccounts => "Switching accounts isn't available yet.";
  @override
  String get noSafeRequests => 'No low-risk requests are waiting.';
  @override
  String get noRequests => 'No approvals are waiting.';
  @override
  String get requestGone => 'That request was already answered or timed out.';
  @override
  String get sent => 'Sent.';
  @override
  String get approved => 'Approved.';
  @override
  String get denied => 'Denied.';
  @override
  String approvedCount(int count) =>
      count == 1 ? 'Approved one.' : 'Approved $count.';
  @override
  String trusted(String agent, int minutes) =>
      'Trusting $agent for ${_duration(minutes)}.';
  @override
  String get home => 'Home.';
  @override
  String get noUsage => 'No usage figures yet.';
  @override
  String get pickOnScreen => 'Pick a session on screen.';

  @override
  String notFound(String? name) =>
      name == null ? "That's gone." : "I can't find $name.";
  @override
  String ended(String agent) => '$agent has ended.';
  @override
  String ambiguous(List<GuideAgent> agents) {
    final names = agents
        .take(3)
        .map((a) => '${a.label} on ${a.machineName}')
        .join(', ');
    return 'Which one: $names?';
  }

  @override
  String severalRequests(int count) =>
      '$count approvals are waiting. Say approve and the agent name.';
  @override
  String opening(String what) => 'Opening $what.';
  @override
  String openingChat(String agent) => 'Chat with $agent.';
  @override
  String openingTerminal(String agent) => 'Terminal of $agent.';
  @override
  String noChat(String agent) =>
      "$agent can't open as a chat here. Showing the terminal.";
  @override
  String noReply(String agent) => '$agent has no reply yet.';
  @override
  String replyFrom(String agent, String text) => '$agent says: $text';
  @override
  String confirmApprove(GuidePending pending) =>
      'Approve ${GuideStrings.requestLabel(pending.request)} for '
      '${pending.agent.label} on ${pending.agent.machineName}? Say yes.';
  @override
  String confirmDeny(GuidePending pending) =>
      'Deny ${GuideStrings.requestLabel(pending.request)} for '
      '${pending.agent.label}? Say yes.';
  @override
  String confirmApproveAll(int count) => count == 1
      ? 'Approve one low-risk request? Say yes.'
      : 'Approve $count low-risk requests? Say yes.';
  @override
  String confirmTrust(GuidePending pending, int minutes) =>
      'Trust ${pending.agent.label} to run '
      '${GuideStrings.requestLabel(pending.request)} and the like for '
      '${_duration(minutes)}? Say yes.';
  @override
  String nothingToTrust(String agent) =>
      '$agent has no request waiting to trust.';
  @override
  String get trustHighRisk =>
      "That request is high risk, so it can't be trusted. Say approve to "
      'answer just this one.';
  @override
  String confirmSend(String agent, String text) =>
      'Send to $agent: ${GuideStrings.asQuestion(text)} Say yes.';
  @override
  String failed(String what) => "That didn't work: $what";

  static String _duration(int minutes) {
    if (minutes % 60 == 0) {
      final hours = minutes ~/ 60;
      return hours == 1 ? 'an hour' : '$hours hours';
    }
    return minutes == 1 ? 'a minute' : '$minutes minutes';
  }

  @override
  String waiting(GuideWorld world) {
    final pending = world.pending;
    final input = [
      for (final agent in world.live)
        if (agent.pending.isEmpty && agent.info.state.needsAttention) agent,
    ];
    final idle = [
      for (final agent in world.live)
        if (agent.pending.isEmpty &&
            (agent.info.state == AgentAttentionState.idle))
          agent,
    ];
    final working = world.live
        .where((a) => a.info.state == AgentAttentionState.working)
        .length;
    final parts = <String>[];
    if (pending.isNotEmpty) {
      final shown = pending
          .take(3)
          .map(
            (p) =>
                '${agentName(p.agent, world)} wants '
                '${GuideStrings.requestLabel(p.request)}',
          )
          .join('; ');
      parts.add(
        pending.length == 1
            ? 'One approval: $shown.'
            : '${pending.length} approvals: $shown.',
      );
    }
    if (input.isNotEmpty) {
      final names = input.take(3).map((a) => agentName(a, world)).join(', ');
      parts.add(
        input.length == 1
            ? '$names needs input.'
            : '${input.length} need input: $names.',
      );
    }
    if (idle.isNotEmpty) {
      final names = idle.take(3).map((a) => agentName(a, world)).join(', ');
      parts.add(
        idle.length == 1 ? '$names is idle.' : '${idle.length} idle: $names.',
      );
    }
    if (parts.isEmpty) {
      if (world.live.isEmpty) return 'No agents are running.';
      return working == 1
          ? 'Nothing is waiting. One agent is working.'
          : 'Nothing is waiting. $working agents are working.';
    }
    return parts.join(' ');
  }
}

class _Portuguese extends GuideStrings {
  const _Portuguese();

  @override
  String get code => 'pt';
  @override
  String get onWord => 'em';
  @override
  String get listening => 'A ouvir…';
  @override
  String get thinking => 'A pensar…';
  @override
  String get oneMoment => 'Um momento.';
  @override
  String get off => 'Guia desligado.';
  @override
  String get disabled => 'O guia de voz está desligado nas Definições.';
  @override
  String get locked => 'Desbloqueia primeiro o Conductore.';
  @override
  String get ok => 'OK.';
  @override
  String get cancelled => 'Cancelado.';
  @override
  String get sayYesOrNo => 'Diz sim ou não.';
  @override
  String get didNotCatch =>
      'Desculpa, não percebi. Diz ajuda para ouvir os comandos.';
  @override
  String get noBrain =>
      'Agora só conheço os comandos simples: nenhuma máquina pode responder '
      'ao resto. Diz ajuda.';
  @override
  String brainFailed(String reason) => switch (reason) {
    'outdated' => 'A máquina cérebro precisa de atualizar o companion.',
    'claude-missing' => 'O Claude Code não está instalado na máquina cérebro.',
    'not-logged-in' => 'O Claude não tem sessão iniciada na máquina cérebro.',
    'timeout' => 'A máquina cérebro demorou demasiado.',
    'busy' => 'A máquina cérebro está ocupada. Tenta outra vez.',
    'unreachable' => 'Não consigo chegar à máquina cérebro.',
    _ => 'Desculpa, não resultou.',
  };
  @override
  String get micBusy => 'O microfone está ocupado. Guia desligado.';
  @override
  String get help =>
      'Diz: o que está à espera, abre e um nome, aprova, nega, diz a um agente '
      'para fazer algo, lê a última resposta, vai para o chat, vai para o '
      'terminal, início, qual é o meu uso, ou pára.';
  @override
  String get nothingMore => 'É tudo.';
  @override
  String get noAgentOnScreen =>
      'Não há nenhum agente no ecrã. Diz abre e um nome.';
  @override
  String get notAvailableTrust =>
      'Confiar num agente ainda não está disponível.';
  @override
  String get notAvailableApproveAll =>
      'Aprovar tudo o que é seguro ainda não está disponível.';
  @override
  String get notAvailableAccounts =>
      'Mudar de conta ainda não está disponível.';
  @override
  String get noSafeRequests => 'Não há pedidos de baixo risco à espera.';
  @override
  String get noRequests => 'Não há aprovações à espera.';
  @override
  String get requestGone => 'Esse pedido já foi respondido ou expirou.';
  @override
  String get sent => 'Enviado.';
  @override
  String get approved => 'Aprovado.';
  @override
  String get denied => 'Negado.';
  @override
  String approvedCount(int count) =>
      count == 1 ? 'Aprovei um.' : 'Aprovei $count.';
  @override
  String trusted(String agent, int minutes) =>
      'A confiar em $agent durante ${_duration(minutes)}.';
  @override
  String get home => 'Início.';
  @override
  String get noUsage => 'Ainda não há números de uso.';
  @override
  String get pickOnScreen => 'Escolhe uma sessão no ecrã.';

  @override
  String notFound(String? name) =>
      name == null ? 'Já não existe.' : 'Não encontro $name.';
  @override
  String ended(String agent) => '$agent terminou.';
  @override
  String ambiguous(List<GuideAgent> agents) {
    final names = agents
        .take(3)
        .map((a) => '${a.label} em ${a.machineName}')
        .join(', ');
    return 'Qual deles: $names?';
  }

  @override
  String severalRequests(int count) =>
      'Há $count aprovações à espera. Diz aprova e o nome do agente.';
  @override
  String opening(String what) => 'A abrir $what.';
  @override
  String openingChat(String agent) => 'Chat com $agent.';
  @override
  String openingTerminal(String agent) => 'Terminal de $agent.';
  @override
  String noChat(String agent) =>
      '$agent não abre em chat aqui. Mostro o terminal.';
  @override
  String noReply(String agent) => '$agent ainda não respondeu.';
  @override
  String replyFrom(String agent, String text) => '$agent diz: $text';
  @override
  String confirmApprove(GuidePending pending) =>
      'Aprovar ${GuideStrings.requestLabel(pending.request)} para '
      '${pending.agent.label} em ${pending.agent.machineName}? Diz sim.';
  @override
  String confirmDeny(GuidePending pending) =>
      'Negar ${GuideStrings.requestLabel(pending.request)} para '
      '${pending.agent.label}? Diz sim.';
  @override
  String confirmApproveAll(int count) => count == 1
      ? 'Aprovar um pedido de baixo risco? Diz sim.'
      : 'Aprovar $count pedidos de baixo risco? Diz sim.';
  @override
  String confirmTrust(GuidePending pending, int minutes) =>
      'Confiar em ${pending.agent.label} para '
      '${GuideStrings.requestLabel(pending.request)} e semelhantes durante '
      '${_duration(minutes)}? Diz sim.';
  @override
  String nothingToTrust(String agent) =>
      '$agent não tem nenhum pedido à espera para confiar.';
  @override
  String get trustHighRisk =>
      'Esse pedido é de alto risco, não dá para confiar. Diz aprova para '
      'responder só a este.';
  @override
  String confirmSend(String agent, String text) =>
      'Enviar para $agent: ${GuideStrings.asQuestion(text)} Diz sim.';
  @override
  String failed(String what) => 'Não resultou: $what';

  static String _duration(int minutes) {
    if (minutes % 60 == 0) {
      final hours = minutes ~/ 60;
      return hours == 1 ? 'uma hora' : '$hours horas';
    }
    return minutes == 1 ? 'um minuto' : '$minutes minutos';
  }

  @override
  String waiting(GuideWorld world) {
    final pending = world.pending;
    final input = [
      for (final agent in world.live)
        if (agent.pending.isEmpty && agent.info.state.needsAttention) agent,
    ];
    final idle = [
      for (final agent in world.live)
        if (agent.pending.isEmpty &&
            agent.info.state == AgentAttentionState.idle)
          agent,
    ];
    final working = world.live
        .where((a) => a.info.state == AgentAttentionState.working)
        .length;
    final parts = <String>[];
    if (pending.isNotEmpty) {
      final shown = pending
          .take(3)
          .map(
            (p) =>
                '${agentName(p.agent, world)} quer '
                '${GuideStrings.requestLabel(p.request)}',
          )
          .join('; ');
      parts.add(
        pending.length == 1
            ? 'Uma aprovação: $shown.'
            : '${pending.length} aprovações: $shown.',
      );
    }
    if (input.isNotEmpty) {
      final names = input.take(3).map((a) => agentName(a, world)).join(', ');
      parts.add(
        input.length == 1
            ? '$names precisa de ti.'
            : '${input.length} precisam de ti: $names.',
      );
    }
    if (idle.isNotEmpty) {
      final names = idle.take(3).map((a) => agentName(a, world)).join(', ');
      parts.add(
        idle.length == 1
            ? '$names está parado.'
            : '${idle.length} parados: $names.',
      );
    }
    if (parts.isEmpty) {
      if (world.live.isEmpty) return 'Não há agentes a correr.';
      return working == 1
          ? 'Nada à espera. Um agente está a trabalhar.'
          : 'Nada à espera. $working agentes estão a trabalhar.';
    }
    return parts.join(' ');
  }
}

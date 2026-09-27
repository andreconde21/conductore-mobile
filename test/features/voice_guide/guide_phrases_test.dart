import 'package:conduit/features/voice_guide/domain/guide_intent.dart';
import 'package:conduit/features/voice_guide/domain/guide_phrases.dart';
import 'package:flutter_test/flutter_test.dart';

String? nameOf(GuideRef? ref) => ref is GuideByName ? ref.name : null;

void main() {
  group('GuidePhrases.match, English', () {
    test('what is waiting', () {
      for (final phrase in [
        "What's waiting?",
        'what is waiting for me',
        'What needs me',
        'Hey Conductore, what needs my attention?',
        'anything waiting',
        'status',
      ]) {
        expect(
          GuidePhrases.match(phrase),
          isA<GuideWhatsWaiting>(),
          reason: phrase,
        );
      }
    });

    test('open a workspace, agent or machine', () {
      final open = GuidePhrases.match('Open Conductore Mobile') as GuideOpen;
      expect(nameOf(open.target), 'conductore mobile');
      expect(
        nameOf((GuidePhrases.match('open the api agent') as GuideOpen).target),
        'api',
      );
      expect(
        nameOf((GuidePhrases.match('take me to VTM') as GuideOpen).target),
        'vtm',
      );
      expect(
        nameOf(
          (GuidePhrases.match('show the web project') as GuideOpen).target,
        ),
        'web',
      );
    });

    test('chat, terminal, home', () {
      expect(GuidePhrases.match('go to chat'), isA<GuideShowChat>());
      expect(
        GuidePhrases.match('switch to the chat view'),
        isA<GuideShowChat>(),
      );
      expect(GuidePhrases.match('Go to terminal.'), isA<GuideShowTerminal>());
      expect(GuidePhrases.match('home'), isA<GuideHome>());
      expect(GuidePhrases.match('go back home please'), isA<GuideHome>());
    });

    test('approve and deny the current request, or a named one', () {
      final approve = GuidePhrases.match('Approve') as GuideDecide;
      expect(approve.allow, isTrue);
      expect(approve.target, isNull);
      expect((GuidePhrases.match('approve it') as GuideDecide).target, isNull);
      final named = GuidePhrases.match('approve for api') as GuideDecide;
      expect(nameOf(named.target), 'api');
      final deny = GuidePhrases.match('deny that') as GuideDecide;
      expect(deny.allow, isFalse);
      expect(deny.target, isNull);
      expect(
        nameOf((GuidePhrases.match('reject web') as GuideDecide).target),
        'web',
      );
    });

    test('approve all safe', () {
      for (final phrase in [
        'approve all safe',
        'Approve all the safe ones',
        'approve everything low risk',
        'approve all',
      ]) {
        expect(
          GuidePhrases.match(phrase),
          isA<GuideApproveAllSafe>(),
          reason: phrase,
        );
      }
    });

    test('read, more, stop', () {
      expect(
        (GuidePhrases.match('read the last reply') as GuideRead).target,
        isNull,
      );
      expect(
        nameOf(
          (GuidePhrases.match('read the last reply from api') as GuideRead)
              .target,
        ),
        'api',
      );
      expect(
        nameOf((GuidePhrases.match('what did web say') as GuideRead).target),
        'web',
      );
      expect(GuidePhrases.match('more'), isA<GuideMore>());
      expect(GuidePhrases.match('Stop.'), isA<GuideStop>());
      expect(GuidePhrases.match("that's all"), isA<GuideStop>());
    });

    test('tell an agent to do something', () {
      final send =
          GuidePhrases.match('Tell the API agent to run the tests')
              as GuideSend;
      expect(nameOf(send.target), 'api');
      expect(send.text, 'Run the tests');
      final ask =
          GuidePhrases.match('ask VTM to commit and push, please') as GuideSend;
      expect(nameOf(ask.target), 'vtm');
      expect(ask.text, 'Commit and push');
    });

    test('trust for N minutes', () {
      final trust =
          GuidePhrases.match('trust this for 15 minutes') as GuideTrust;
      expect(trust.minutes, 15);
      expect(trust.target, isNull);
      expect(
        (GuidePhrases.match('trust api for an hour') as GuideTrust).minutes,
        60,
      );
      expect(
        nameOf(
          (GuidePhrases.match('trust api for an hour') as GuideTrust).target,
        ),
        'api',
      );
      expect(
        (GuidePhrases.match('trust it for half an hour') as GuideTrust).minutes,
        30,
      );
      expect(
        (GuidePhrases.match('trust for ten minutes') as GuideTrust).minutes,
        10,
      );
    });

    test('usage, account, help', () {
      expect(GuidePhrases.match("what's my usage"), isA<GuideUsage>());
      expect(
        GuidePhrases.match('how much quota do I have left'),
        isA<GuideUsage>(),
      );
      final account =
          GuidePhrases.match('switch to the work account')
              as GuideSwitchAccount;
      expect(account.account, 'work');
      expect(GuidePhrases.match('help'), isA<GuideHelp>());
    });

    test('catch me up', () {
      for (final phrase in [
        'Catch me up',
        'catch me up please',
        'what did I miss',
        'what happened while I was away',
        'give me a recap',
        'brief me',
        'summarize the agents',
      ]) {
        expect(GuidePhrases.match(phrase), isA<GuideCatchUp>(), reason: phrase);
      }
      for (final phrase in [
        'põe-me a par',
        'poe me a par',
        'o que é que perdi',
        'faz-me um resumo',
        'dá-me um ponto de situação',
      ]) {
        expect(GuidePhrases.match(phrase), isA<GuideCatchUp>(), reason: phrase);
      }
      // A sentence that merely contains the words is not the command.
      expect(GuidePhrases.match('the recap job failed'), isNull);
    });

    test('anything else goes to the brain', () {
      for (final phrase in [
        'ask web how far it is',
        'the tests that open a socket failed',
        'why is the build red',
      ]) {
        expect(GuidePhrases.match(phrase), isNull, reason: phrase);
      }
      expect(GuidePhrases.match(''), isNull);
      expect(GuidePhrases.match('  ...  '), isNull);
    });
  });

  group('GuidePhrases.match, Portuguese', () {
    test('o que está à espera', () {
      for (final phrase in [
        'O que está à espera?',
        'o que é que está à espera',
        'o que precisa de mim',
        'Há algo à espera?',
      ]) {
        expect(
          GuidePhrases.match(phrase),
          isA<GuideWhatsWaiting>(),
          reason: phrase,
        );
      }
    });

    test('abre, chat, terminal, início', () {
      expect(
        nameOf(
          (GuidePhrases.match('Abre o Conductore Mobile') as GuideOpen).target,
        ),
        'conductore mobile',
      );
      expect(
        nameOf((GuidePhrases.match('abre a máquina VTM') as GuideOpen).target),
        'vtm',
      );
      expect(GuidePhrases.match('vai para o chat'), isA<GuideShowChat>());
      expect(
        GuidePhrases.match('vai para o terminal'),
        isA<GuideShowTerminal>(),
      );
      expect(GuidePhrases.match('início'), isA<GuideHome>());
      expect(GuidePhrases.match('volta para o início'), isA<GuideHome>());
    });

    test('aprova, nega, aprova tudo o que é seguro', () {
      expect((GuidePhrases.match('aprova') as GuideDecide).allow, isTrue);
      expect((GuidePhrases.match('Aprova isso') as GuideDecide).target, isNull);
      final deny = GuidePhrases.match('nega o pedido do web') as GuideDecide;
      expect(deny.allow, isFalse);
      expect(nameOf(deny.target), 'web');
      expect(
        GuidePhrases.match('aprova tudo o que é seguro'),
        isA<GuideApproveAllSafe>(),
      );
    });

    test('diz ao agente para…', () {
      final send =
          GuidePhrases.match('diz ao api para correr os testes') as GuideSend;
      expect(nameOf(send.target), 'api');
      expect(send.text, 'Correr os testes');
      final ask =
          GuidePhrases.match('pede ao web que faça commit') as GuideSend;
      expect(nameOf(ask.target), 'web');
      expect(ask.text, 'Faça commit');
    });

    test('lê, mais, pára, uso, confia, conta', () {
      expect(GuidePhrases.match('lê a última resposta'), isA<GuideRead>());
      expect(
        nameOf(
          (GuidePhrases.match('lê a última resposta do api') as GuideRead)
              .target,
        ),
        'api',
      );
      expect(GuidePhrases.match('mais'), isA<GuideMore>());
      expect(GuidePhrases.match('pára'), isA<GuideStop>());
      expect(GuidePhrases.match('obrigado'), isA<GuideStop>());
      expect(GuidePhrases.match('qual é o meu uso'), isA<GuideUsage>());
      expect(
        (GuidePhrases.match('confia nisto durante 10 minutos') as GuideTrust)
            .minutes,
        10,
      );
      expect(
        (GuidePhrases.match('confia no api durante uma hora') as GuideTrust)
            .minutes,
        60,
      );
      expect(
        (GuidePhrases.match('muda para a conta pessoal') as GuideSwitchAccount)
            .account,
        'pessoal',
      );
      expect(GuidePhrases.match('ajuda'), isA<GuideHelp>());
    });
  });

  group('GuidePhrases.yesNo', () {
    test('yes', () {
      for (final phrase in [
        'yes',
        'Yes please',
        'yeah',
        'OK do it',
        'sim',
        'Sim, pode',
        'claro',
      ]) {
        expect(GuidePhrases.yesNo(phrase), isTrue, reason: phrase);
      }
    });

    test('no wins', () {
      for (final phrase in [
        'no',
        "No, don't",
        'yes no wait',
        'cancel',
        'não',
        'Não, cancela',
      ]) {
        expect(GuidePhrases.yesNo(phrase), isFalse, reason: phrase);
      }
    });

    test('unclear', () {
      for (final phrase in ['', 'maybe', 'open api', 'talvez']) {
        expect(GuidePhrases.yesNo(phrase), isNull, reason: phrase);
      }
    });
  });

  group('review and undo', () {
    test('undo, in English and Portuguese, with or without a name', () {
      for (final phrase in [
        'undo that',
        'Undo it',
        'undo the last turn',
        'revert that',
        'roll back the changes',
        'desfaz isso',
        'Desfazer',
        'anula o último turno',
      ]) {
        final intent = GuidePhrases.match(phrase);
        expect(intent, isA<GuideUndo>(), reason: phrase);
        expect((intent! as GuideUndo).target, isNull, reason: phrase);
        expect(intent.risky, isTrue);
      }
      expect(
        nameOf((GuidePhrases.match('undo that for api') as GuideUndo).target),
        'api',
      );
      expect(
        nameOf((GuidePhrases.match('desfaz isso no web') as GuideUndo).target),
        'web',
      );
    });

    test('review, revê, show the changes', () {
      for (final phrase in [
        'review',
        'Review the changes',
        'show me the diff',
        'what changed',
        'revê',
        'rever',
        'revê as alterações',
        'mostra as alterações',
      ]) {
        final intent = GuidePhrases.match(phrase);
        expect(intent, isA<GuideReview>(), reason: phrase);
        expect((intent! as GuideReview).target, isNull, reason: phrase);
      }
      expect(
        nameOf((GuidePhrases.match('review api') as GuideReview).target),
        'api',
      );
      expect(
        nameOf(
          (GuidePhrases.match('review the changes of api') as GuideReview)
              .target,
        ),
        'api',
      );
      expect(
        nameOf((GuidePhrases.match('revê o api') as GuideReview).target),
        'api',
      );
    });
  });
}

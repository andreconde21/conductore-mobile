import 'dart:async';

import 'package:conduit/features/voice/domain/voice_commands.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:conduit/features/voice/presentation/dictation_text_inserter.dart';
import 'package:conduit/features/voice/presentation/voice_settings_scope.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// The mic button: starts dictation into [textController], streams partial
/// transcripts into it, and stops on a second tap or at the end of speech.
///
/// Continuous dictation, its silence and length limits come from
/// Settings → Speech (via [VoiceSettingsScope]) unless the controller has
/// its own options. While listening the button pulses with the input
/// level; after a continuous session paused itself it reads "Paused, tap
/// to continue".
///
/// Without a speech recognizer on the device the mic stays visible but
/// muted; a tap explains why and how to get one
/// ([showSpeechUnavailableDialog]). When [enabled] is false it shows
/// disabled with [disabledTooltip] rather than disappearing, so the mic
/// is always where the user expects it.
///
/// Several buttons may share one [DictationController] (composer sheet and
/// inline bar); only the button that started the session animates and can
/// stop it. Unmounting a button mid-session cancels its own session so the
/// recognizer never talks to a field that is gone.
///
/// When the field is emptied by someone else mid-session (the composer
/// sent or cleared it), the session is discarded, so a late result cannot
/// bring the sent text back (CON-097).
class DictationButton extends StatefulWidget {
  const DictationButton({
    required this.controller,
    required this.textController,
    this.focusNode,
    this.enabled = true,
    this.disabledTooltip,
    this.autoStart = false,
    this.onMessage,
    this.onVoiceCommand,
    super.key,
  });

  final DictationController controller;
  final TextEditingController textController;
  final FocusNode? focusNode;
  final bool enabled;

  /// Why the mic cannot be used right now, while [enabled] is false.
  final String? disabledTooltip;

  /// Start dictating as soon as the button appears (the terminal's
  /// Dictate button opens the chat line this way).
  final bool autoStart;

  /// Receives error text to show near the field (the button has no room).
  final ValueChanged<String>? onMessage;

  /// A trailing "send" or "cancel" ended the dictation (CON-098); the
  /// field already holds the text without the command words. Null leaves
  /// the words as text.
  final ValueChanged<VoiceCommand>? onVoiceCommand;

  @override
  State<DictationButton> createState() => _DictationButtonState();
}

class _DictationButtonState extends State<DictationButton> {
  late DictationTextInserter _inserter;
  late DictationSink _sink;
  String? _shownMessage;
  bool _lastSessionMine = false;
  String _lastText = '';

  @override
  void initState() {
    super.initState();
    _inserter = DictationTextInserter(widget.textController);
    _sink = _newSink();
    _lastText = widget.textController.text;
    widget.textController.addListener(_handleTextChanged);
    widget.controller.addListener(_handleControllerChanged);
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _autoStart());
    }
  }

  DictationSink _newSink() => DictationSink(
    target: widget.textController,
    onBegin: () => _inserter.begin(),
    onPartial: (text) => _inserter.partial(text),
    onFinish: (text) {
      _inserter.finish(text);
      widget.focusNode?.requestFocus();
    },
    onCancel: () {
      _inserter.cancel();
      widget.focusNode?.requestFocus();
    },
    onDiscard: () => _inserter.abandon(),
    onCommand: widget.onVoiceCommand == null
        ? null
        : (command, message) {
            _inserter.finish(message);
            widget.onVoiceCommand?.call(command);
          },
  );

  /// The field went empty without the transcript doing it: whatever the
  /// session still hears belongs to a message that is gone.
  void _handleTextChanged() {
    final text = widget.textController.text;
    final emptied = _lastText.isNotEmpty && text.isEmpty;
    _lastText = text;
    if (emptied && _mine && _inserter.isActive && !_inserter.isWriting) {
      _inserter.abandon();
      unawaited(widget.controller.discard(target: widget.textController));
    }
  }

  Future<void> _autoStart() async {
    final controller = widget.controller;
    await controller.checkAvailability();
    if (!mounted || !widget.enabled) return;
    if (!controller.isAvailable) {
      await showSpeechUnavailableDialog(context, controller);
      return;
    }
    if (controller.status == DictationStatus.idle) {
      await controller.toggle(_sink, options: _options());
    }
  }

  /// A tap on the muted mic: re-check (a recognizer may have been
  /// installed since), then dictate or explain.
  Future<void> _tapUnavailable() async {
    final controller = widget.controller;
    await controller.checkAvailability();
    if (!mounted) return;
    if (controller.isAvailable) {
      await controller.toggle(_sink, options: _options());
      return;
    }
    await showSpeechUnavailableDialog(context, controller);
  }

  @override
  void didUpdateWidget(DictationButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    final fieldChanged = oldWidget.textController != widget.textController;
    if (fieldChanged) {
      oldWidget.textController.removeListener(_handleTextChanged);
      widget.textController.addListener(_handleTextChanged);
      _lastText = widget.textController.text;
      _inserter = DictationTextInserter(widget.textController);
    }
    if ((fieldChanged ||
            (oldWidget.onVoiceCommand == null) !=
                (widget.onVoiceCommand == null)) &&
        !_mine) {
      _sink = _newSink();
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
    }
  }

  @override
  void dispose() {
    widget.textController.removeListener(_handleTextChanged);
    widget.controller.removeListener(_handleControllerChanged);
    if (widget.controller.owns(_sink)) {
      unawaited(widget.controller.cancel());
    }
    super.dispose();
  }

  void _handleControllerChanged() {
    if (widget.controller.isActive) {
      _lastSessionMine = widget.controller.owns(_sink);
    }
    final message = widget.controller.message;
    if (message != null &&
        message != _shownMessage &&
        widget.controller.status == DictationStatus.idle) {
      _shownMessage = message;
      widget.onMessage?.call(message);
    }
    if (message == null) {
      _shownMessage = null;
    }
  }

  bool get _mine => widget.controller.owns(_sink);

  DictationOptions? _options() {
    if (widget.controller.options != null) {
      return null; // The controller's own options win.
    }
    final settings = VoiceSettingsScope.maybeOf(context);
    return settings == null
        ? null
        : DictationOptions.fromPreferences(settings.voice);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        if (!controller.isAvailable) {
          return IconButton(
            key: const ValueKey('dictation-button'),
            tooltip: widget.enabled
                ? 'Voice input unavailable'
                : widget.disabledTooltip ?? 'Voice input unavailable',
            icon: Icon(
              Icons.mic_off_rounded,
              color: Theme.of(context).disabledColor,
            ),
            onPressed: widget.enabled
                ? () => unawaited(_tapUnavailable())
                : null,
          );
        }
        final status = controller.status;
        final active = status != DictationStatus.idle;
        final busy =
            status == DictationStatus.starting ||
            status == DictationStatus.finishing ||
            status == DictationStatus.requestingPermission;
        final colorScheme = Theme.of(context).colorScheme;
        final String tooltip;
        final IconData icon;
        if (active && _mine) {
          tooltip = status == DictationStatus.listening
              ? 'Stop dictating'
              : 'Finishing…';
          icon = status == DictationStatus.listening
              ? Icons.stop_circle_rounded
              : Icons.mic_rounded;
        } else if (controller.pause != null && _lastSessionMine) {
          tooltip = 'Paused, tap to continue';
          icon = Icons.mic_rounded;
        } else if (controller.permissionDenied) {
          tooltip = 'Microphone access denied';
          icon = Icons.mic_off_rounded;
        } else {
          tooltip = widget.enabled
              ? 'Dictate'
              : widget.disabledTooltip ?? 'Dictate';
          icon = Icons.mic_none_rounded;
        }
        final Widget child = busy && _mine
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colorScheme.primary,
                ),
              )
            : Icon(
                icon,
                color: active && _mine
                    ? colorScheme.error
                    : controller.pause != null && _lastSessionMine
                    ? colorScheme.primary
                    : null,
              );
        final listening = status == DictationStatus.listening && _mine;
        final canTap =
            widget.enabled &&
            (!active || _mine) &&
            status != DictationStatus.requestingPermission;
        return IconButton(
          key: const ValueKey('dictation-button'),
          tooltip: tooltip,
          icon: listening
              ? _Pulse(level: controller.level, child: child)
              : child,
          onPressed: canTap
              ? () => unawaited(controller.toggle(_sink, options: _options()))
              : null,
        );
      },
    );
  }
}

/// Explains that the device has no speech recognizer and, on Android,
/// offers the voice input settings where one is chosen. Shared by the mic
/// and Chat View's Talk button.
Future<void> showSpeechUnavailableDialog(
  BuildContext context,
  DictationController controller,
) {
  final android = defaultTargetPlatform == TargetPlatform.android;
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('speech-unavailable-dialog'),
      icon: const Icon(Icons.mic_off_rounded),
      title: const Text('No speech recognizer'),
      content: Text(
        android
            ? 'This device has no speech recognition service, so the mic '
                  'cannot dictate yet.\n\n'
                  'Install or enable Google speech services (the Google '
                  'app, or "Speech Recognition and Synthesis from Google"), '
                  'or pick a voice input app in Android settings. Then tap '
                  'the mic again.'
            : 'Speech recognition is not available on this device, so the '
                  'mic cannot dictate yet.\n\n'
                  'Turn on Dictation in Settings › General › Keyboard, and '
                  'check that your dictation language is supported. Then tap '
                  'the mic again.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
        if (android)
          FilledButton(
            key: const ValueKey('speech-open-settings'),
            onPressed: () {
              Navigator.of(dialogContext).pop();
              unawaited(controller.openSpeechSettings());
            },
            child: const Text('Open settings'),
          ),
      ],
    ),
  );
}

/// A soft halo behind the stop icon that grows with the input level, so
/// the mic visibly "hears" the user. Each change animates briefly and
/// settles (no endless animation).
class _Pulse extends StatelessWidget {
  const _Pulse({required this.level, required this.child});

  final double level;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.error;
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        AnimatedContainer(
          key: const ValueKey('dictation-pulse'),
          duration: const Duration(milliseconds: 120),
          width: 24 + 16 * level,
          height: 24 + 16 * level,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: 0.12 + 0.18 * level),
          ),
        ),
        child,
      ],
    );
  }
}

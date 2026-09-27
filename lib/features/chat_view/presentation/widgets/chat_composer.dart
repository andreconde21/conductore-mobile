import 'dart:async';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/voice/presentation/dictation_button.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:flutter/material.dart';

/// The chat view's input row: a field where Enter sends, voice dictation,
/// the full composer for multiline prompts, and Esc to interrupt.
class ChatComposer extends StatefulWidget {
  const ChatComposer({
    required this.onSend,
    required this.onInterrupt,
    this.enabled = true,
    this.disabledHint,
    this.sending = false,
    this.showInterrupt = false,
    this.onExpand,
    this.dictation,
    this.onTalk,
    this.onGuide,
    this.textController,
    this.focusNode,
    this.initialText = '',
    this.onPasteImage,
    this.clipboardHasImage,
    super.key,
  });

  /// Sends one prompt; throws to keep the text in the field.
  final Future<void> Function(String text) onSend;
  final Future<void> Function() onInterrupt;
  final bool enabled;

  /// Shown as the hint while [enabled] is false.
  final String? disabledHint;
  final bool sending;

  /// Emphasizes the Esc button (the agent is working).
  final bool showInterrupt;

  /// Opens the full-screen composer seeded with the field's text; it gets
  /// the current text and a setter for the draft.
  final void Function(String text, ValueChanged<String> setDraft)? onExpand;
  final DictationController? dictation;

  /// Starts the hands-free Talk loop; null hides the button.
  final VoidCallback? onTalk;

  /// A long press on Talk starts the voice guide instead.
  final VoidCallback? onGuide;

  /// The field's text, when the page needs it (Talk puts unsent speech
  /// back here); otherwise the composer owns one.
  final TextEditingController? textController;

  /// The field's focus, when the page moves it there ("Quote in reply").
  final FocusNode? focusNode;

  /// Text the field starts with (e.g. an uploaded screenshot's path).
  final String initialText;

  /// Uploads the clipboard's image and inserts its path; offered as
  /// "Paste image" in the field's menu while [clipboardHasImage] says so.
  /// Null: text paste only.
  final VoidCallback? onPasteImage;

  /// Whether the clipboard holds an image; asked when the field gains
  /// focus and when the app comes back to the front.
  final Future<bool> Function()? clipboardHasImage;

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  late final TextEditingController _controller =
      widget.textController ?? TextEditingController(text: widget.initialText);
  late final _focusNode = widget.focusNode ?? FocusNode();
  AppLifecycleListener? _lifecycle;
  bool _clipboardHasImage = false;

  @override
  void initState() {
    super.initState();
    if (widget.onPasteImage != null) {
      _focusNode.addListener(_onFocusChanged);
      _lifecycle = AppLifecycleListener(onResume: _probeClipboard);
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    if (widget.textController == null) _controller.dispose();
    if (widget.focusNode == null) {
      _focusNode.dispose();
    } else {
      _focusNode.removeListener(_onFocusChanged);
    }
    super.dispose();
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus) _probeClipboard();
  }

  Future<void> _probeClipboard() async {
    final probe = widget.clipboardHasImage;
    if (probe == null) return;
    final hasImage = await probe();
    if (mounted && hasImage != _clipboardHasImage) {
      setState(() => _clipboardHasImage = hasImage);
    }
  }

  Widget _contextMenu(BuildContext context, EditableTextState state) {
    final paste = widget.onPasteImage;
    if (paste == null || !_clipboardHasImage) {
      return AdaptiveTextSelectionToolbar.editableText(
        editableTextState: state,
      );
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: [
        ...state.contextMenuButtonItems,
        ContextMenuButtonItem(
          label: 'Paste image',
          onPressed: () {
            state.hideToolbar();
            paste();
          },
        ),
      ],
    );
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || !widget.enabled || widget.sending) {
      return;
    }
    _controller.clear();
    try {
      await widget.onSend(text);
    } catch (error) {
      if (!mounted) return;
      // Keep the prompt so nothing typed is lost.
      if (_controller.text.isEmpty) {
        _controller.text = text;
      }
      _showError(error);
    }
  }

  Future<void> _interrupt() async {
    try {
      await widget.onInterrupt();
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  void _showError(Object error) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(error is AppFailure ? error.userMessage : '$error'),
        ),
      );
  }

  /// Why Talk and the mic are disabled: the composer's own reason.
  String get _disabledVoiceTooltip =>
      widget.disabledHint ?? 'Voice input works once you can send';

  /// Talk (the hands-free loop). Without a speech recognizer it explains
  /// why instead of starting a loop that cannot hear.
  Widget _talkButton() {
    final dictation = widget.dictation;
    Widget button() {
      final unavailable = dictation != null && !dictation.isAvailable;
      return IconButton(
        key: const ValueKey('chat-talk'),
        tooltip: widget.enabled ? 'Talk' : _disabledVoiceTooltip,
        icon: Icon(
          Icons.record_voice_over_outlined,
          color: unavailable ? Theme.of(context).disabledColor : null,
        ),
        onPressed: !widget.enabled
            ? null
            : unavailable
            ? () => unawaited(showSpeechUnavailableDialog(context, dictation))
            : widget.onTalk,
        onLongPress: unavailable ? null : widget.onGuide,
      );
    }

    return dictation == null
        ? button()
        : ListenableBuilder(
            listenable: dictation,
            builder: (context, _) => button(),
          );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Interrupt (Esc)',
              onPressed: _interrupt,
              icon: Icon(
                Icons.stop_circle_outlined,
                color: widget.showInterrupt ? theme.colorScheme.error : null,
              ),
            ),
            Expanded(
              child: TextField(
                key: const ValueKey('chat-composer-field'),
                controller: _controller,
                focusNode: _focusNode,
                enabled: widget.enabled,
                minLines: 1,
                maxLines: 4,
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                contextMenuBuilder: _contextMenu,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: widget.enabled
                      ? 'Message Claude…'
                      : widget.disabledHint,
                  border: const OutlineInputBorder(
                    borderRadius: BorderRadius.all(
                      Radius.circular(AppTheme.radius),
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                ),
              ),
            ),
            // Talk and the mic stay visible (disabled) while the chat
            // cannot send, so voice is always where the user expects it.
            if (widget.onTalk != null) _talkButton(),
            if (widget.dictation != null)
              DictationButton(
                controller: widget.dictation!,
                textController: _controller,
                focusNode: _focusNode,
                enabled: widget.enabled,
                disabledTooltip: _disabledVoiceTooltip,
                onMessage: (message) => ScaffoldMessenger.maybeOf(context)
                  ?..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(content: Text(message))),
              ),
            if (widget.onExpand != null && widget.enabled)
              IconButton(
                tooltip: 'Open composer',
                icon: const Icon(Icons.open_in_full_rounded),
                onPressed: () => widget.onExpand!(
                  _controller.text,
                  (draft) => _controller.text = draft,
                ),
              ),
            widget.sending
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    tooltip: 'Send',
                    onPressed: widget.enabled ? _send : null,
                    icon: const Icon(Icons.send_rounded),
                  ),
          ],
        ),
      ),
    );
  }
}

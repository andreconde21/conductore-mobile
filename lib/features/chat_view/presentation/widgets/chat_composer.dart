import 'dart:async';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:conduit/features/terminal/data/keyboard_image_file.dart';
import 'package:conduit/features/terminal/domain/prompt_image.dart';
import 'package:conduit/features/voice/domain/voice_commands.dart';
import 'package:conduit/features/voice/presentation/dictation_button.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:flutter/material.dart';

/// The chat view's input row, at most four controls (CON-107): Stop
/// while the agent works, a field that grows with its text (Enter sends),
/// the mic (tap dictates, long-press starts Talk) and Send. Images come in
/// through the attach icon in the field, "Paste image" in its menu, and a
/// keyboard's image insertion (its clipboard panel, GIFs). Once the
/// message runs past one line a small × clears it, with Undo.
class ChatComposer extends StatefulWidget {
  const ChatComposer({
    required this.onSend,
    required this.onInterrupt,
    this.enabled = true,
    this.disabledHint,
    this.agentName,
    this.sending = false,
    this.showInterrupt = false,
    this.dictation,
    this.onTalk,
    this.textController,
    this.focusNode,
    this.initialText = '',
    this.onPasteImage,
    this.clipboardHasImage,
    this.onAttachImage,
    this.attachingImage = false,
    this.onInsertContent,
    super.key,
  });

  /// Sends one prompt; throws to keep the text in the field.
  final Future<void> Function(String text) onSend;
  final Future<void> Function() onInterrupt;
  final bool enabled;

  /// Shown as the hint while [enabled] is false.
  final String? disabledHint;

  /// The agent's name for people ("Claude Code", "Codex"); null when its
  /// kind is not known.
  final String? agentName;
  final bool sending;

  /// Shows Stop (Esc): only while the agent is working.
  final bool showInterrupt;
  final DictationController? dictation;

  /// Starts the hands-free Talk loop, on a long press of the mic; null
  /// leaves the long press off.
  final VoidCallback? onTalk;

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
  /// focus, when the app comes back to the front, and again each time the
  /// field's menu opens (the earlier answers can be stale: Android only
  /// lets the focused app read the clipboard, and the image may have been
  /// copied since).
  final Future<bool> Function()? clipboardHasImage;

  /// The attach icon's choices (clipboard, photo picker, camera); null
  /// hides it.
  final ValueChanged<PromptImageOrigin>? onAttachImage;

  /// An image is being uploaded: the attach icon shows progress.
  final bool attachingImage;

  /// An image the keyboard inserted (its clipboard panel, a GIF); null
  /// leaves the keyboard's image insertion off.
  final ValueChanged<KeyboardInsertedContent>? onInsertContent;

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
    final probe = widget.clipboardHasImage;
    if (paste == null) {
      return AdaptiveTextSelectionToolbar.editableText(
        editableTextState: state,
      );
    }
    return _PasteImageMenu(
      editableTextState: state,
      initiallyHasImage: _clipboardHasImage,
      probe: probe,
      onHasImage: (hasImage) => _clipboardHasImage = hasImage,
      onPasteImage: paste,
    );
  }

  Widget _attachButton(ThemeData theme) {
    final attach = widget.onAttachImage!;
    if (widget.attachingImage) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return PopupMenuButton<PromptImageOrigin>(
      key: const ValueKey('chat-attach-image'),
      tooltip: 'Attach image',
      enabled: widget.enabled,
      icon: const Icon(Icons.add_photo_alternate_outlined),
      onSelected: attach,
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: PromptImageOrigin.clipboard,
          child: ListTile(
            leading: Icon(Icons.content_paste_rounded),
            title: Text('Paste image from clipboard'),
          ),
        ),
        PopupMenuItem(
          value: PromptImageOrigin.gallery,
          child: ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(
              PlatformFeatures.camera ? 'Pick a photo' : 'Image file',
            ),
          ),
        ),
        if (PlatformFeatures.camera)
          const PopupMenuItem(
            value: PromptImageOrigin.camera,
            child: ListTile(
              leading: Icon(Icons.photo_camera_outlined),
              title: Text('Take a photo'),
            ),
          ),
      ],
    );
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || !widget.enabled || widget.sending) {
      return;
    }
    // A late result of the dictation must not refill the field (CON-097).
    unawaited(widget.dictation?.discard(target: _controller));
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

  /// Empties the field (attached images are paths in it) and stops the
  /// dictation feeding it; a snackbar offers the text back.
  void _clear() {
    final previous = _controller.value;
    if (previous.text.isEmpty) return;
    unawaited(widget.dictation?.discard(target: _controller));
    _controller.clear();
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Message cleared'),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              if (mounted && _controller.text.isEmpty) {
                _controller.value = previous;
              }
            },
          ),
        ),
      );
  }

  void _voiceCommand(VoiceCommand command) {
    switch (command) {
      case VoiceCommand.send:
        unawaited(_send());
      case VoiceCommand.cancel:
        _clear();
    }
  }

  /// The × over the field's corner, once the message runs past a line.
  Widget _clearOverlay(ThemeData theme) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final text = _controller.text;
        if (!widget.enabled || !(text.contains('\n') || text.length > 40)) {
          return const SizedBox.shrink();
        }
        return Material(
          color: theme.colorScheme.surfaceContainerHighest,
          shape: const CircleBorder(),
          child: InkWell(
            key: const ValueKey('chat-composer-clear'),
            customBorder: const CircleBorder(),
            onTap: _clear,
            child: Tooltip(
              message: 'Clear message',
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Icon(
                  Icons.close_rounded,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        );
      },
    );
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

  /// Why the mic is disabled: the composer's own reason.
  String get _disabledVoiceTooltip =>
      widget.disabledHint ?? 'Voice input works once you can send';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
        child: Row(
          children: [
            if (widget.showInterrupt)
              IconButton(
                key: const ValueKey('chat-interrupt'),
                tooltip: 'Interrupt (Esc)',
                onPressed: _interrupt,
                icon: Icon(
                  Icons.stop_circle_outlined,
                  color: theme.colorScheme.error,
                ),
              ),
            Expanded(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  _field(theme),
                  Positioned(top: -4, right: -4, child: _clearOverlay(theme)),
                ],
              ),
            ),
            // The mic stays visible (disabled) while the chat cannot
            // send, so voice is always where the user expects it.
            if (widget.dictation != null)
              DictationButton(
                controller: widget.dictation!,
                textController: _controller,
                focusNode: _focusNode,
                enabled: widget.enabled,
                disabledTooltip: _disabledVoiceTooltip,
                onVoiceCommand: _voiceCommand,
                onLongPress: widget.onTalk,
                onMessage: (message) => ScaffoldMessenger.maybeOf(context)
                  ?..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(content: Text(message))),
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

  Widget _field(ThemeData theme) {
    return TextField(
      key: const ValueKey('chat-composer-field'),
      controller: _controller,
      focusNode: _focusNode,
      enabled: widget.enabled,
      // Grows with the message up to about half a phone screen, then
      // scrolls: no separate full-screen composer.
      minLines: 1,
      maxLines: 10,
      keyboardType: TextInputType.text,
      textInputAction: TextInputAction.send,
      onSubmitted: (_) => _send(),
      contextMenuBuilder: _contextMenu,
      contentInsertionConfiguration: widget.onInsertContent == null
          ? null
          : ContentInsertionConfiguration(
              allowedMimeTypes: keyboardImageMimeTypes,
              onContentInserted: widget.onInsertContent!,
            ),
      decoration: InputDecoration(
        isDense: true,
        hintText: widget.enabled
            ? 'Message ${agentObject(widget.agentName)}…'
            : widget.disabledHint,
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppTheme.radius)),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 10,
        ),
        // Inside the field: images are always one tap away
        // without taking another slot in the row.
        suffixIcon: widget.onAttachImage == null ? null : _attachButton(theme),
        suffixIconConstraints: const BoxConstraints(
          minWidth: 40,
          minHeight: 40,
        ),
      ),
    );
  }
}

/// The field's menu with "Paste image" while the clipboard holds one. It
/// asks the clipboard again as it opens: the answer from when the field
/// gained focus may predate the copy, or have been refused because the app
/// was not focused yet.
class _PasteImageMenu extends StatefulWidget {
  const _PasteImageMenu({
    required this.editableTextState,
    required this.initiallyHasImage,
    required this.probe,
    required this.onHasImage,
    required this.onPasteImage,
  });

  final EditableTextState editableTextState;
  final bool initiallyHasImage;
  final Future<bool> Function()? probe;
  final ValueChanged<bool> onHasImage;
  final VoidCallback onPasteImage;

  @override
  State<_PasteImageMenu> createState() => _PasteImageMenuState();
}

class _PasteImageMenuState extends State<_PasteImageMenu> {
  late bool _hasImage = widget.initiallyHasImage;

  @override
  void initState() {
    super.initState();
    unawaited(_probe());
  }

  Future<void> _probe() async {
    final probe = widget.probe;
    if (probe == null) return;
    final hasImage = await probe();
    widget.onHasImage(hasImage);
    if (mounted && hasImage != _hasImage) {
      setState(() => _hasImage = hasImage);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.editableTextState;
    if (!_hasImage) {
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
            widget.onPasteImage();
          },
        ),
      ],
    );
  }
}

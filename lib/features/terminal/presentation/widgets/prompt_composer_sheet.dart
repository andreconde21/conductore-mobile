import 'dart:async';

import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/features/terminal/domain/clipboard_image_paste.dart';
import 'package:conduit/features/terminal/domain/prompt_image.dart';
import 'package:conduit/features/voice/domain/voice_commands.dart';
import 'package:conduit/features/voice/presentation/dictation_button.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Upper bound on a single composed prompt, in characters. Large pastes are
/// fine over SSH, but remote line editors and TUIs degrade badly past this
/// point; oversized prompts are kept as drafts instead of silently truncated.
const promptComposerMaxChars = 100000;

/// Sends a composed prompt into the terminal. Implementations deliver the
/// text atomically (bracketed paste when the remote app supports it) and,
/// when [submit] is set, follow up with an isolated Enter keypress.
typedef PromptComposerSend =
    Future<void> Function(String text, {required bool submit});

/// Shows the full-screen prompt composer for the active terminal session.
///
/// The composer edits a per-session draft: [onDraftChanged] fires on every
/// edit so the caller always holds the latest text, no matter how the sheet
/// closes. Sending clears the draft; Cancel and dismissal keep it.
///
/// [bracketedPasteSupported] is polled at build time so the sheet can warn
/// when a multiline prompt would be delivered line by line (each newline
/// acting as Enter) because the remote application has not switched
/// bracketed paste on.
Future<void> showPromptComposerSheet({
  required BuildContext context,
  required String initialText,
  required ValueChanged<String> onDraftChanged,
  required PromptComposerSend onSend,
  required bool submitEnter,
  required ValueChanged<bool> onSubmitEnterChanged,
  required bool Function() isConnected,
  bool Function()? bracketedPasteSupported,
  DictationController? dictation,
  PromptImageAttacher? imageAttacher,
  bool pasteImages = true,
}) {
  return showAdaptiveModal<void>(
    kind: AdaptiveModalKind.dialog,
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => PromptComposerSheet(
      initialText: initialText,
      onDraftChanged: onDraftChanged,
      onSend: onSend,
      submitEnter: submitEnter,
      onSubmitEnterChanged: onSubmitEnterChanged,
      isConnected: isConnected,
      bracketedPasteSupported: bracketedPasteSupported,
      dictation: dictation,
      imageAttacher: imageAttacher,
      pasteImages: pasteImages,
    ),
  );
}

class PromptComposerSheet extends StatefulWidget {
  const PromptComposerSheet({
    required this.initialText,
    required this.onDraftChanged,
    required this.onSend,
    required this.submitEnter,
    required this.onSubmitEnterChanged,
    required this.isConnected,
    this.bracketedPasteSupported,
    this.dictation,
    this.imageAttacher,
    this.pasteImages = true,
    super.key,
  });

  final String initialText;
  final ValueChanged<String> onDraftChanged;
  final PromptComposerSend onSend;
  final bool submitEnter;
  final ValueChanged<bool> onSubmitEnterChanged;
  final bool Function() isConnected;
  final bool Function()? bracketedPasteSupported;

  /// Voice input; null hides the mic (no recognizer on this platform).
  final DictationController? dictation;

  /// Attaches images (gallery, camera, clipboard) by uploading them to the
  /// host and inserting the remote path; null hides the image button.
  final PromptImageAttacher? imageAttacher;

  /// Whether Paste uploads a clipboard image (through [imageAttacher]) and
  /// inserts its path before falling back to text.
  final bool pasteImages;

  @override
  State<PromptComposerSheet> createState() => _PromptComposerSheetState();
}

class _PromptComposerSheetState extends State<PromptComposerSheet> {
  late final TextEditingController _controller;
  final _focusNode = FocusNode();
  late bool _submitEnter;
  bool _sending = false;
  bool _attaching = false;
  String? _error;

  /// What Clear removed, offered back for a few seconds.
  TextEditingValue? _cleared;
  Timer? _clearedTimer;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _controller.addListener(_handleTextChanged);
    _submitEnter = widget.submitEnter;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _focusNode.requestFocus(),
    );
  }

  @override
  void dispose() {
    _controller.removeListener(_handleTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    _clearedTimer?.cancel();
    super.dispose();
  }

  void _handleTextChanged() {
    widget.onDraftChanged(_controller.text);
    // Rebuild for the character count, the oversize/empty send guard, and to
    // clear a stale send error once the user edits again. New text also
    // retires a pending Undo of Clear.
    setState(() {
      _error = null;
      if (_controller.text.isNotEmpty) _dropCleared();
    });
  }

  bool get _oversized => _controller.text.length > promptComposerMaxChars;

  bool get _multiline => _controller.text.contains('\n');

  Future<void> _send() async {
    final text = _controller.text;
    if (_sending || text.isEmpty || _oversized) {
      return;
    }
    if (!widget.isConnected()) {
      _showError('Not connected. The prompt was kept as a draft.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    // The dictation feeding this draft ends here: a late result would
    // bring the sent text back (CON-097).
    await widget.dictation?.discard(target: _controller);
    try {
      await widget.onSend(text, submit: _submitEnter);
    } catch (error) {
      if (mounted) {
        setState(() => _sending = false);
        _showError('Sending failed. The prompt was kept as a draft.');
      }
      return;
    }
    widget.onDraftChanged('');
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  // Errors are shown inside the sheet: a SnackBar would be drawn on the
  // Scaffold underneath and hidden behind the modal.
  void _showError(String message) {
    setState(() => _error = message);
  }

  Future<void> _pasteFromClipboard() async {
    final attacher = widget.imageAttacher;
    if (widget.pasteImages && attacher != null) {
      if (_attaching || _sending) return;
      setState(() {
        _attaching = true;
        _error = null;
      });
      try {
        final path = await ClipboardImagePaster.fromAttacher(attacher).paste();
        if (path != null) {
          if (mounted) _insertImagePath(path);
          return;
        }
      } catch (error) {
        if (mounted) _showError('Could not paste the image: $error');
        return;
      } finally {
        if (mounted) setState(() => _attaching = false);
      }
      if (!mounted) return;
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) {
      return;
    }
    final text = data?.text;
    if (text == null || text.isEmpty) {
      return;
    }
    final value = _controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final updated = value.text.replaceRange(start, end, text);
    _controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    _focusNode.requestFocus();
  }

  /// Puts [remotePath] at the cursor as its own word.
  void _insertImagePath(String remotePath) {
    final value = _controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final inserted = insertPromptImagePath(value.text, start, end, remotePath);
    _controller.value = TextEditingValue(
      text: inserted.text,
      selection: TextSelection.collapsed(offset: inserted.cursor),
    );
    _focusNode.requestFocus();
  }

  Future<void> _attachImage(PromptImageOrigin origin) async {
    final attacher = widget.imageAttacher;
    if (attacher == null || _attaching || _sending) {
      return;
    }
    setState(() {
      _attaching = true;
      _error = null;
    });
    try {
      final picked = await attacher.source.pick(origin);
      if (!mounted) {
        return;
      }
      if (picked == null) {
        if (origin == PromptImageOrigin.clipboard) {
          _showError('There is no image on the clipboard.');
        }
        return;
      }
      final crop = await attacher.crop(picked);
      if (!mounted || crop == null) {
        return;
      }
      final prepared = await attacher.prepare(picked, crop);
      final remotePath = await attacher.upload(prepared);
      if (!mounted) {
        return;
      }
      _insertImagePath(remotePath);
    } catch (error) {
      if (mounted) {
        _showError('Could not attach the image: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _attaching = false);
      }
    }
  }

  void _selectAll() {
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
    _focusNode.requestFocus();
  }

  /// Empties the draft (attached images are paths in it), stops the
  /// dictation feeding it, and offers Undo for a few seconds.
  void _clear() {
    final previous = _controller.value;
    if (previous.text.isEmpty) return;
    unawaited(widget.dictation?.discard(target: _controller));
    _controller.clear();
    setState(() {
      _cleared = previous;
      _clearedTimer?.cancel();
      _clearedTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(_dropCleared);
      });
    });
    _focusNode.requestFocus();
  }

  void _undoClear() {
    final previous = _cleared;
    if (previous == null) return;
    setState(_dropCleared);
    _controller.value = previous;
    _focusNode.requestFocus();
  }

  void _dropCleared() {
    _cleared = null;
    _clearedTimer?.cancel();
    _clearedTimer = null;
  }

  void _voiceCommand(VoiceCommand command) {
    switch (command) {
      case VoiceCommand.send:
        if (_controller.text.isNotEmpty) unawaited(_send());
      case VoiceCommand.cancel:
        _clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final length = _controller.text.length;
    final canSend = !_sending && length > 0 && !_oversized;
    final desktop = PlatformFeatures.isDesktop;
    void sendShortcut() {
      if (canSend) unawaited(_send());
    }

    final bracketedPaste = widget.bracketedPasteSupported?.call() ?? true;
    final String? notice;
    if (_oversized) {
      notice =
          'Too large to send safely. Trim or split the prompt; '
          'it stays saved as a draft.';
    } else if (_error != null) {
      notice = _error;
    } else if (_multiline && !bracketedPaste) {
      notice =
          'The remote app has not enabled bracketed paste, so each line '
          'will be sent as if you pressed Enter after it.';
    } else {
      notice = null;
    }
    final noticeColor = _oversized || _error != null
        ? colorScheme.error
        : colorScheme.onSurfaceVariant;
    // The keyboard inset comes first so the sheet rises above the IME; the
    // SafeArea then keeps the button row clear of the Android navigation bar
    // whenever the keyboard is hidden (MediaQuery.padding is already zero
    // while the keyboard covers the bar). The column scrolls so a short
    // landscape viewport cannot overflow.
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  // Five icon buttons fit a 360 dp phone only when the
                  // title may shrink.
                  Expanded(
                    child: Text(
                      'Chat mode',
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.dictation != null)
                    DictationButton(
                      controller: widget.dictation!,
                      textController: _controller,
                      focusNode: _focusNode,
                      enabled: !_sending,
                      onMessage: _showError,
                      onVoiceCommand: _voiceCommand,
                    ),
                  if (widget.imageAttacher != null)
                    _attaching
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : PopupMenuButton<PromptImageOrigin>(
                            tooltip: 'Attach image',
                            icon: const Icon(
                              Icons.add_photo_alternate_outlined,
                            ),
                            enabled: !_sending,
                            onSelected: (origin) =>
                                unawaited(_attachImage(origin)),
                            itemBuilder: (context) => [
                              PopupMenuItem(
                                value: PromptImageOrigin.gallery,
                                child: ListTile(
                                  leading: const Icon(
                                    Icons.photo_library_outlined,
                                  ),
                                  title: Text(
                                    PlatformFeatures.camera
                                        ? 'Gallery'
                                        : 'Image file',
                                  ),
                                ),
                              ),
                              if (PlatformFeatures.camera)
                                const PopupMenuItem(
                                  value: PromptImageOrigin.camera,
                                  child: ListTile(
                                    leading: Icon(Icons.photo_camera_outlined),
                                    title: Text('Camera'),
                                  ),
                                ),
                              if (PlatformFeatures.clipboardImage)
                                const PopupMenuItem(
                                  value: PromptImageOrigin.clipboard,
                                  child: ListTile(
                                    leading: Icon(
                                      Icons.content_paste_go_rounded,
                                    ),
                                    title: Text('Paste image'),
                                  ),
                                ),
                            ],
                          ),
                  // A desktop has these on the keyboard (Ctrl+V, Ctrl+A)
                  // and in the field's right-click menu.
                  if (!desktop) ...[
                    IconButton(
                      tooltip: 'Paste clipboard',
                      icon: const Icon(Icons.content_paste_rounded),
                      onPressed: _sending ? null : _pasteFromClipboard,
                    ),
                    IconButton(
                      tooltip: 'Select all',
                      icon: const Icon(Icons.select_all_rounded),
                      onPressed: _sending || length == 0 ? null : _selectAll,
                    ),
                  ],
                  // Only with text; it also stops dictation and can be
                  // undone, so desktops get it too.
                  if (length > 0)
                    IconButton(
                      key: const ValueKey('composer-clear'),
                      tooltip: 'Clear draft',
                      icon: const Icon(Icons.backspace_outlined),
                      onPressed: _sending ? null : _clear,
                    ),
                ],
              ),
              CallbackShortcuts(
                // Desktop: Ctrl+Enter (Cmd+Enter on macOS) sends; Enter
                // stays a new line.
                bindings: {
                  if (desktop) ...{
                    const SingleActivator(
                      LogicalKeyboardKey.enter,
                      control: true,
                    ): sendShortcut,
                    const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                        sendShortcut,
                  },
                },
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  // readOnly (not enabled: false) keeps focus and the keyboard
                  // through a send, so a failed send leaves the user editing.
                  readOnly: _sending,
                  minLines: 4,
                  maxLines: 8,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  decoration: const InputDecoration(
                    hintText: 'Type, dictate, or paste a prompt…',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_cleared != null && notice == null)
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              'Draft cleared',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: noticeColor,
                              ),
                            ),
                          ),
                          TextButton(
                            key: const ValueKey('composer-undo-clear'),
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: _undoClear,
                            child: const Text('Undo'),
                          ),
                        ],
                      ),
                    )
                  else if (notice != null)
                    Expanded(
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          notice,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: noticeColor,
                          ),
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  const SizedBox(width: 8),
                  Text(
                    '$length / $promptComposerMaxChars',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Press Enter after inserting'),
                subtitle: Text(
                  _submitEnter
                      ? 'The prompt is submitted immediately.'
                      : 'The prompt is left in the terminal for review.',
                  style: theme.textTheme.bodySmall,
                ),
                value: _submitEnter,
                onChanged: _sending
                    ? null
                    : (value) {
                        setState(() => _submitEnter = value);
                        widget.onSubmitEnterChanged(value);
                      },
              ),
              Row(
                children: [
                  TextButton(
                    onPressed: _sending
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const Spacer(),
                  Tooltip(
                    message: desktop
                        ? (defaultTargetPlatform == TargetPlatform.macOS
                              ? 'Cmd+Enter'
                              : 'Ctrl+Enter')
                        : '',
                    child: FilledButton.icon(
                      onPressed: canSend ? _send : null,
                      icon: _sending
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              _submitEnter
                                  ? Icons.send_rounded
                                  : Icons.keyboard_return_rounded,
                            ),
                      label: Text(_submitEnter ? 'Insert & Send' : 'Insert'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

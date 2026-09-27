import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sftp/domain/sftp_repository.dart';
import 'package:conduit/features/share_target/data/sftp_share_uploader.dart';
import 'package:conduit/features/terminal/data/platform_prompt_image_source.dart';
import 'package:conduit/features/terminal/data/prompt_image_preparer.dart';
import 'package:conduit/features/terminal/domain/prompt_image.dart';
import 'package:conduit/features/terminal/presentation/widgets/image_crop_page.dart';
import 'package:flutter/widgets.dart';

/// Prompt images for a [host]: picked or pasted, cropped over [context]'s
/// navigator, and uploaded to the host's share inbox, whose path the
/// composer inserts for the agent to read.
PromptImageAttacher sftpPromptImageAttacher({
  required SftpRepository repository,
  required SavedHost host,
  required BuildContext Function() context,
  PromptImageSource? source,
  PromptImagePreparer? preparer,
}) {
  final prepare = (preparer ?? PromptImagePreparer()).prepare;
  return PromptImageAttacher(
    source: source ?? PlatformPromptImageSource(),
    crop: (image) => showImageCropPage(context(), image),
    prepare: prepare,
    upload: (image) async {
      final paths = await SftpShareUploader(repository).upload(host, [image]);
      return paths.single;
    },
  );
}

/// Gives every Chat View prompt images, however it was opened: from the
/// terminal, but also from home's agents panel, the quick switcher, the
/// voice guide or a forwarded message, whose openers have no attacher of
/// their own. Sits above the Navigator.
class PromptImageScope extends InheritedWidget {
  const PromptImageScope({
    required this.attacherFor,
    required this.pasteImages,
    required super.child,
    super.key,
  });

  /// The attacher for [host]; [context] is where the crop page opens.
  final PromptImageAttacher Function(
    SavedHost host,
    BuildContext Function() context,
  )
  attacherFor;

  /// The "Paste images as uploaded files" setting.
  final bool Function() pasteImages;

  static PromptImageScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<PromptImageScope>();

  @override
  bool updateShouldNotify(PromptImageScope oldWidget) => false;
}

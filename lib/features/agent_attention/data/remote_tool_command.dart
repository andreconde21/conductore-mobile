import 'dart:convert';

/// Directories agent tooling installers use that a non-interactive SSH
/// shell does not put on PATH (`~/.bashrc`-only activation for mise,
/// Homebrew, Cargo, Nix, npm's global prefix, and the `~/.local/bin`
/// default of most `install.sh` scripts).
const remoteToolExtraPathDirs = [
  r'$HOME/.local/bin',
  r'$HOME/.local/share/mise/shims',
  r'$HOME/.cargo/bin',
  r'$HOME/.nix-profile/bin',
  r'$HOME/.npm-global/bin',
  '/opt/homebrew/bin',
  '/home/linuxbrew/.linuxbrew/bin',
  '/usr/local/bin',
];

/// Wraps `tool args` so it runs under POSIX `sh` with the usual user-local
/// install directories prepended to PATH. SSH exec channels get a
/// non-login, non-interactive shell whose PATH rarely includes them, which
/// would otherwise read as "not installed"; going through `sh -c` also
/// keeps the `PATH=... cmd` syntax working when the login shell is fish or
/// csh. The script is quoted with [shellQuoteArgument], which the login
/// shell reads the same way whether it is sh, bash, zsh or fish.
String remoteToolCommand(String tool, String args) {
  final inner =
      'PATH="${remoteToolExtraPathDirs.join(':')}:\$PATH" exec $tool $args';
  return 'sh -c ${shellQuoteArgument(inner)}';
}

/// Quotes one argument unless it is plainly safe, so that sh, bash, zsh
/// and fish all read back exactly [value].
///
/// Plain POSIX quoting (`'...'` with `'\''` for quotes) is not enough:
/// fish treats `\'` and `\\` as escapes even inside single quotes, so a
/// value such as `x\';evil;#` would end the quote early there. Quotes, and
/// the backslashes fish would pair up, are therefore escaped outside the
/// single-quoted runs (`'\''`, `'\\'`), which every one of those shells,
/// and tmux's command parser, read as the literal character. Other values
/// (a `printf '\t'` format included) get the usual POSIX quoting.
String shellQuoteArgument(String value) {
  if (RegExp(r'^[A-Za-z0-9._:\-]+$').hasMatch(value)) {
    return value;
  }
  final escaped = value.replaceAllMapped(
    _quoteOrBackslash,
    (match) => "'\\${match[0]}'",
  );
  return "'$escaped'";
}

/// A quote, or a backslash fish would read as an escape inside single
/// quotes: one before another backslash, a quote or the closing quote.
final _quoteOrBackslash = RegExp(r"'|\\(?=[\\']|$)");

/// The SSH exec command that runs [script] under POSIX `sh`, whatever the
/// account's login shell is.
///
/// sshd hands an exec command to the login shell (`$SHELL -c`), so a
/// script meant for sh would otherwise be parsed by fish, csh or nushell
/// first. Here the login shell only ever sees a fixed
/// `sh -c 'eval "$(printf "...")"'` with no quote or backslash-escape it
/// could read differently: every byte of [script] outside a small safe
/// set travels as a `\ooo` octal escape that only sh's `printf` decodes.
/// Stdin stays connected to the script, unlike `... | sh`.
String posixShellCommand(String script) {
  final out = StringBuffer();
  for (final byte in utf8.encode(script)) {
    if (_isPlain(byte)) {
      out.writeCharCode(byte);
    } else {
      out.write('\\${byte.toRadixString(8).padLeft(3, '0')}');
    }
  }
  return 'sh -c \'eval "\$(printf "$out")"\'';
}

/// Bytes that mean nothing special inside double quotes to sh, to printf's
/// format, or inside single quotes to any login shell: letters, digits and
/// a handful of punctuation.
bool _isPlain(int byte) =>
    (byte >= 0x30 && byte <= 0x39) ||
    (byte >= 0x41 && byte <= 0x5a) ||
    (byte >= 0x61 && byte <= 0x7a) ||
    ' #&()*+,-./:;<=>?@[]^_{|}~'.codeUnits.contains(byte);

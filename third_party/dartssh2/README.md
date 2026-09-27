# dartssh2 (vendored)

A copy of the `dartssh2` package (MIT, see `LICENSE`) taken from
<https://github.com/gwitko/dartssh2_conduit> at commit
`c39f316a853e6d6a21db698503450a39d9e96d68`, which itself is a fork of
<https://github.com/TerminalStudio/dartssh2> 2.18.0. Only `lib/`, `LICENSE`,
`CHANGELOG.md`, `analysis_options.yaml` and `pubspec.yaml` were copied; the
upstream tests, examples and media stay upstream.

It is vendored because we cannot push to that fork and the SFTP client keeps
its extended-request plumbing private, so the extensions below cannot be
added from outside the package.

## Local patch

Kept small so it can be sent upstream as is:

- `SftpClient.posixRename(oldPath, newPath)`: the
  `posix-rename@openssh.com` extension, a rename that replaces an existing
  target atomically (plain SFTP v3 rename refuses an existing target).
- `SftpFile.fsync()`: the `fsync@openssh.com` extension.
- `SftpClient.supportsExtension(name, version)`: whether the server
  advertised an extension in its version handshake, so callers can pick a
  fallback before sending the request.

The diff against the origin commit is the git history of this directory
after the commit that added the pristine copy.

# The throwaway machine of tools/smoke-test.sh: sshd, Herdr and the
# companion from this checkout, with two fake Claude Code agents.
# Build context: a temp dir holding host/ (the companion), herdr (the
# binary) and the files of this folder.
FROM node:22-alpine
RUN apk add --no-cache openssh-server bash coreutils procps \
 && ssh-keygen -A \
 && adduser -D -s /bin/bash smoke \
 && echo 'smoke:smoke' | chpasswd \
 && printf 'PasswordAuthentication yes\nPermitRootLogin no\nAllowUsers smoke\n' >> /etc/ssh/sshd_config
COPY herdr /usr/local/bin/herdr
COPY --chown=smoke:smoke host /home/smoke/conductore-host
COPY start.sh fake-claude.sh /usr/local/bin/
USER smoke
RUN cd /home/smoke && conductore-host/install.sh \
 && printf 'export PATH="$HOME/.local/bin:$PATH"\n' >> /home/smoke/.profile
USER root
EXPOSE 22
CMD ["/usr/local/bin/start.sh"]

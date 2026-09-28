# Vendored: talkbawt server

The self-hosted option of `conductore-hostd talkbawt serve` (see the companion
README, "Talkbawt"). Nothing here runs unless that command is started.

| | |
| --- | --- |
| Upstream | https://github.com/andreconde21/talkbawt |
| Commit | `18b3ca24af95db79823c22f410a0b5ba22e11454` (merge of PR #1, "server additions for Conductore"), talkbawt 1.1.0 |
| Files | `src/app.mjs`, `src/db.mjs`, `src/guards.mjs`, `src/index.mjs`, `src/render.mjs`, unchanged. `src/server.mjs` (the deployed entry, which listens on `0.0.0.0` and trusts proxy headers) is left out: the companion embeds the server through `createTalkbawt()` from `src/index.mjs`. |
| Runtime | Node 22.5 or newer (`node:sqlite`); no npm dependencies |
| License | see `LICENSE` |

To update: copy the five files from the new upstream commit, update the commit
above, and run `node --test test/talkbawt.test.js` in `host/` (the client tests
run against this copy, and the local secret scan is checked against its
`guards.mjs`).

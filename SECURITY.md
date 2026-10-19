# Security Policy

Vinyl runs with your user's permissions, reads your Now Playing session, and (with your consent) scripts your browser and music apps. We take that seriously.

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Instead, use GitHub's [private vulnerability reporting](../../security/advisories/new). Include steps to reproduce and the macOS version. You'll get a response as soon as possible, and credit in the fix if you'd like.

## Scope

Particularly interesting areas:

- The Now Playing helper (`Helper/`), which is loaded into `/usr/bin/perl`
- AppleScript sent to browsers and music apps (`AppleScriptTarget`, `BrowserPlayback`)
- Data stored in `~/Library/Application Support/Vinyl`

## Supported versions

Only the latest release receives fixes during the beta.

# Security Policy

## Reporting a vulnerability

Please report security issues privately rather than opening a public issue.

Use GitHub's [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability) on this repository. Include what you did, what happened, and what you expected. A proof of concept helps but is not required.

This is a personal project maintained in spare time, so please allow a reasonable window for a first response before disclosing publicly.

## What this app can do

Knowing the boundaries makes it easier to judge whether something is a real finding.

**Agent Island makes no network requests.** There is no networking code in either the Swift app or the Rust helper, and neither process opens a TCP or UDP socket. Anything that appears to contradict that is a serious finding — please report it.

**It has no third-party dependencies.** No Swift packages, no Rust crates. The supply-chain surface is Apple's frameworks and the Rust standard library.

**It reads local agent transcripts.** `~/.claude/projects`, `~/.claude2/projects`, and `~/.codex/sessions`. It extracts state, bounded activity labels, changed-file *basenames*, model metadata, token counts, and the newest user prompt. It does not read file contents, assistant responses, tool output, diffs, or credentials.

**It writes in exactly two places outside its own container**, both opt-in and both reversible:

| What | Where | Enabled by |
| --- | --- | --- |
| Agent hook entry | `~/.claude/settings.json`, `~/.claude2/settings.json`, `~/.codex/hooks/hooks.json` | Settings → ANSWER FROM ISLAND |
| Nothing else | — | — |

A backup is taken before the first edit, and turning the toggle off removes the entry.

## Permissions

All optional. Core session tracking needs none of them.

- **Notifications** — completion and needs-input alerts.
- **System audio capture** — the music visualizer only. Audio is analysed frame by frame in memory and discarded; nothing is recorded or written to disk.
- **Accessibility** — suppressing the macOS volume HUD only. This is the broadest permission the app can hold, so it is worth being specific: the event tap consumes a key only *after* the corresponding volume change has succeeded, passes every non-volume key through untouched, refuses to start without the grant, and dies with the process.

## The answer transport

The one path by which the app can affect a running agent. Design notes, since it is the most security-relevant part:

- The island returns an **index into the option list the agent itself authored**. It never supplies text, and the label written into the verdict is read back out of the agent's own payload.
- The index is validated against that option list before it is sent; out-of-range values are discarded.
- The socket is mode `0600` inside a mode `0700` directory, and every connection's UID is checked with `getpeereid`.
- A Unix domain socket has no network stack behind it and cannot be reached from another machine.
- Request payloads are bounded at 64 KB, and concurrent questions at eight.
- Every failure path is silent: the agent falls through to its own terminal prompt.

## Code signing

Local builds are ad-hoc signed by default. `scripts/make-signing-cert.sh` optionally creates a self-signed identity so permission grants survive rebuilds. That certificate is scoped to code signing only (`CA:FALSE`, `codeSigning` extended key usage), its private key is restricted to `/usr/bin/codesign`, and nothing is added to the system trust store.

Releases are **not** notarized. Anyone distributing builds of this project should use their own Apple Developer ID.

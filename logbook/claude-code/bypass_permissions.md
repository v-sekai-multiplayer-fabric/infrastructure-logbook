# Why `bypassPermissions` in a settings file does nothing in VS Code

**Date:** 2026-08-18. **Desk:** Windows 11, VS Code, Claude Code native binary.

A permission mode was written into a settings file, the session went on asking for
permission, and the question was which of three things was wrong. The answer was none of
the first two, and it is not reachable from any settings file at all.

## Question

`permissions.defaultMode: "bypassPermissions"` was placed in `.claude/settings.local.json`.
The session continued to prompt. Why?

## Hypotheses

| | claim | how it dies |
|---|---|---|
| H1 | the key is wrong — `defaultMode` is not where the mode lives, or `bypassPermissions` is not the spelling | the string appears as an accepted mode value in the binary |
| H2 | the value is right but refused from a *project* settings file, as a scope rule | a refusal message naming project scope exists |
| H3 | the value is right and read, then discarded by the **host** — the editor — rather than by the CLI | a refusal message naming the host exists |

H1 and H2 were the two guesses worth writing down before looking, because both are ordinary
and both suggest a fix inside the repository. H3 suggests no fix inside the repository at
all, which is why distinguishing them was worth the measurement rather than another edit.

## Apparatus

The CLI is a single native binary, not a JavaScript bundle, so its strings are readable but
UTF-16 in places, which is what defeats a first pass with plain `grep`.

    /c/Users/ernes/.local/bin/claude     324,028,576 bytes

`strings` is not present on this desk. `grep -a` finds the ASCII fragments; the wide-char
ones need the NULs removed first, and that is the whole trick:

    tr -d '\000' < claude | grep -a -o -E ".{0,160}consent to it.{0,60}"

One pass over the binary costs **1.1 s** wall (0.83 user, 0.77 sys) — about as long as it
takes to read this sentence aloud, so an exploratory grep is free and there is no reason to
guess instead.

## Method

1. `grep -a -o -E ".{90}bypassPermissions.{120}"` over the raw binary, to find whether the
   token exists at all and in what company.
2. Re-run through `tr -d '\000'` once step 1 returned text with single spaces between every
   letter, which is UTF-16 read as bytes.
3. Widen the window around each candidate message until the sentence completes.

## Results

The token is an accepted mode value, listed beside `plan`, `acceptEdits`, `auto`, `default`
and `dontAsk`. **H1 is dead.**

No message names project scope, or any settings-file scope, as the reason for a refusal.
**H2 is dead.**

Three messages name the host, and one of them is the whole answer:

    Permission mode bypassPermissions from settings was ignored — enable the
    "Claude Code: Allow Dangerously Skip Permissions" setting in VS Code to consent to it

    settings defaultMode "bypassPermissions" ignored for a VS Code-owned session
    without the allow-bypass setting

    tengu_settings_bypass_unconsent

Two further strings show the same gate on the other two routes into the mode:
`bypassPermissionsBlockedByHost`, and `setMode:'bypassPermissions' is session-scoped; not
persisting as defaultMode`. So `/permissions` at runtime is gated by the host too, and does
not write itself back into a settings file even when it succeeds.

**H3 survives.** The value is read, then discarded, and the discard is the editor's
decision rather than the CLI's. The consent is deliberately not delegable to a file the
repository can commit — which is consistent: a file in a repository can be written by
anything that can write to the repository, and this mode is exactly the one where that
matters.

## What follows

The setting is a checkbox in VS Code, reached by its label rather than by anything this
workspace can hold. The CLI flag `--dangerously-skip-permissions` is read *before* the host
gate, so a terminal session takes the mode with no editor consent involved — which is the
usable answer for anyone who wants it today.

## Not measured

Stated because the entry would otherwise read as complete:

- **The VS Code setting's id was not found**, only its display label. The extension passes
  it to the CLI as `allowDangerouslySkipPermissions`, and the dotted id lives in the
  extension's `package.json`, which is not on this desk — `~/.vscode/extensions` does not
  exist here and no `anthropic.claude-code*` directory was found under `~`. Writing a
  guessed key into VS Code's `settings.json` would be a silent no-op if wrong, so none was
  written.
- **The toggle itself was never flipped**, so the claim that enabling it makes the settings
  value take effect is the binary's, not this desk's. It is untested here.
- **The CLI flag was not run** either. It is read earlier in the same function, which is
  evidence and not a measurement.

## A second observation, from the same afternoon

Not a designed experiment — it happened while the above was being written, and it is here
because it changed what got committed.

`.claude/settings.json` lost its `permissions.allow` block. The hypothesis that the edit
had failed is refuted by the tool reporting success and by a read-back showing both blocks
present. It was then observed to revert **three times**: after an `Edit`, after a `cat >`
heredoc, and again before the commit. `.claude/settings.local.json`, written in the same
window, was deleted outright.

Apparatus is just `git -C .claude diff` after each write. The conclusion is that the
running session owns that file while it runs, and rewrites it rather than merging into it —
`/plugin install` writing `enabledPlugins` is what dropped the permissions in the first
place. A hand-restore from inside the session that is doing the writing does not survive,
so the restore belongs in a different session, and the permissions were committed as
removed rather than as a diff that does not stick.

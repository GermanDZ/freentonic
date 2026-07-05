# Workflow schema versioning policy

Every workflow YAML declares a dialect version on its first line:

```yaml
version: 1
```

Providers live in a [separate repo](https://github.com/GermanDZ/freentonic-providers),
so the workflow YAML dialect **is** freentonic's public contract with
provider authors. This document says what that `version:` number promises,
so a provider can pin against it with confidence. It pairs with the
[CHANGELOG](../CHANGELOG.md), which is the per-release signal of what
actually changed.

## What `version: 1` promises

`version: 1` is the only dialect version today. While the major version
stays at `1`:

- **Additive changes never bump the version.** New optional keys, new
  workflow actions, new `api_client:` / `normalize:` / `credentials:`
  sub-keys, and new accepted values for an existing key are all backward
  compatible: a workflow written against an earlier `1` release keeps
  loading and running unchanged. New capabilities are opt-in. (The
  `extract: plan:` form is an example — it is a new accepted shape for an
  existing key; every `extract: { ruby:, class: }` workflow is untouched.)
- **Defaults don't shift under you.** If a key is absent, its behavior is
  the same across `1.x` releases. A new key may *introduce* a default for
  behavior that previously required no key, but it won't change the meaning
  of a workflow that was already valid.
- **Validation only gets stricter for genuinely invalid input.** Load-time
  validation (see `--lint`) may start rejecting a workflow that was already
  malformed (e.g. an unknown action name, a missing required key). It will
  not start rejecting a workflow that was well-formed under an earlier `1`
  release.

In short: **anything you could write under `version: 1` last release, you
can still write this release.**

## What bumps the version

A change bumps to `version: 2` only when it would break an existing valid
workflow:

- **Renaming or removing a key or action.** e.g. renaming `capture_header:`
  or removing an action.
- **Changing the meaning of an existing key** such that an unchanged
  workflow would behave differently.
- **Making a previously optional key required**, or removing an accepted
  value.

When that happens:

1. The new form ships first, accepted **alongside** the old one, for at
   least one release — a dual-accept window. During this window the old
   form still works and, where it makes sense, `--lint` emits a
   deprecation warning naming the replacement.
2. Only in a **later** release is the old form removed and the required
   `version:` bumped to `2`. Loading a `version: 1` workflow against a
   `version: 2`-only release fails fast with an actionable message rather
   than silently misbehaving.

This means a rename is never a same-day break: you always get a release
where both spellings work, so provider repos can migrate on their own
schedule and pin to a known-good freentonic version in the meantime.

## How this shows up in the changelog

Because the dialect is the public API, every change that touches it is
called out in the [CHANGELOG](../CHANGELOG.md):

- **Additive** changes appear under a normal release heading (e.g. "new
  `cursor` pagination", "new `field_aliases` key"). No version bump.
- **Deprecations** are called out explicitly when the dual-accept window
  opens, naming the old and new forms and the release the old one is
  slated for removal.
- **Breaking** changes (the eventual `version: 2`) get their own prominent
  entry describing the migration.

## For provider authors: how to pin

- Keep `version: 1` at the top of every workflow. `--lint` will tell you
  immediately if you're running against a release that no longer accepts
  it.
- Pin the freentonic gem/image to a known-good version and upgrade
  deliberately. Read the changelog's additive entries to adopt new
  capabilities; watch for deprecation entries so you migrate within the
  dual-accept window rather than after it closes.

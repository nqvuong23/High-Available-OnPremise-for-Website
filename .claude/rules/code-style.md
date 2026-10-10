# Code and documentation style

> This rule has no `paths` frontmatter on purpose: it applies to every file in the repo.
> One sentence version: everything written down is English and short. Vietnamese belongs in chat only.

## Language

- Every file in the repo is English: Ansible tasks, Bash and Python code, comments, commit messages, documentation, `.claude/` rules.
- Vietnamese is used only when chatting with Claude Code. It never ends up in a file, not even in a comment.
- No Vietnamese in command output, `echo` text, `name:` of an Ansible task, log lines, error messages, alert text or variable names.
- No Vietnamese without diacritics either. `[LOI] IP bi trung` is still Vietnamese; write `[ERROR] duplicate IP`.
- File names, variable names, host names and command names are English and already were; keep them that way.

## Comments

- A comment summarises, it does not narrate. Keywords and a short clause are enough.
- One line is the default. Two or three lines only when the *why* is genuinely not obvious from the code.
- Comment the reason, not the mechanics. The code already says what it does.
- No paragraph-length essays above a block of code, no step-by-step retelling of what the next five lines do.
- No decorative banners or box drawing to separate sections; a blank line and one short header comment is enough.
- Explain a non-obvious decision in the matching `.claude/rules/` file or an ADR under `docs/`, then point at it from the code in one line.

```bash
# good
ip_nonlocal_bind: BACKUP must bind the VIP it does not own yet

# bad
# Here we set the kernel parameter net.ipv4.ip_nonlocal_bind to the value 1.
# The reason we do this is that HAProxy running on the BACKUP node needs to be
# able to bind to the VIP address even though at this point in time the VIP is
# still owned by the MASTER node, and without this parameter the bind call
# would fail with EADDRNOTAVAIL, which would then mean that ...
```

## Log and output strings

- English, one line, lowercase after a bracketed level tag.
- Fixed prefixes so output is greppable: `[OK]`, `[WARN]`, `[ERROR]`, `[INFO]`.
- Say what happened and which object it happened to: `[ERROR] db01 not writable`, not `[ERROR] something went wrong`.
- A script that produces measurements prints machine-readable lines first and prose second, so results can be parsed later.
- Never print a secret; use `no_log: true` in Ansible and redact in scripts.

## Ansible task names

- Imperative, English, under about 60 characters: `Install MySQL 8.4 from Oracle repo`.
- Name the object and the action. Do not restate module options already visible below.

## Documentation

- English, short sentences, one idea per bullet.
- State the trade-off next to the decision; a decision without its cost is not documented.
- Numbers must be measured, with the measuring command shown next to them.

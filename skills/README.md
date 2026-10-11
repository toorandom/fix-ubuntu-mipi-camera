# Claude Code skill

`ipu6-camera/` is a [Claude Code](https://claude.com/claude-code) skill: a written
procedure Claude loads when you describe a camera problem, so it does not have to
re-derive any of this from scratch.

Install it for your user:

```bash
mkdir -p ~/.claude/skills
cp -r skills/ipu6-camera ~/.claude/skills/
```

Then either describe the problem in plain words ("the camera is upside down", "it hung
when I closed the lid") and Claude loads it on its own, or invoke it explicitly with
`/ipu6-camera`.

It is worth having mostly for the negative knowledge — the approaches that look
reasonable and are wrong:

- a plain `systemctl suspend` does not reproduce the hibernation bug at all, and
  `rtcwake` wedges the MEI stack while skipping the very hooks under test;
- a hang at `Freezing user space processes` is where the log always ends, because
  journald freezes there too, so it says nothing about where the kernel actually died;
- `dmesg -T` reports wrong times after hibernation;
- the reference leaks on the sensor side are load-bearing and must not be "fixed".

Every one of those cost real debugging time to learn.

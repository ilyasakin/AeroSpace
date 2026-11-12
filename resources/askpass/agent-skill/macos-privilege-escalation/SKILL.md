---
name: macos-privilege-escalation
description: How to run a command as root (or another user) on this Mac from an agent. Use whenever a command needs sudo, administrator rights or root - installing system files, editing /etc, launchctl bootstrap system, pmset, tmutil, chown to root, anything that fails with "Permission denied" or "Operation not permitted" for lack of privileges. Covers when to use sudo versus pkexec (AeroSpace's password prompt) and how to wait for the user's approval.
---

# Privilege escalation on this Mac

This Mac has `pkexec`, the macOS counterpart of the polkit command on Linux desktops such as
Omarchy. `pkexec CMD` runs `sudo -A CMD`; sudo asks for the password through AeroSpace, which
dims the screen and shows a prompt naming the requester and the exact command. The user types
the password there. sudo checks it, runs the command and logs it. AeroSpace never runs anything
privileged itself.

## sudo or pkexec

- **A terminal the user can type into** (an interactive shell the user is watching): use `sudo`.
- **No terminal to type a password into** (you are an agent running commands, a GUI action, a
  background job): use `pkexec`. Plain `sudo` there fails with "a terminal is required" or
  hangs waiting for input nobody can give.
- Use either only when the command needs the privilege. Do not reach for root just because a
  command changes state; most work in the user's own files needs none.

## How to call it

```sh
pkexec /usr/bin/some-command --flag value       # as root
pkexec --user _www /usr/bin/some-command        # as another user
pkexec /bin/sh -c 'step-one && step-two'        # several related steps, one approval
```

1. Say in your message, before the call, exactly which command you are about to run as root and
   why. The user approves it in the prompt, and it should match what you told them.
2. Prefer full paths (`/usr/bin/...`): the prompt shows the command as given.
3. The call blocks until the user answers, for up to 60 seconds. Give the tool call a timeout
   longer than that, or run it in the background and wait for it to finish.
4. Group a few related privileged steps into one `pkexec /bin/sh -c '...'` rather than asking for
   the password repeatedly. Keep the script short enough to read in the prompt.

## Results

- Exit 0: the command ran; its output is the command's own.
- `sudo: no password was provided` / `a password is required`: the user pressed Esc, the prompt
  timed out, or AeroSpace refused the request. Do not retry on your own; ask the user.
- `aerospace askpass: AeroSpace is not running`: ask the user to start AeroSpace, or to run the
  command themselves (in Claude Code they can type `! sudo <command>`).
- `pkexec: command not found`: this setup is missing; ask the user to run the command themselves.

## Never

- Never pipe or embed a password (`echo … | sudo -S`, `expect`, a password in a file or variable).
- Never ask the user to type their password into the chat.
- Never edit sudoers, PAM or the askpass setup to avoid the prompt.
- Never use `pkexec` to work around a permission the user denied, or for a command you did not
  describe to them first.

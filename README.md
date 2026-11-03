# wsl-ssh-config-sync

Keeps `~/.ssh/config` in WSL as the source of truth and copies it to the Windows OpenSSH config on every save.

- Copies the config to the Windows side each time you save it
- Refuses to overwrite the Windows file if it was edited directly
- Syncs once at WSL startup as well

## Why

Pointing WSL at the Windows config does not work: an `Include` of a `/mnt/c` file, or a symlink to it, makes WSL's `ssh` refuse the file with `Bad owner or permissions`: Windows drives mounted without the `metadata` option show every file as mode 0777. The same error happens in the other direction, when Windows `ssh` includes `\\wsl.localhost\<distro>\home\<you>\.ssh\config`.

So the WSL side is the source of truth and a plain copy is made to Windows. Write keys as `IdentityFile ~/.ssh/<key>`: Windows OpenSSH expands `~` to `%USERPROFILE%`, so the same config works on both sides, as long as a key with that name exists on each side.

## Requirements

- WSL 2 with systemd enabled (`systemd=true` under `[boot]` in `/etc/wsl.conf`)
- The Windows OpenSSH client
- POSIX `sh` and coreutils
- To sync while no WSL shell is open, enable lingering: `loginctl enable-linger "$USER"`

Tested on WSL 2 (Ubuntu, systemd 259) with the Windows OpenSSH client.

## Installation

**1. Put the files in place**

```sh
base=https://raw.githubusercontent.com/denchu-unagi/wsl-ssh-config-sync/main
mkdir -p ~/.local/bin ~/.config/systemd/user
curl -fsSL "$base/bin/wsl-ssh-config-sync" -o ~/.local/bin/wsl-ssh-config-sync
chmod +x ~/.local/bin/wsl-ssh-config-sync
curl -fsSL "$base/systemd/wsl-ssh-config-sync.path" -o ~/.config/systemd/user/wsl-ssh-config-sync.path
curl -fsSL "$base/systemd/wsl-ssh-config-sync.service" -o ~/.config/systemd/user/wsl-ssh-config-sync.service
```

**2. Write the Windows path to the env file**

```sh
winhome=$(wslpath "$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')")
mkdir -p ~/.config/wsl-ssh-config-sync
printf "WSL_SSH_CONFIG_SYNC_TARGET='%s'\n" "$winhome/.ssh/config" > ~/.config/wsl-ssh-config-sync/env
cat ~/.config/wsl-ssh-config-sync/env
```

The value is quoted so that a Windows user name with spaces works both for the service and for `.` in a shell.

**3. Back up the Windows config**

```sh
. ~/.config/wsl-ssh-config-sync/env
mkdir -p "$(dirname "$WSL_SSH_CONFIG_SYNC_TARGET")"
[ -e "$WSL_SSH_CONFIG_SYNC_TARGET" ] && cp "$WSL_SSH_CONFIG_SYNC_TARGET" "$WSL_SSH_CONFIG_SYNC_TARGET.bak-$(date +%Y%m%d%H%M%S)"
```

**4. Merge the Windows-only entries into `~/.ssh/config`**

Do this by hand in an editor. Copy every `Host` block that exists only in the Windows config into `~/.ssh/config`, and write keys as `IdentityFile ~/.ssh/<key>`. The next step overwrites the Windows config, so anything not merged here is gone from it (the backup from step 3 still has it).

**5. Make both sides identical**

```sh
. ~/.config/wsl-ssh-config-sync/env
cp ~/.ssh/config "$WSL_SSH_CONFIG_SYNC_TARGET"
```

This matters: on the very first run the sync refuses to overwrite a Windows file that differs, and stops with exit 1.

**6. Enable it**

```sh
systemctl --user daemon-reload
systemctl --user enable --now wsl-ssh-config-sync.service
systemctl --user enable --now wsl-ssh-config-sync.path
systemctl --user status wsl-ssh-config-sync.path
```

The service runs first while both files are identical, so it records the current content and succeeds.

**7. Check that it works**

```sh
. ~/.config/wsl-ssh-config-sync/env
printf '\n# sync test\n' >> ~/.ssh/config
sleep 1; tail -n 1 "$WSL_SSH_CONFIG_SYNC_TARGET"     # shows: # sync test
# remove those two lines from ~/.ssh/config again
```

In PowerShell, `ssh -G <host>` should print the configuration coming from the copied file.

## Uninstall

```sh
systemctl --user disable --now wsl-ssh-config-sync.path wsl-ssh-config-sync.service
rm -f ~/.local/bin/wsl-ssh-config-sync \
      ~/.config/systemd/user/wsl-ssh-config-sync.path \
      ~/.config/systemd/user/wsl-ssh-config-sync.service \
      ~/.config/wsl-ssh-config-sync/env
rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/wsl-ssh-config-sync"
systemctl --user daemon-reload
```

## Configuration

| Variable | Meaning |
| --- | --- |
| `WSL_SSH_CONFIG_SYNC_TARGET` | Required. Path of the Windows OpenSSH config, written in the env file. |
| `XDG_STATE_HOME` | Where the sync record is kept. Defaults to `~/.local/state`. |

The source is always `~/.ssh/config` and cannot be changed: the path unit watches that exact path.

## How it works

1. The script copies `~/.ssh/config` into a temporary snapshot and uses only that snapshot.
2. It compares the snapshot with the target.
3. If the target exists, differs from the snapshot, and also differs from the record of the last sync, the Windows file was edited directly: the script prints recovery steps and stops without touching anything.
4. Otherwise it writes the snapshot to a temporary file next to the target and renames it over the target (also when the target does not exist yet), so a failed copy never leaves a half-written Windows config. The renamed file takes the permissions inherited from the Windows `.ssh` folder.
5. It records the snapshot the same way, so the next run can tell a normal change from a direct edit on Windows.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | Synced, or already identical |
| 1 | Refused or failed: the Windows file was edited after the last sync, or a copy failed. The log says which. |
| 2 | `WSL_SSH_CONFIG_SYNC_TARGET` is not set; nothing was changed |

If the target was renamed into place but recording the snapshot then failed, the next change is treated as a direct Windows edit and refused. Nothing is lost; recover as below.

## Limitations

The check and the rename are not atomic with Windows editors. A save on the Windows side that lands in the few milliseconds between them is overwritten. Edit only `~/.ssh/config` in WSL.

## When syncing stops

Editing the Windows config directly stops syncing, because overwriting it would silently lose those edits. You can notice it with:

```sh
systemctl --user --failed
journalctl --user -t wsl-ssh-config-sync
```

Use `-t`, not `-u`: the script exits so quickly that journald often cannot attach its message to the service unit.

To recover:

1. Merge the changes from the Windows config into `~/.ssh/config`.
2. Record the Windows content as the last sync:

   ```sh
   . ~/.config/wsl-ssh-config-sync/env
   state="${XDG_STATE_HOME:-$HOME/.local/state}/wsl-ssh-config-sync"
   mkdir -p "$state"
   cp "$WSL_SSH_CONFIG_SYNC_TARGET" "$state/last-synced"
   ```

3. Resume: `systemctl --user start wsl-ssh-config-sync.service`

## Tests

```sh
cd tests && ./test.sh
```

The tests use temporary files only and never touch your real `~/.ssh` or `/mnt/c`.

## License

[MIT](LICENSE)

Unofficial tool, not affiliated with Microsoft.

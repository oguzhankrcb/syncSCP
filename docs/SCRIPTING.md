# Scripting with syncscp-cli (0.23.0)

`syncscp-cli` is syncSCP's counterpart to `winscp.com`: the same sites, host keys and settings as the app, driven by commands. It ships inside the app at `syncSCP.app/Contents/MacOS/syncscp-cli`; Help ▸ Install Command Line Tool shows the command that links it into your PATH as `syncscp`.

## Running

```bash
syncscp                                   # interactive prompt (errors do not stop it)
syncscp /script=backup.txt                # run a script file
syncscp /command "open Production/web" "get /var/log/app.log" "exit"
syncscp /store=~/other-data /command …    # use another data folder
```

`-script=`, `-command` and `-store=` work too. The exit code is 0 only when every command succeeded, so scripts can be used in cron jobs and CI.

## Commands

| Command | Meaning |
| --- | --- |
| `open SITE` / `open URL` | Connect to a saved site (its name, `Folder/Name`) or a URL: `sftp://`, `scp://`, `ftp://`, `ftps://` (implicit), `ftpes://` (explicit), `dav://`, `davs://`, `s3://` with `user[:password]@host[:port]/path`. Options: `-hostkey=SHA256:…`, `-password=…`, `-privatekey=FILE`. A second argument is the starting folder. |
| `close`, `exit` | End the session / the script. |
| `ls [MASK]`, `cd`, `pwd` | Remote listing (masks such as `*.log`), folder change, current folder. |
| `lls`, `lcd`, `lpwd` | The same on this Mac. |
| `get [-delete] REMOTE… [LOCAL]` | Download files or folders (masks allowed); with a folder as the target, into it. `-delete` removes the remote copy afterwards. |
| `put [-delete] LOCAL… [REMOTE]` | Upload; `-delete` moves the local copy to the Trash afterwards. Existing remote files are replaced. |
| `rm`, `rmdir`, `mkdir` | Delete (folders recursively), remove an empty folder, create a folder. |
| `mv SRC… TARGET`, `cp SRC… TARGET` | Move or copy on the server (into TARGET when it is a folder). |
| `chmod MODE FILE…` | Set an octal mode. |
| `stat FILE` | One file's details. |
| `synchronize remote\|local\|both [LOCAL [REMOTE]]` | Like the app's Synchronize: `remote` uploads changes, `local` downloads, `both` copies the newer side. `-delete` mirrors (not with `both`), `-criteria=size` ignores times, `-preview` only lists. A missing target folder is created. |
| `option batch abort\|continue` | Stop at the first error (default for scripts) or keep going. `option confirm …` is accepted and ignored. |
| `echo TEXT` | Print text. |

## Passwords and host keys

- Keys and the SSH agent work as in the app. A password comes from `-password=`, the URL, the `SYNCSCP_PASSWORD` environment variable, or a prompt when the tool runs in a terminal. SSH passwords reach `ssh` through askpass from a temporary Keychain item, never through arguments. S3 session tokens come from `SYNCSCP_S3_SESSION_TOKEN`.
- Passwords saved in the app's Keychain are not read by the tool (macOS would ask for permission on every run).
- An SSH host key must already be trusted in syncSCP. Otherwise `open` stops and prints the fingerprint the server presents; check it, then add `-hostkey="SHA256:…"`, and it is remembered. `-hostkey=*` accepts any key with a warning, which defeats the check.

## Example

```text
# Nightly: upload the build and keep the server folder identical to it
option batch abort
open Production/app-server -hostkey="SHA256:PTfMDqEG83rjmMlubWom0BsMdI4t4l9r2Dy8zCmv9Z4"
synchronize remote ~/Projects/storefront/dist /srv/www/storefront/current -delete
get /var/log/nginx/error.log ~/Logs/
exit
```

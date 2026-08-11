# User-level service install

These service files run the Synapsis OTP release from:

```sh
$HOME/.local/opt/synapsis
```

The service environment is loaded from:

```sh
$HOME/.config/synapsis/synapsis.env
```

## Prepare the release

```sh
mkdir -p "$HOME/.local/opt/synapsis" "$HOME/.config/synapsis" "$HOME/.local/state/synapsis"
tar -xzf synapsis-<version>-<platform>.tar.gz -C "$HOME/.local/opt/synapsis"
```

Use the archive matching your host:

```text
synapsis-<version>-linux-amd64.tar.gz
synapsis-<version>-linux-arm64.tar.gz
synapsis-<version>-macos-amd64.tar.gz
synapsis-<version>-macos-arm64.tar.gz
```

Create the user service environment:

```sh
{
  printf 'SECRET_KEY_BASE=%s\n' "$(openssl rand -base64 64)"
  printf 'SYNAPSIS_ENCRYPTION_KEY=%s\n' "$(openssl rand -base64 32)"
  printf 'PHX_HOST=localhost\n'
  printf 'PORT=4657\n'
} > "$HOME/.config/synapsis/synapsis.env"
```

The release listens on `127.0.0.1` by default. `PHX_HOST` controls generated
URLs; it does not widen the listening socket. To bind another interface, set
`PHX_IP` to an explicit IPv4 or IPv6 address.

> **Warning:** Synapsis v0.1.3 has no authentication boundary for HTTP,
> LiveView, channels, or SSE. Setting `PHX_IP=0.0.0.0`, `PHX_IP=::`, or another
> non-loopback address exposes the local agent to the network. Put an
> authenticating reverse proxy in front of it before opting in to remote access.

By default, both user-level services store Synapsis state under:

```sh
$HOME/.config/synapsis
$HOME/.local/state/synapsis
```

## macOS launchd LaunchAgent

```sh
mkdir -p "$HOME/Library/LaunchAgents"
sed "s#__HOME__#$HOME#g" com.gsmlg.synapsis.plist > "$HOME/Library/LaunchAgents/com.gsmlg.synapsis.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.gsmlg.synapsis.plist"
launchctl enable "gui/$(id -u)/com.gsmlg.synapsis"
launchctl kickstart -k "gui/$(id -u)/com.gsmlg.synapsis"
```

Check status and logs:

```sh
launchctl print "gui/$(id -u)/com.gsmlg.synapsis"
tail -f /tmp/synapsis.out.log /tmp/synapsis.err.log
```

Stop and uninstall:

```sh
launchctl bootout "gui/$(id -u)/com.gsmlg.synapsis"
rm "$HOME/Library/LaunchAgents/com.gsmlg.synapsis.plist"
```

## Linux systemd user service

```sh
mkdir -p "$HOME/.config/systemd/user"
cp synapsis.service "$HOME/.config/systemd/user/synapsis.service"
systemctl --user daemon-reload
systemctl --user enable --now synapsis.service
```

Check status and logs:

```sh
systemctl --user status synapsis.service
journalctl --user -u synapsis.service -f
```

Allow the service to start at login without an active session:

```sh
loginctl enable-linger "$USER"
```

Stop and uninstall:

```sh
systemctl --user disable --now synapsis.service
rm "$HOME/.config/systemd/user/synapsis.service"
systemctl --user daemon-reload
```

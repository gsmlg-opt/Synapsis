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

Linux archives require glibc plus the runtime libraries that provide
`libtinfo.so.6`, `libz.so.1`, `libstdc++.so.6` and `libgcc_s.so.1` (commonly
the ncurses/tinfo, zlib, libstdc++ and GCC runtime packages). The bundled
official Node also uses the C++ and GCC runtime libraries. On NixOS, expose
all of these libraries through `nix-ld` or an equivalent explicit library
path before starting the release.

The release packages its filesystem Node executable and complete upstream
license under `releases/<version>/filesystem-node/`. Its `env.sh` selects that
version's absolute executable path after extraction, including when the release
directory moves. No Node installation or PATH lookup is needed for these file
helpers. An explicitly configured `SYNAPSIS_FILESYSTEM_NODE` takes precedence.
This runtime does not supply every browser, media codec or platform dependency.

For source builds, set `SYNAPSIS_FILESYSTEM_RUNTIME_ROOT` to the root of the
trusted official Node 24.22.1 distribution for the build target before running
`mix release synapsis`. The release step copies its `bin/node` and complete
`LICENSE`; it does not download or choose a host runtime. Build for each target
on that target and verify the resulting archive independently. Existing
Linux x64 checks do not establish macOS or ARM execution.

Create the user service environment:

```sh
umask 077
{
  printf 'SECRET_KEY_BASE=%s\n' "$(openssl rand -base64 64)"
  printf 'SYNAPSIS_ENCRYPTION_KEY=%s\n' "$(openssl rand -base64 32)"
  printf 'PHX_HOST=localhost\n'
  printf 'PORT=4657\n'
} > "$HOME/.config/synapsis/synapsis.env"
chmod 600 "$HOME/.config/synapsis/synapsis.env"
```

The release listens on `127.0.0.1` by default. `PHX_HOST` controls generated
URLs; it does not widen the listening socket. To bind another interface, set
`PHX_IP` to an explicit IPv4 or IPv6 address.

> **Warning:** Synapsis v1 has no application authentication boundary for HTTP,
> LiveView, channels, or SSE. Setting `PHX_IP=0.0.0.0`, `PHX_IP=::`, or another
> non-loopback address exposes the local agent to the network. Put an
> authenticating reverse proxy in front of it before opting in to remote access.

## Remote administration with Caddy mTLS

Synapsis deliberately does not implement terminal-user authentication. For
remote API, SSE, Channel, or LiveView access, Caddy must be the public endpoint
and must verify a client certificate before forwarding to Synapsis. Keep
`PHX_IP=127.0.0.1`; setting a public bind address bypasses this trust boundary.

```caddyfile
synapsis.example.com {
  tls {
    client_auth {
      mode require_and_verify
      trust_pool file /etc/caddy/synapsis-client-ca.pem
    }
  }

  reverse_proxy 127.0.0.1:4657
}
```

Set `PHX_HOST=synapsis.example.com`. Caddy supplies the forwarded host and
protocol headers used by Phoenix and supports the long-lived SSE and WebSocket
connections without a separate route. When Caddy is the first proxy it ignores
spoofed incoming `X-Forwarded-*` values; configure `trusted_proxies` explicitly
if another trusted proxy is placed in front of it.

The client CA file contains only public trust material. Keep its signing key
offline, issue separate certificates with the `clientAuth` extended key usage,
and keep each client private key on the administrator or monitoring host. Test
the boundary after every proxy change:

```sh
# Expected to fail: no client certificate.
curl --fail https://synapsis.example.com/api/health

# Expected to return health JSON.
curl --fail \
  --cert synapsis-admin.pem \
  --key synapsis-admin.key \
  https://synapsis.example.com/api/health
```

Local health checks may use `http://127.0.0.1:4657/api/health`. Remote health
checks must come through Caddy from a trusted network and use their own client
certificate.

Backplane connection credentials are stored through the existing connection
configuration, encrypted with `SYNAPSIS_ENCRYPTION_KEY`, and redacted from API
responses. Supply them only over the mTLS-protected API/CLI path; do not put
them in the Caddyfile, command history, or query parameters.

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

---
name: fleetview-peers
description: >-
  Reach the OTHER FleetView instances on this network — the ones running on different Macs — with
  the `project-manager` CLI. Use whenever the task spans machines: "what is the other Mac working
  on", "check the fleet on my laptop", "is anything stuck on the studio machine", "tell the agent
  over there to continue", "find every FleetView on the network". Also use before assuming a
  terminal is missing: it may simply be on another instance.
---

# Controlling other FleetView instances

Each FleetView serves an HTTP API on all interfaces, and `project-manager` speaks it. So the same
CLI that drives the local fleet drives any instance you can reach — no agent, no relay, nothing to
install on the other machine.

## Find them

```bash
project-manager peers
```

```
URL                    TERMS WORKING   PROJECTS
http://192.168.2.2:8080 9     1         cosy voice, FleetView
http://192.168.2.6:8080 26    2         FleetView, datagen_vision2web  ←self
```

It probes the local /24 on 8080–8082 and identifies an instance by whether `/state` answers with the
right shape. A whole subnet takes a few seconds. FleetView binds the next free port from 8080 up, so
a machine whose 8080 was busy appears on 8081 — and **one machine can show up twice**, which means
two instances are running there and they are fighting over the same hook events. That is worth
reporting, not working around.

## Drive one

```bash
project-manager -u http://192.168.2.2:8080 ls
project-manager -u http://192.168.2.2:8080 show cosy -l 40
project-manager -u http://192.168.2.2:8080 send cosy "继续"
```

`-u` applies to every subcommand; `FLEETVIEW_URL` does the same thing if you would rather export it
once. Everything in the [[project-manager]] skill works unchanged against a remote instance —
`ls`, `watch`, `show`, `tail`, `send`, `key`, `choose`, `check`, `new`, `rm`.

## Three things do not cross the network

- **`open`** hands back a ttyd port on *that* machine. The web dashboard rebuilds a URL from its own
  host, which is why it works there; a remote CLI just gets a number. Use `show`/`tail` to read a
  terminal instead.
- **`log`** prints a transcript path on *that* machine's filesystem. It will not exist locally, so do
  not try to read it — `show` is how you see that conversation from here.
- **`ask`** forks an agent process on the remote machine. It works, but it spends that machine's API
  budget and you cannot see it start. Prefer `show` unless you specifically want the agent's own
  reading of its context.

## There is no authentication

Anything that can reach the port can inject prompts, press keys, and remove terminals. There is no
token, no password, and the agents on the other side usually run with permissions bypassed.

What follows from that, for you:

- **You are driving someone's live work.** A prompt you inject lands in a real session that may be
  mid-task. `ls` and `show` first; know what it is doing before you send anything.
- **Say which instance you touched.** Report the URL alongside the terminal name, always. "Sent
  继续 to `cosy voice-1`" is ambiguous across machines; "…on `192.168.2.2:8080`" is not.
- **Never `rm` on a remote instance without being asked to.** Removing a terminal destroys its tmux
  session and whatever was running in it. On your own machine that is recoverable knowledge; on
  another one you cannot see what you took.
- **Do not scan networks you were not asked to.** `peers` looks at the local subnet, which is fine
  at home and is not fine on a café or office network. If the user is somewhere shared, ask first.

## Conventions

- **Read before write, every time.** `peers` → `ls` → `show` → only then `send`.
- **A terminal selector is per-instance.** `8f904256` on one machine means nothing on another, and
  name substrings collide across fleets. Resolve the id against the instance you are targeting.
- **If a peer disappears mid-task, say so.** A laptop closing its lid takes its whole fleet with it;
  that is not an error to retry through.

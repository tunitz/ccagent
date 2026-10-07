# ccagent

Tiny bash metrics agent for the Control Center dashboard. Samples CPU, GPU, RAM and power into a local JSONL log; the Control Center reads it over SSH with a per-unit key restricted to a forced command.

Install (the Control Center shows this command with the unit's own public key filled in):

```
curl -fsSL https://github.com/tunitz/ccagent/releases/latest/download/install-ccagent.sh | sudo bash -s -- '<ssh-ed25519 public key>'
```

The installer needs no secrets: it only authorizes the public key you pass. Remove with `sudo /opt/ccagent/uninstall.sh`.

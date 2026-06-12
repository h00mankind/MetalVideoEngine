Metal render verification must run outside the outer sandbox.

In this repo, sandboxed `mve` render and benchmark runs can fail before
project code with `job failed: no Metal device on this system`. The same
release binary succeeds when run with sandbox escalation, so final render
checks that need `MTLCreateSystemDefaultDevice()` should be executed
unsandboxed.

Checks are selected through `.ci/ccid.toml` and run by the pinned shared ccid runner on a trusted worker.

The default selection is `native`. Native Linux success does not certify a foreign architecture, a separately selected image or hardware gate, or publication. Use `list` to inspect available native Nix checks, and select existing results or affected checks before scheduling more work.

Additional coverage limits:

- Working tree is active nixciri per durable task, but canonical origin still ends nixniri-corbet-ch; resolve identity before registration.
- GitHub redirects old nixniri URL to nixciri; remote main e23378090d46e55c44f4d7c33e288262d622e494 differs local HEAD 11e3d0cfbd6aa2f9b3934ba65277dbf5814d391f. Synchronize safe source before migration.
- Remote-current workflow has a 120-minute KVM gate and flake consumes corbet-foss/ciri with runtime nested/TTY VM fixtures; local copy understates current coverage. Preserve these gates when synchronizing.

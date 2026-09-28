Checks are selected through `.ci/ccid.toml` and run by the pinned shared ccid runner on a trusted worker.

The default selection is `native`. Native Linux success does not certify a foreign architecture, a separately selected image or hardware gate, or publication. Use `list` to inspect available native Nix checks, and select existing results or affected checks before scheduling more work.

Additional coverage limits:

- The canonical repository is `corbet-nix/nixciri-corbet-ch`.
- The flake consumes `corbet-foss/ciri`. Its nested and TTY VM gates exercise the exact packaged runtime; the nested gate also checks movement through persistent empty workspaces with real clients.
- Hosted CI evaluates all declared architectures and runs native checks, including both KVM fixtures. Foreign architectures are evaluated, not runtime-tested.

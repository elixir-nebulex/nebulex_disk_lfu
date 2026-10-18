# Project Rules

This repository is `nebulex_disk_lfu`, a persistent disk cache adapter with
LFU eviction for [Nebulex](https://github.com/elixir-nebulex/nebulex). The
shared rules come from the `nebulex` dependency, so run `mix deps.get`
first; the `@deps/…` files do not exist in a fresh clone. The workflow
below says what to read for each kind of task; where it says
`architecture.md`, read this repo's guide (core's applies for context).

@deps/nebulex/usage-rules/workflow.md

@usage-rules/architecture.md

## Running Tests

The suite has its own tests and does not reuse the Nebulex shared suites,
so there is no Nebulex checkout to set up:

```bash
mix deps.get
mix test
```

The tests write to temporary directories (through `briefly`) and clean them
up.

<!-- usage-rules-start -->
<!-- nebulex:nebulex-start -->
## nebulex:nebulex usage
[nebulex:nebulex usage rules](deps/nebulex/usage-rules/nebulex.md)
<!-- nebulex:nebulex-end -->
<!-- nebulex:elixir-style-start -->
## nebulex:elixir-style usage
[nebulex:elixir-style usage rules](deps/nebulex/usage-rules/elixir-style.md)
<!-- nebulex:elixir-style-end -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

[usage_rules usage rules](deps/usage_rules/usage-rules.md)
<!-- usage_rules-end -->
<!-- usage-rules-end -->

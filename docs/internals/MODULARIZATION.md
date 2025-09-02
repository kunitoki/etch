**Component Boundaries (DONE)**

- `src/etch/core/**`: hold value tags, heap management (`regvm_heap`, `regvm_heap_verify`), the dispatch loop (`regvm`, `regvm_exec`), host/CFFI glue (`regvm_host`, `regvm_cffi`), serializers and minimal logging; expose a small API via `etch/core/runtime.nim` that creates `VirtualMachine`, loads bytecode blobs, and runs them without referencing compiler/debugger code.
- `src/etch/bytecode/**`: keep everything that produces or manipulates bytecode—`regvm_compiler`, optimizer/lifetime passes, AST passes, prover hooks, bytecode (de)serializer, and the frontend/typechecker stack (`frontend`, `typechecker`, `prover`, `modules`). This layer depends on `core` only through `bytecode_types` and `bytecode_program` records.
- `src/etch/tooling/**`: place CLI (`cli/**`), tester/bench runners (`tester.nim`, `backend/**`), coma-time evaluator, and utilities that orchestrate compiler+VM; they import the `bytecode` façade, never the raw `core` internals.
- `src/etch/capabilities/**`: isolate debugger (`regvm_debugger*`), profiler, replay (`regvm_replay`), dump tooling, each exposing `Capability` objects that can be registered with `VirtualMachine` if the build enables them.
- Public entry points mirror the layers: keep `src/etch_vm.nim` (core-only), `src/etch_toolchain.nim` (core+bytecode), and the existing etch.nim CLI (tooling). Nim’s dead code elimination will drop everything not referenced when you build the bare VM.

**Pluggable Capabilities**

- Add `core/vm_features.nim` defining `FeatureKind = enum fkReplay, fkDebugger, fkProfiler, fkCffi, fkComptime, fkCompiler` plus `FeatureSet = object` storing requested capabilities; expose `proc hasFeature(feature: FeatureKind): bool`.
- Extend `vm.nim` to hold `RuntimeCapability` records (callbacks for hooks like `onInstruction`, `onBreakpoint`, `onSnapshot`, `onHeapChange`) registered through `vm.registerCapability(capability)`; keep the fast path free by wrapping callbacks with `when defined(hasDebugger)` or checking `FeatureSet` before dispatch.
- Move replay/debug/profiler logic behind their own modules (`capabilities/replay.nim`, etc.) that implement `proc attach*(vm: VirtualMachine)` to register hooks and hold feature-specific state; the VM never directly imports them, so removing the module from the build eliminates the feature cleanly.
- Define a `BytecodeProvider` interface in `bytecode/provider.nim` returning `BytecodeProgram`; the compiler implements it, but embedders can provide prebuilt bytecode or load from disk without pulling in the compiler.
- Introduce a tiny service locator (`RuntimeServices`) passed to optional modules so features can ask for logging, filesystem, or host bindings without creating new compile-time dependencies.

**Build Configuration**

- Add feature toggles to etch.nimble/config.nims: e.g., `switch("core_only", "-d:etchCoreOnly")`, `switch("with_debugger", "-d:etchDebugger")`; document them in `docs/internal/build-targets.md`.
- Update the justfile with recipes `just build-core`, `just build-toolchain`, `just build-cli`, and variants that pass the correct Nim defines; ensure CI runs each variant (core-only, toolchain, full) to catch missing guards.
- Modify `src/etch/cli/commands/*` to import optional code inside `when defined(etchCompiler)`/`when defined(etchDebugger)` blocks and emit helpful errors if a user invokes a disabled command.
- Allow disabling CLI frontend commands completely when building for the C apis.
- Provide pkg-config style outputs: produce `libetch_core.{a,dylib}` and `libetch_toolchain.{a,dylib}` targets so downstream users can link only what they need.
- Update index.md and `docs/architecture.md` with a section describing the feature matrix, default presets, and how to compose a custom build.

**Implementation Steps**

- Extract a `runtime` subpackage by moving the VM, heap, value definitions, and execution helpers under `src/etch/core/`; adjust imports in `vm_execution.nim`, `vm_host_function.nim`, and `etch/common/*` to reference the new paths.
- Create `BytecodeProgram`/`BytecodeLoader` interfaces (`src/etch/bytecode/program.nim`) and refactor `src/etch/bytecode/compiler.nim` plus `src/etch/compiler.nim` to implement them, ensuring the VM depends only on this interface.
- Introduce `core/features.nim` and thread `FeatureSet` through `VirtualMachine` creation (constructor parameter defaulting to `FeatureSet.default()`); gate existing replay/debugger/profiler allocations behind guards using this set.
- Relocate debugger/replay/profiler/dumper modules into `src/etch/capabilities/` and refactor them to expose `attach*(vm, cfg)` entry points; remove direct imports from `vm_execution.nim` and instead conditionally call `attachReplay(vm, cfg)` from the CLI/tooling layer when the feature is available.
- Adjust main.nim and each command to check compile-time flags before referencing missing modules; for example, wrap `import ../interpreter/vm_replay` and the `--record` flow in `when defined(etchReplay)`.
- Add documentation/tests: create `docs/modular-build.md`, extend debugging.md/performance.md with feature requirements, and add smoke tests that build and run `just go examples/basic_math.etch` under `ETCH_PROFILE=core` (core-only) and `ETCH_PROFILE=full` (all features) to guarantee both configurations remain healthy.

  🎨 Etch Language Presentation Guide

  "Define once, Etch forever."

  ---
  📊 Slide Deck Structure (30-40 slides)

  OPENING SLIDES (3-4 slides)

  Slide 1: Title Slide

  Content:
  ETCH
  Define once, Etch forever.

  A safety-first programming language
  that proves correctness at compile-time

  [Your Name]

  Layout: Centered, minimalist, bold typography
  Fun Image: A literal etching/engraving tool carving into stone, or a chip being etched in a semiconductor fab (since code is "etched" once and runs forever)
  Color scheme: Dark background with bright accent color (maybe teal/cyan for tech vibe)

  ---
  Slide 2: The Problem

  Content:
  What keeps you up at night?

  ❌ Division by zero crashes in production
  ❌ Integer overflow vulnerabilities
  ❌ Uninitialized variable bugs
  ❌ Array bounds errors
  ❌ "It works on my machine"

  Layout: Big X marks in red, bullet list
  Fun Image: A programmer in bed with worried thought bubbles showing crash logs and error messages, or a "this is fine" dog meme in a burning server room
  Speaker Notes: These are real production bugs that cost time, money, and reputation

  ---
  Slide 3: The Etch Promise

  Content:
  What if the compiler could PROVE your code is safe?

  ✓ No division by zero - PROVEN
  ✓ No integer overflow - PROVEN
  ✓ No uninitialized variables - PROVEN
  ✓ No array out of bounds - PROVEN
  ✓ Dead code eliminated - AUTOMATICALLY

  Not at runtime. At compile-time.

  Layout: Green checkmarks, dramatic text reveal
  Fun Image: A judge's gavel with "PROOF" stamped on code, or a mathematical theorem being written on a blackboard
  Speaker Notes: This isn't runtime checking. This is mathematical proof.

  ---
  LANGUAGE DESIGN (5-6 slides)

  Slide 4: Hello, Etch!

  Content:
  fn main() -> void {
    print("Hello, World!");
  }

  Simple. Clean. Familiar.
  C-like syntax you already know.

  Layout: Large code block centered, tagline below
  Fun Image: Split screen - complex "Hello World" in other languages vs Etch's clean version
  Speaker Notes: We didn't reinvent syntax. We focused on safety and features.

  ---
  Slide 5: The Safety Prover in Action

  Content:
  fn main() -> void {
      let divisor: int = rand(10, 5);    // Range: [5, 10]
      let result: int = 100 / divisor;   // ✓ Safe!
      print(result);
  }

  The compiler tracks value ranges
  Proven non-zero = proven safe

  vs.

  fn main() -> void {
      let divisor: int = rand(5, 0);     // Range: [0, 5]
      let result: int = 100 / divisor;   // ❌ COMPILE ERROR
  }

  Layout: Side-by-side comparison, traffic light colors (green/red)
  Fun Image: A detective with magnifying glass examining code ranges, or a traffic light
  Speaker Notes: This is compile-time range analysis. The prover tracks every value.

  ---
  Slide 6: Intelligent Dead Code Elimination

  Content:
  fn main() -> void {
      let x: int = rand(100, 50);  // Range: [50, 100]

      if x > 200 {
          print(10 / 0);  // No error! Unreachable!
      }

      if x > 75 {
          print("Possible!");  // May execute
      }
  }

  The prover knows x ∈ [50, 100]
  - First branch impossible → eliminated
  - Division by zero in dead code → no error
  - Second branch possible → kept

  Layout: Code with annotations showing range analysis, flowchart overlay
  Fun Image: A garbage truck collecting dead code, or branches of a tree being pruned
  Speaker Notes: This isn't just optimization - it affects safety analysis too

  ---
  Slide 7: Type System & Inference

  Content:
  fn main() -> void {
      let x: int = 42;           // Explicit type
      let y = 3.14;              // Inferred as float
      let name = "Etch";         // Inferred as string
      let numbers = [1, 2, 3];   // Inferred as array[int]
  }

  Strong static typing
  Smart type inference
  No surprises

  Layout: Code with type annotations shown visually with arrows/labels
  Fun Image: A sorting hat (Harry Potter style) putting types in buckets, or a Sherlock Holmes figure "inferring" types
  Speaker Notes: Types are checked at compile-time but you don't always have to write them

  ---
  Slide 8: Arrays with Safety Guarantees

  Content:
  fn main() -> void {
      let numbers: array[int] = [10, 20, 30, 40, 50];

      let count: int = #numbers;              // Length operator
      let middle: int = numbers[count / 2];   // Bounds checked
      let slice: array[int] = numbers[1:4];   // Safe slicing
  }

  Compile-time bounds checking when possible
  Runtime checks when necessary
  Clear error messages

  Layout: Visual representation of array with indices, bounds checking illustration
  Fun Image: A bouncer checking IDs at a club entrance (array bounds checking), or guard rails on a cliff edge
  Speaker Notes: The prover eliminates bounds checks it can prove safe

  ---
  THE KILLER FEATURE: COMPTIME (6-7 slides)

  Slide 9: Compile-Time Execution

  Content:
  What if you could run code
  DURING COMPILATION?

  Not macros. Not templates.
  Actual code execution.

  Layout: Big bold statement, dramatic reveal
  Fun Image: A DeLorean time machine labeled "COMPTIME" going back to compilation, or Inception-style "code within code"
  Speaker Notes: This is the most powerful feature of Etch

  ---
  Slide 10: Comptime Basics

  Content:
  fn square(x: int) -> int {
      return x * x;
  }

  fn main() -> void {
      // Computed at COMPILE-TIME, stored as constant
      let result: int = comptime(square(8));
      print(result);  // Just prints 64, no function call!
  }

  Zero runtime overhead
  - Function call happens during compilation
  - Result baked into binary as constant
  - No function call at runtime

  Layout: Split timeline showing compile-time vs runtime execution
  Fun Image: A factory assembly line where computation happens at the factory (compile-time) vs at the store (runtime)
  Speaker Notes: The bytecode just has LoadK 64, not a function call

  ---
  Slide 11: Comptime Blocks

  Content:
  fn main() -> void {
      comptime {
          print("Hello from the compiler!");
          print("This runs during build");

          var i: int = 0;
          while i < 5 {
              print(i);
              i = i + 1;
          }
      }

      print("Hello from runtime!");
  }

  Compile-time output:
  Hello from the compiler!
  This runs during build
  0 1 2 3 4

  Runtime output:
  Hello from runtime!

  Layout: Split output showing what happens when vs annotated code
  Fun Image: A construction site (compile-time) vs a finished building (runtime)
  Speaker Notes: Loops, conditionals, everything works in comptime blocks

  ---
  Slide 12: File Embedding

  Content:
  fn main() -> void {
      // File read at COMPILE-TIME
      let config: string = comptime(readFile("config.txt"));
      print(config);  // File embedded in binary!
  }

  Embed files directly into your binary
  - No runtime I/O
  - No missing file errors
  - Single executable deployment

  Layout: Flowchart showing file → compiler → binary
  Fun Image: A vacuum sealing machine sucking files into a package, or a 3D printer embedding files in binary
  Speaker Notes: Config files, templates, shaders - all embedded at compile-time

  ---
  Slide 13: Code Injection

  Content:
  fn main() -> void {
      comptime {
          let env: string = readFile(".env");

          if env == "production" {
              inject("LOG_LEVEL", "int", 0);
              inject("DEBUG", "int", 0);
          } else {
              inject("LOG_LEVEL", "int", 2);
              inject("DEBUG", "int", 1);
          }
      }

      if DEBUG == 1 {  // Variable was injected!
          print("Debug mode enabled");
      }
  }

  Metaprogramming without macros
  Generate code based on compile-time conditions

  Layout: Animation showing injection process, code appearing at runtime scope
  Fun Image: A syringe injecting code (code injection), or a vending machine dispensing variables
  Speaker Notes: Variables injected at compile-time are available at runtime

  ---
  Slide 14: Comptime Use Cases

  Content:
  🎯 Build-time configuration
     Different builds from same source

  🎯 Resource embedding
     Templates, shaders, assets in binary

  🎯 Lookup tables
     Compute once, use forever

  🎯 Feature flags
     Conditional compilation

  🎯 Version information
     Embed git commit, build date

  🎯 Platform-specific code
     One codebase, many targets

  Layout: Icon grid with examples
  Fun Image: A Swiss Army knife with different tools (versatility), or a transformer robot (one thing, many forms)
  Speaker Notes: This replaces build scripts, preprocessor macros, and resource bundlers

  ---
  COMPILER ARCHITECTURE (6-7 slides)

  Slide 15: The Compilation Pipeline

  Content:
  Source Code
      ↓
  🔍 Parser → AST
      ↓
  🎯 Type Checker → Typed AST
      ↓
  ✓ Safety Prover → Proven AST
      ↓
  ⚡ Comptime Executor → Modified AST
      ↓
  🔧 Bytecode Generator → Bytecode
      ↓
  💾 Cache → Disk
      ↓
  🚀 VM Executor → Output

  Layout: Vertical flowchart with icons
  Fun Image: An assembly line in a car factory, each station represents a compilation stage
  Speaker Notes: Multi-stage pipeline, each stage adds guarantees

  ---
  Slide 16: The Prover System

  Content:
  Range Analysis
  ├── Track value ranges through program
  ├── Propagate through operations
  │   ├── [5,10] + [2,3] = [7,13]
  │   ├── [5,10] * [2,3] = [10,30]
  │   └── if x < 7 then x ∈ [5,6]
  └── Prove safety properties
      ├── Division: denominator ∉ {0}
      ├── Overflow: result within type bounds
      └── Array: index within [0, length)

  Initialization Analysis
  ├── Track initialization state
  ├── Flow-sensitive analysis
  └── Ensure all paths initialize

  Dead Code Analysis
  ├── Identify impossible branches
  └── Eliminate unreachable code

  Layout: Tree diagram showing analysis types, examples
  Fun Image: A neural network or interconnected neurons (symbolic of analysis), or a CSI lab analyzing evidence
  Speaker Notes: This is the brain of Etch - mathematical proof of safety

  ---
  Slide 17: Why Nim?

  Content:
  Nim: The secret weapon 🎯

  ✨ Compiles to C → Portable, Fast
  ✨ Python-like syntax → Productive
  ✨ Metaprogramming → Powerful DSLs
  ✨ Zero-cost abstractions → Efficient
  ✨ Great standard library → Batteries included
  ✨ Excellent macros → AST manipulation

  Building a compiler in Nim:
  ├── Clean AST representation
  ├── Pattern matching for transformations
  ├── Easy FFI to C libraries
  └── Fast compile times

  Layout: Benefits list with code snippet examples
  Fun Image: Nim language logo with superpowers (cape, lightning), or a craftsman with perfect tools
  Speaker Notes: Nim is perfect for systems programming and compiler development

  ---
  Slide 18: Register-Based VM Architecture

  Content:
  RegVM: Register-Based Virtual Machine

  Stack VM:              Register VM:
  ┌─────────┐           ┌──────────────┐
  │ PUSH 5  │           │ LoadK r0, 5  │
  │ PUSH 3  │           │ LoadK r1, 3  │
  │ ADD     │           │ Add r2, r0,r1│
  │ POP r0  │           │              │
  └─────────┘           └──────────────┘

  Advantages:
  ✓ Fewer instructions
  ✓ Better for optimization
  ✓ Closer to real hardware
  ✓ Easier to debug

  Layout: Side-by-side comparison with visual stack vs registers
  Fun Image: Stack of plates (stack machine) vs a toolbelt with tools (register machine), or CPU registers diagram
  Speaker Notes: Most VMs are stack-based, but registers are more efficient

  ---
  Slide 19: Bytecode Instructions

  Content:
  Instruction Categories:

  📦 Load/Store
     LoadK, Move, GetGlobal, SetGlobal

  🧮 Arithmetic
     Add, Sub, Mul, Div, Mod, Neg

  🔢 Comparison
     Eq, Lt, Le, Gt, Ge, Ne

  🎯 Control Flow
     Jump, JumpIf, JumpIfNot, TestJump

  📞 Function Calls
     Call, Return

  🎨 Fused Instructions (optimization!)
     AddAdd, MulAdd, LoadAddStore
     EqStore, LtStore, IncTest

  Layout: Categories with icons and examples
  Fun Image: Instruction set as LEGO blocks that combine, or a periodic table of bytecode instructions
  Speaker Notes: Fused instructions combine multiple operations for performance

  ---
  Slide 20: Bytecode Caching

  Content:
  First run:
  Source → Parse → Typecheck → Prove → Compile → Cache
  (Takes ~100ms)

  Subsequent runs:
  Source Hash Check → Load Cached Bytecode → Run
  (Takes ~10ms)

  10x faster subsequent runs! 🚀

  Cache invalidation:
  ✓ Source file changed → recompile
  ✓ Source hash mismatch → recompile
  ✓ Bytecode version changed → recompile

  Layout: Timeline comparison showing time savings
  Fun Image: A cache memory chip, or a speedy delivery truck using cached shortcuts on a map
  Speaker Notes: Makes development iteration lightning fast

  ---
  Slide 21: VSCode Debugger Integration

  Content:
  Full DAP (Debug Adapter Protocol) Support

  Features:
  🐛 Set breakpoints in .etch files
  ⏯️  Step through execution (step in/out/over)
  👁️  Watch expressions
  📊 View call stack
  🔍 Inspect variables
  📌 Conditional breakpoints

  Debug Server:
  ├── TCP/IP communication
  ├── DAP protocol implementation
  └── Integrated with RegVM

  Layout: Screenshot of VSCode with Etch code being debugged (if you have one), or mockup
  Fun Image: A detective solving a mystery (debugging), VSCode interface screenshots
  Speaker Notes: Professional-grade debugging experience, not just print statements!

  ---
  BYTECODE VS C BACKEND (4-5 slides)

  Slide 22: Two Execution Modes

  Content:
             Etch Compiler
                  ↓
          ┌───────┴────────┐
          ↓                ↓
     Bytecode VM      C Backend
          ↓                ↓
     Development      Production

  Fast iteration  | Maximum performance
  Debug support   | Native code
  Portable        | OS optimizations
  Caching         | Standalone binary

  Layout: Branching diagram showing two paths
  Fun Image: A fork in the road, or a shapeshifter transforming between two forms
  Speaker Notes: One language, two execution strategies for different needs

  ---
  Slide 23: Bytecode VM - Fast Development

  Content:
  Perfect for development iteration:

  ✓ Instant execution (cached)
  ✓ Full debugger support
  ✓ Portable bytecode
  ✓ No C compiler needed
  ✓ Rich runtime errors

  When to use:
  🔧 During development
  🧪 Running tests
  📝 Scripting tasks
  🔄 Rapid prototyping

  Layout: Benefits list with use case icons
  Fun Image: A race car (fast iteration) or a playground (experimentation)
  Speaker Notes: This is your daily driver during development

  ---
  Slide 24: C Backend - Maximum Performance

  Content:
  Compiles to clean, readable C code:

  ✓ Native machine code via gcc/clang
  ✓ Platform optimizations (-O3)
  ✓ System calling conventions
  ✓ FFI to C libraries seamless
  ✓ Standalone executable

  When to use:
  🚀 Production deployments
  ⚡ Performance critical code
  📦 Distribution to users
  🔌 Integrating with C libraries

  Layout: Benefits list with icons, maybe C code snippet
  Fun Image: A rocket launching (production ready), or a finely tuned race car engine
  Speaker Notes: Compiles to human-readable C, then to machine code

  ---
  Slide 25: C Backend Code Generation

  Content:
  // Etch source
  fn fibonacci(n: int) -> int {
      if n <= 1 {
          return n;
      }
      return fibonacci(n - 1) + fibonacci(n - 2);
  }

  // Generated C code
  int64_t etch_fibonacci(int64_t n) {
      if (n <= 1) {
          return n;
      }
      return etch_fibonacci(n - 1) + etch_fibonacci(n - 2);
  }

  Clean, readable C you could write by hand

  Layout: Side-by-side code comparison
  Fun Image: A translator converting between languages, or a DNA sequence transcription diagram
  Speaker Notes: The C backend generates idiomatic C code, not garbage

  ---
  PERFORMANCE (3-4 slides)

  Slide 26: Performance Philosophy

  Content:
  Safety doesn't mean slow!

  Etch's approach:
  1️⃣ Prove safety at compile-time
  2️⃣ Eliminate runtime checks
  3️⃣ Generate efficient bytecode/C
  4️⃣ Leverage compiler optimizations

  Result: Safety with zero overhead*

  *Overhead eliminated by proofs

  Layout: Numbered steps, dramatic statement
  Fun Image: A safe being transported at high speed, or a race car with airbags
  Speaker Notes: Safety overhead only when the compiler can't prove safety

  ---
  Slide 27: Benchmark Results

  Content:
  Performance Benchmarks
  (vs Python 3)

  Arithmetic Operations:  15-30x faster
  Array Operations:       20-40x faster
  Function Calls:         10-25x faster
  Math Intensive:         25-50x faster

  C Backend vs VM:
  Simple operations:      1-2x faster (C)
  Math intensive:         2-5x faster (C)

  Layout: Bar charts or performance comparison table
  Fun Image: Speedometer, race between cars (Etch vs Python), or performance graphs
  Speaker Notes: These are real benchmarks from the test suite

  ---
  Slide 28: Optimization Opportunities

  Content:
  Current Optimizations:
  ✓ Constant folding
  ✓ Dead code elimination
  ✓ Range-based check elimination
  ✓ Fused instructions
  ✓ Bytecode caching

  Future Optimizations (from CLAUDE.md):
  🎯 Loop optimizations
  🎯 Common subexpression elimination
  🎯 Type-specialized instructions
  🎯 Function inlining
  🎯 Register coalescing

  The compiler keeps getting faster!

  Layout: Two-column layout with current/future
  Fun Image: A rocket with "Version 1.0" vs "Version 2.0" with more boosters
  Speaker Notes: There's a detailed optimization roadmap in the repo

  ---
  THE VIBE & DEVELOPER EXPERIENCE (4-5 slides)

  Slide 29: The Etch Developer Experience

  Content:
  What does it feel like to write Etch?

  🎯 Simple syntax - no cognitive overhead
  💡 Helpful errors - compiler guides you
  ⚡ Fast iteration - instant feedback
  🔒 Confidence - proven correctness
  🐛 Easy debugging - professional tools
  📚 Clear docs - examples everywhere

  "It feels like writing Python,
   but knowing it won't crash in production"

  Layout: Quote style with developer testimonials
  Fun Image: A happy developer at a computer with thumbs up, zen garden (peaceful development)
  Speaker Notes: This is about the feeling of using Etch daily

  ---
  Slide 30: Error Messages That Help

  Content:
  Other languages:
  ❌ "Segmentation fault (core dumped)"
  ❌ "undefined is not a function"
  ❌ "NullPointerException"

  Etch:
  ✓ "Division by zero detected at line 42:
     Variable 'divisor' has range [0, 5]
     Denominator must be proven non-zero

     Hint: Consider using 'rand(5, 1)' instead"

  Clear. Actionable. Educational.

  Layout: Before/after comparison, color-coded
  Fun Image: Confused person looking at cryptic errors vs. enlightened person with clear guidance
  Speaker Notes: Error messages teach you to write better code

  ---
  Slide 31: The Vibe Coding Part

  Content:
  Etch encourages exploration:

  🧪 Try comptime experiments
     What can you compute at build time?

  🔬 Play with the prover
     How clever is the range analysis?

  🎨 Generate code dynamically
     Can you metaprogram this?

  🚀 Profile both backends
     When does C win? When is VM enough?

  It's a playground for ideas
  with production-ready output.

  Layout: Experimentation theme, playful icons
  Fun Image: A scientist in a lab with cool experiments, or an artist painting with code
  Speaker Notes: Etch makes compiler technology accessible and fun

  ---
  Slide 32: Workflow Example

  Content:
  Typical development cycle:

  1. Write code
     └─ Syntax highlighting in VSCode

  2. Run with VM
     └─ Instant feedback (cached)

  3. Debug with breakpoints
     └─ Step through, inspect values

  4. Prove safety
     └─ Fix any safety errors

  5. Test thoroughly
     └─ VM execution with test runner

  6. Deploy with C backend
     └─ Maximum performance

  All from one codebase!

  Layout: Workflow diagram with steps
  Fun Image: A production pipeline or assembly line showing each stage
  Speaker Notes: The workflow is optimized for productivity

  ---
  COMPARISONS & POSITIONING (3-4 slides)

  Slide 33: Language Comparisons

  Content:
                  Etch    Rust    Zig     Python  Go
  Safety          ✅      ✅      ⚠️      ❌      ⚠️
  Proofs          ✅      ❌      ❌      ❌      ❌
  Comptime        ✅      ❌      ✅      ❌      ❌
  Simple Syntax   ✅      ⚠️      ✅      ✅      ✅
  Fast Compile    ✅      ❌      ✅      ✅      ✅
  No GC           ✅      ✅      ✅      ❌      ❌
  Easy to Learn   ✅      ❌      ⚠️      ✅      ✅

  Etch = Safety + Simplicity + Speed

  Layout: Comparison table/matrix
  Fun Image: Venn diagram showing Etch at intersection of safety, simplicity, and performance
  Speaker Notes: Etch finds a unique niche in the language ecosystem

  ---
  Slide 34: Who Is Etch For?

  Content:
  Perfect for:

  🎯 Systems programmers wanting safety without Rust complexity
  🎯 Python developers needing performance without sacrificing clarity
  🎯 Game developers needing predictable behavior
  🎯 Embedded systems with safety requirements
  🎯 Compiler enthusiasts exploring PL design
  🎯 Educators teaching program verification

  Not for:
  ❌ Existing large codebases (greenfield projects)
  ❌ Massive teams (small-medium teams thrive)

  Layout: Two column (perfect for / not for)
  Fun Image: Different avatars representing different developer types
  Speaker Notes: Etch has a sweet spot in the ecosystem

  ---
  Slide 35: What Makes Etch Different

  Content:
  Etch's Unique Value:

  1. Proofs, not checks
     We mathematically prove safety

  2. Comptime execution
     Not macros - actual code execution

  3. Two backends, one language
     VM for dev, C for prod

  4. Built by developers, for developers
     Solving real problems, not academic exercises

  5. It's FUN!
     Compiler technology shouldn't be scary

  Layout: Numbered differentiation points
  Fun Image: A unique fingerprint, or a standout character in a crowd
  Speaker Notes: These four things together make Etch unique

  ---
  FUTURE & COMMUNITY (3-4 slides)

  Slide 36: Current Status

  Content:
  🎯 Language Status: Active Development

  What works:
  ✅ Core language features
  ✅ Safety prover with range analysis
  ✅ Compile-time execution
  ✅ Bytecode VM with caching
  ✅ C code generation backend
  ✅ VSCode debugger integration
  ✅ Test framework
  ✅ Performance benchmarking

  Production ready? Almost!
  Great for: Experiments, small projects, learning

  Layout: Checklist with status indicators
  Fun Image: A progress bar almost complete, or a building under construction (almost done)
  Speaker Notes: Etch is usable today but still evolving

  ---
  Slide 37: Roadmap (from CLAUDE.md)

  Content:
  Optimization Roadmap:

  Phase 1: Bytecode optimization
  ├─ Re-enable optimizer
  ├─ Integrate prover data
  └─ Enhanced constant folding

  Phase 2: Instruction improvements
  ├─ Jump target tables
  ├─ ARG instructions
  └─ Reversed operations

  Phase 3: Advanced optimizations
  ├─ Peephole optimization
  ├─ Common subexpression elimination
  ├─ Loop optimizations

  Phase 4: Type-aware optimization
  ├─ Static type specialization
  └─ Function inlining

  Layout: Roadmap with phases
  Fun Image: A roadmap/highway with milestones, or a mountain climbing path
  Speaker Notes: There's a detailed improvement plan in the repo

  ---
  Slide 38: Contributing

  Content:
  Get Involved!

  📚 Read the docs
     docs/ has detailed guides

  🧪 Try the examples
     examples/ has 100+ test cases

  🐛 Find bugs
     Report issues on GitHub

  💡 Suggest features
     What safety proofs would you like?

  🔧 Submit PRs
     Especially for optimization passes!

  📝 Write tutorials
     Help others learn Etch

  Layout: Call-to-action with icons
  Fun Image: A group of people collaborating, open source community illustration
  Speaker Notes: The project is open source and welcomes contributors

  ---
  CLOSING SLIDES (4-5 slides)

  Slide 39: Live Demo Setup

  Content:
  Let's see Etch in action! 🎬

  Demo 1: Safety proofs catching bugs
  Demo 2: Comptime execution
  Demo 3: Debugger in VSCode
  Demo 4: Performance comparison
  Demo 5: C backend code generation

  Layout: Demo checklist
  Fun Image: A stage with spotlight (demo time!), or "LIVE" broadcast sign
  Speaker Notes: Have terminal and VSCode ready

  ---
  Slide 40: Demo 1 - Safety Proofs

  Content:
  // Show division by zero prevention
  fn main() -> void {
      let x: int = rand(5, 0);  // [0, 5]
      let result: int = 10 / x; // ❌ COMPILE ERROR!
  }

  // Fix it
  fn main() -> void {
      let x: int = rand(5, 1);  // [1, 5]
      let result: int = 10 / x; // ✅ Compiles!
  }

  // Show overflow detection
  fn main() -> void {
      let big: int = 9223372036854775800;
      let overflow: int = big + 1000; // ❌ Overflow!
  }

  Layout: Live coding screen
  Speaker Notes: Type this live and show the compiler errors

  ---
  Slide 41: Demo 2 - Comptime

  Content:
  // Embed file at compile time
  fn main() -> void {
      let readme: string = comptime(readFile("README.md"));
      print(readme);
  }

  // Generate code
  fn main() -> void {
      comptime {
          inject("VERSION", "int", 42);
          inject("BUILD_DATE", "string", "2024");
      }
      print(VERSION);
      print(BUILD_DATE);
  }

  Layout: Live terminal showing compilation output vs runtime
  Speaker Notes: Show the comptime output during build

  ---
  Slide 42: Demo 3 - Performance

  Content:
  # Run VM version
  $ time etch --run math_intensive.etch
  Real: 45ms

  # Run C backend
  $ time etch --run c math_intensive.etch
  Real: 15ms

  # Compare with Python
  $ time python3 math_intensive.py
  Real: 1200ms

  C backend: 3x faster than VM
            80x faster than Python!

  Layout: Terminal output side-by-side
  Fun Image: Race finish line with timing results
  Speaker Notes: Run these benchmarks live

  ---
  Slide 43: Key Takeaways

  Content:
  Remember:

  1️⃣ Safety through mathematical proofs
     Not runtime checks - compile-time proofs

  2️⃣ Zero-cost abstractions
     Comptime moves work to compilation

  3️⃣ Two backends, one language
     VM for dev, C for production

  4️⃣ Clean, simple syntax
     No complexity tax for safety

  5️⃣ Built in Nim
     The right tool for the job

  Define once, Etch forever.

  Layout: Numbered summary points
  Fun Image: Return to the etching/engraving image from slide 1 (callback)
  Speaker Notes: Reinforce the core messages

  ---
  Slide 44: Resources & Links

  Content:
  🔗 Links:

  GitHub: github.com/kunitoki/etch
  Documentation: [your docs link]
  Examples: examples/ in repo
  Improvement Plan: CLAUDE.md

  Try it:
  $ git clone https://github.com/kunitoki/etch
  $ cd etch
  $ just build
  $ etch --run examples/simple_hello.etch

  Join the conversation!

  Layout: Links and quick start commands
  Fun Image: QR code to GitHub repo
  Speaker Notes: Have QR code for easy mobile access

  ---
  Slide 45: Questions?

  Content:
  Questions?

  "Define once, Etch forever."

  Thank you! 🚀

  Layout: Centered, minimal
  Fun Image: Question marks, or an open door (inviting questions)
  Speaker Notes: Leave extra time for Q&A

  ---
  🎨 Overall Design Recommendations

  Color Palette

  - Primary: Deep blue/teal (#0A192F or similar - tech vibe)
  - Accent: Cyan/bright blue (#64FFDA - for highlighting)
  - Success: Green (#00FF00 - for proven safe)
  - Error: Red (#FF6B6B - for safety violations)
  - Code blocks: Dark theme (VS Code Dark+)

  Typography

  - Headers: Bold, modern sans-serif (Inter, Roboto, or Fira Code)
  - Body: Clean sans-serif (same as headers)
  - Code: Monospace (Fira Code, JetBrains Mono)

  Visual Themes Throughout

  - Use etching/engraving imagery as recurring motif
  - Use proof/mathematics imagery (theorems, QED symbols)
  - Use time travel for comptime features
  - Use safety imagery (shields, locks, safety equipment)
  - Use speed imagery (rockets, race cars) for performance

  Animation Suggestions

  - Code appears line by line
  - Error messages slide in from side
  - Comparison slides use fade transitions
  - Build highlighted checkmarks for feature lists
  - Use syntax highlighting that animates in

  Pro Tips

  1. Live code as much as possible - don't just show screenshots
  2. Keep slides visual - less text, more diagrams
  3. Use color coding - green for safe, red for unsafe
  4. Show actual errors - demonstrate the compiler helping you
  5. Have backup demos - record them in case live demo fails
  6. Print slide numbers - helps with questions later

  🎬 Presentation Flow Tips

  Timing (45-60 min talk):
  - Opening: 5 min
  - Language Design: 10 min
  - Comptime Deep Dive: 10 min
  - Architecture: 10 min
  - Performance & Vibe: 8 min
  - Demos: 10 min
  - Q&A: 10+ min

  Energy Management:
  - Start strong with the safety problem
  - Build excitement with comptime features
  - Show technical depth with architecture
  - Peak energy at live demos
  - End with community invitation
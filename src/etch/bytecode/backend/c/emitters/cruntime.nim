proc emitCRuntime*(gen: var CGenerator) =
  ## Emit the C runtime header with EtchV type implementation
  const runtimeHeader = slurp "../runtime.h"
  gen.emit(runtimeHeader)

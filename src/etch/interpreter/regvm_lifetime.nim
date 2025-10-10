# regvm_lifetime.nim
# Variable lifetime tracking for VM and debugger
# Tracks when variables are defined, used, and go out of scope

import std/[tables, algorithm, strutils]


type
  # Lifetime range for a variable - PC range where it's alive
  LifetimeRange* = object
    varName*: string
    register*: uint8
    startPC*: int      # PC where variable is first defined
    endPC*: int        # PC where variable goes out of scope
    defPC*: int        # PC where variable is actually assigned (may differ from startPC)
    lastUsePC*: int    # PC of last use (for optimization)
    scopeLevel*: int   # Nesting level for scopes

  # Scope information during compilation
  ScopeInfo* = object
    level*: int
    startPC*: int
    variables*: seq[string]  # Variables defined in this scope
    parentScope*: ref ScopeInfo

  # Lifetime tracker maintains all variable lifetimes
  LifetimeTracker* = object
    ranges*: seq[LifetimeRange]
    currentScope*: ref ScopeInfo
    scopeLevel*: int
    variableMap*: Table[string, seq[LifetimeRange]]  # Variable name to all its lifetime ranges
    pcToVariables*: Table[int, seq[string]]  # PC to variables alive at that point
    destructorPoints*: Table[int, seq[string]]  # PC to variables that need destructors

  # Function-specific lifetime data for embedding in bytecode
  FunctionLifetimeData* = object
    functionName*: string
    ranges*: seq[LifetimeRange]
    pcToVariables*: Table[int, seq[string]]
    destructorPoints*: Table[int, seq[string]]

  # Variable state at a specific PC (for debugger)
  VariableState* = object
    name*: string
    register*: uint8
    isDefined*: bool  # Has been assigned
    value*: pointer   # Optional cached value

proc newLifetimeTracker*(): LifetimeTracker =
  result = LifetimeTracker(
    ranges: @[],
    currentScope: nil,
    scopeLevel: 0,
    variableMap: initTable[string, seq[LifetimeRange]](),
    pcToVariables: initTable[int, seq[string]](),
    destructorPoints: initTable[int, seq[string]]()
  )

proc enterScope*(tracker: var LifetimeTracker, pc: int) =
  ## Enter a new scope (block, function, loop, etc.)
  inc tracker.scopeLevel
  var newScope = new(ScopeInfo)
  newScope.level = tracker.scopeLevel
  newScope.startPC = pc
  newScope.variables = @[]
  newScope.parentScope = tracker.currentScope
  tracker.currentScope = newScope

proc exitScope*(tracker: var LifetimeTracker, pc: int) =
  ## Exit current scope and mark end of lifetime for all variables in scope
  if tracker.currentScope == nil:
    return

  # Mark end of lifetime for all variables in this scope
  for varName in tracker.currentScope.variables:
    if tracker.variableMap.hasKey(varName):
      for i in countdown(tracker.variableMap[varName].high, 0):
        var lifetime = addr tracker.variableMap[varName][i]
        if lifetime.endPC == -1:  # Still open
          lifetime.endPC = pc
          # Add destructor point for this variable
          if not tracker.destructorPoints.hasKey(pc):
            tracker.destructorPoints[pc] = @[]
          tracker.destructorPoints[pc].add(varName)
          break

  # Move to parent scope
  tracker.currentScope = tracker.currentScope.parentScope
  dec tracker.scopeLevel

proc declareVariable*(tracker: var LifetimeTracker, name: string, register: uint8, pc: int) =
  ## Declare a new variable (allocates register but not yet defined)
  var lifetime = LifetimeRange(
    varName: name,
    register: register,
    startPC: pc,
    endPC: -1,  # Unknown until scope exit
    defPC: -1,  # Not yet defined
    lastUsePC: -1,
    scopeLevel: tracker.scopeLevel
  )

  tracker.ranges.add(lifetime)

  if not tracker.variableMap.hasKey(name):
    tracker.variableMap[name] = @[]
  tracker.variableMap[name].add(lifetime)

  if tracker.currentScope != nil:
    tracker.currentScope.variables.add(name)

proc defineVariable*(tracker: var LifetimeTracker, name: string, pc: int) =
  ## Mark variable as defined (actually assigned a value)
  if tracker.variableMap.hasKey(name):
    # Find the most recent lifetime range for this variable
    for i in countdown(tracker.variableMap[name].high, 0):
      var lifetime = addr tracker.variableMap[name][i]
      if lifetime.defPC == -1 and lifetime.startPC <= pc:
        lifetime.defPC = pc
        break

proc useVariable*(tracker: var LifetimeTracker, name: string, pc: int) =
  ## Mark variable as used at this PC
  if tracker.variableMap.hasKey(name):
    for i in countdown(tracker.variableMap[name].high, 0):
      var lifetime = addr tracker.variableMap[name][i]
      if lifetime.startPC <= pc and (lifetime.endPC == -1 or lifetime.endPC >= pc):
        lifetime.lastUsePC = pc
        break

proc buildPCMap*(tracker: var LifetimeTracker) =
  ## Build PC to variables mapping for efficient lookup during execution
  tracker.pcToVariables.clear()

  for lifetime in tracker.ranges:
    for pc in lifetime.startPC..lifetime.endPC:
      if not tracker.pcToVariables.hasKey(pc):
        tracker.pcToVariables[pc] = @[]
      if lifetime.varName notin tracker.pcToVariables[pc]:
        tracker.pcToVariables[pc].add(lifetime.varName)

proc getActiveVariables*(tracker: LifetimeTracker, pc: int): seq[VariableState] =
  ## Get all variables that are in scope at the given PC
  result = @[]

  for lifetime in tracker.ranges:
    if lifetime.startPC <= pc and (lifetime.endPC == -1 or lifetime.endPC >= pc):
      result.add(VariableState(
        name: lifetime.varName,
        register: lifetime.register,
        isDefined: lifetime.defPC != -1 and lifetime.defPC <= pc,
        value: nil
      ))

proc getDefinedVariables*(tracker: LifetimeTracker, pc: int): seq[VariableState] =
  ## Get only variables that have been defined (assigned) by the given PC
  result = @[]

  for lifetime in tracker.ranges:
    if lifetime.startPC <= pc and (lifetime.endPC == -1 or lifetime.endPC >= pc):
      if lifetime.defPC != -1 and lifetime.defPC <= pc:
        result.add(VariableState(
          name: lifetime.varName,
          register: lifetime.register,
          isDefined: true,
          value: nil
        ))

proc needsDestructor*(tracker: LifetimeTracker, pc: int): seq[string] =
  ## Get variables that need destructors at this PC
  if tracker.destructorPoints.hasKey(pc):
    return tracker.destructorPoints[pc]
  return @[]

proc getVariableRegister*(tracker: LifetimeTracker, name: string, pc: int): int =
  ## Get the register for a variable at a specific PC, or -1 if not in scope
  if tracker.variableMap.hasKey(name):
    for i in countdown(tracker.variableMap[name].high, 0):
      let lifetime = tracker.variableMap[name][i]
      if lifetime.startPC <= pc and (lifetime.endPC == -1 or lifetime.endPC >= pc):
        return int(lifetime.register)
  return -1

proc canReuseRegister*(tracker: LifetimeTracker, register: uint8, pc: int): bool =
  ## Check if a register can be safely reused at this PC
  for lifetime in tracker.ranges:
    if lifetime.register == register:
      # Register is in use if we're within its lifetime range
      if lifetime.startPC <= pc and (lifetime.endPC == -1 or lifetime.endPC >= pc):
        return false
  return true

proc optimizeLifetimes*(tracker: var LifetimeTracker) =
  ## Optimize lifetime ranges based on actual usage
  for i in 0..<tracker.ranges.len:
    var lifetime = addr tracker.ranges[i]
    # If variable is never used after definition, we can shrink its lifetime
    if lifetime.lastUsePC != -1 and lifetime.lastUsePC < lifetime.endPC:
      # Add early destructor point
      let earlyDestructPC = lifetime.lastUsePC + 1
      if not tracker.destructorPoints.hasKey(earlyDestructPC):
        tracker.destructorPoints[earlyDestructPC] = @[]
      tracker.destructorPoints[earlyDestructPC].add(lifetime.varName)
      # Update end PC to last use
      lifetime.endPC = lifetime.lastUsePC

proc exportFunctionData*(tracker: LifetimeTracker, functionName: string): FunctionLifetimeData =
  ## Export lifetime data for a specific function
  result = FunctionLifetimeData(
    functionName: functionName,
    ranges: tracker.ranges,
    pcToVariables: tracker.pcToVariables,
    destructorPoints: tracker.destructorPoints
  )

proc dumpLifetimes*(tracker: LifetimeTracker) =
  ## Debug: dump all lifetime ranges
  echo "=== Variable Lifetimes ==="
  for name, ranges in tracker.variableMap:
    for r in ranges:
      echo "  ", name, ": R", r.register,
           " [", r.startPC, "..", r.endPC, "]",
           " def@", r.defPC,
           " lastUse@", r.lastUsePC,
           " scope=", r.scopeLevel

  echo "=== Destructor Points ==="
  var sortedPCs: seq[int] = @[]
  for pc in tracker.destructorPoints.keys:
    sortedPCs.add(pc)
  sortedPCs.sort()
  for pc in sortedPCs:
    echo "  PC ", pc, ": ", tracker.destructorPoints[pc].join(", ")
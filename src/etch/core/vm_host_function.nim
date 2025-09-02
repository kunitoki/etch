# vm_host_function.nim
# Host function support for VirtualMachine

import std/tables
import ./[vm, vm_types]


# Forward declaration of C API types (avoid circular imports)
type
  EtchContext* = ptr EtchContextObj
  EtchValueObj* = object
    value*: V

  ## Opaque context object for C API
  EtchContextObj* = object
    discard

  # Host function info (matches the C API structure)
  HostFunctionInfo* = object
    callback*: proc(ctx: EtchContext,
                    args: ptr ptr EtchValueObj,
                    numArgs: cint,
                    userData: pointer): ptr EtchValueObj {.cdecl.}
    userData*: pointer


proc getHostFunctionCache(vm: VirtualMachine): ptr Table[uint16, HostFunctionInfo] =
  ## Lazily create or fetch the per-VM host function cache.
  var cache = cast[ptr Table[uint16, HostFunctionInfo]](vm.hostFunctionCache)
  if cache == nil:
    cache = cast[ptr Table[uint16, HostFunctionInfo]](alloc0(sizeof(Table[uint16, HostFunctionInfo])))
    cache[] = initTable[uint16, HostFunctionInfo]()
    vm.hostFunctionCache = cast[pointer](cache)
  cache


# Handle host function calls (embedded VM context)
proc callHostFunction*(vm: VirtualMachine, funcIdx: uint16, funcInfo: FunctionInfo, funcReg: uint8, args: openArray[V]): bool =
  ## Call a host function from the context's host function table
  ## Returns true if function was called successfully

  # Check if host functions and context are available
  if vm.hostFunctions == nil or vm.context == nil:
    return false

  # Cast the hostFunctions pointer to the proper type
  let hostFunctionsTable = cast[ptr Table[string, HostFunctionInfo]](vm.hostFunctions)

  let cache = vm.getHostFunctionCache()

  proc invoke(hostFuncInfo: HostFunctionInfo, args: openArray[V]): bool =
    if hostFuncInfo.callback == nil:
      return false
    let context = cast[EtchContext](vm.context)

    if args.len == 0:
      try:
        let res = hostFuncInfo.callback(context, nil, 0, hostFuncInfo.userData)
        if res != nil:
          setReg(vm, funcReg, res[].value)
          dealloc(res)
        else:
          setReg(vm, funcReg, makeNil())
      except:
        setReg(vm, funcReg, makeNil())
      return true

    # Allocate a single block for all argument values to reduce malloc overhead
    let argsBlock = cast[ptr UncheckedArray[EtchValueObj]](alloc0(sizeof(EtchValueObj) * args.len))
    var hostArgs = newSeq[ptr EtchValueObj](args.len)

    for i in 0..<args.len:
      argsBlock[i].value = args[i]
      hostArgs[i] = addr argsBlock[i]

    try:
      let argsPtr = cast[ptr ptr EtchValueObj](hostArgs[0].addr)
      let res = hostFuncInfo.callback(context, argsPtr, cint(args.len), hostFuncInfo.userData)
      if res != nil:
        setReg(vm, funcReg, res[].value)
        dealloc(res)  # Free the result value
      else:
        setReg(vm, funcReg, makeNil())
    except:
      setReg(vm, funcReg, makeNil())
    finally:
      dealloc(argsBlock)
    true

  var lookup = ""
  if funcInfo.baseName.len > 0:
    lookup = funcInfo.baseName
  else:
    lookup = funcInfo.name

  # Quick path: cached result (including negative cache)
  if cache[].hasKey(funcIdx):
    let cached = cache[][funcIdx]
    return invoke(cached, args)

  var hostFuncInfo: HostFunctionInfo
  if hostFunctionsTable[].hasKey(lookup):
    hostFuncInfo = hostFunctionsTable[][lookup]
  elif funcInfo.name.len > 0 and lookup != funcInfo.name and hostFunctionsTable[].hasKey(funcInfo.name):
    hostFuncInfo = hostFunctionsTable[][funcInfo.name]
  else:
    return false

  cache[][funcIdx] = hostFuncInfo

  invoke(hostFuncInfo, args)

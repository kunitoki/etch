# libffi.nim

when defined(macosx):
  {.pragma: ffiLibrary, header: "<ffi.h>".}
elif defined(linux):
  {.pragma: ffiLibrary, header: "<ffi/ffi.h>".}
else:
  {.pragma: ffiLibrary, dynlib: "libffi.so".}

when defined(windows):
  when defined(x86):
    type
      TABI* {.size: sizeof(cint).} = enum
        FIRST_ABI, SYSV, STDCALL
    const DEFAULT_ABI* = SYSV
  elif defined(amd64):
    type
      TABI* {.size: sizeof(cint).} = enum
        FIRST_ABI, WIN64
    const DEFAULT_ABI* = WIN64
else:
  type
    TABI* {.size: sizeof(cint).} = enum
      FIRST_ABI, SYSV, UNIX64
  when defined(i386):
    const DEFAULT_ABI* = SYSV
  else:
    const DEFAULT_ABI* = UNIX64

type
  Arg* = int
  SArg* = int

  Type* = object
    size*: int
    alignment*: uint16
    typ*: uint16
    elements*: ptr ptr Type

  Status* {.size: sizeof(cint).} = enum
    OK, BAD_TYPEDEF, BAD_ABI

  TypeKind* = cuint

  TCif* {.pure, final.} = object
    abi*: TABI
    nargs*: cuint
    argTypes*: ptr ptr Type
    rtype*: ptr Type
    bytes*: cuint
    flags*: cuint

  Raw* = object
    sint*: SArg

const
  tkVOID* = 0
  tkINT* = 1
  tkFLOAT* = 2
  tkDOUBLE* = 3
  tkLONGDOUBLE* = 4
  tkUINT8* = 5
  tkSINT8* = 6
  tkUINT16* = 7
  tkSINT16* = 8
  tkUINT32* = 9
  tkSINT32* = 10
  tkUINT64* = 11
  tkSINT64* = 12
  tkSTRUCT* = 13
  tkPOINTER* = 14
  tkLAST = tkPOINTER
  tkSMALL_STRUCT_1B* = (tkLAST + 1)
  tkSMALL_STRUCT_2B* = (tkLAST + 2)
  tkSMALL_STRUCT_4B* = (tkLAST + 3)

var
  type_void* {.importc: "ffi_type_void", ffiLibrary.}: Type
  type_uint8* {.importc: "ffi_type_uint8", ffiLibrary.}: Type
  type_sint8* {.importc: "ffi_type_sint8", ffiLibrary.}: Type
  type_uint16* {.importc: "ffi_type_uint16", ffiLibrary.}: Type
  type_sint16* {.importc: "ffi_type_sint16", ffiLibrary.}: Type
  type_uint32* {.importc: "ffi_type_uint32", ffiLibrary.}: Type
  type_sint32* {.importc: "ffi_type_sint32", ffiLibrary.}: Type
  type_uint64* {.importc: "ffi_type_uint64", ffiLibrary.}: Type
  type_sint64* {.importc: "ffi_type_sint64", ffiLibrary.}: Type
  type_float* {.importc: "ffi_type_float", ffiLibrary.}: Type
  type_double* {.importc: "ffi_type_double", ffiLibrary.}: Type
  type_pointer* {.importc: "ffi_type_pointer", ffiLibrary.}: Type

proc raw_call*(cif: var TCif; fn: proc () {.cdecl.}; rvalue: pointer; avalue: ptr Raw) {.cdecl, importc: "ffi_raw_call", ffiLibrary.}
proc ptrarray_to_raw*(cif: var TCif; args: ptr pointer; raw: ptr Raw) {.cdecl, importc: "ffi_ptrarray_to_raw", ffiLibrary.}
proc raw_to_ptrarray*(cif: var TCif; raw: ptr Raw; args: ptr pointer) {.cdecl, importc: "ffi_raw_to_ptrarray", ffiLibrary.}
proc raw_size*(cif: var TCif): int {.cdecl, importc: "ffi_raw_size", ffiLibrary.}
proc prep_cif*(cif: var TCif; abi: TABI; nargs: cuint; rtype: ptr Type; atypes: ptr ptr Type): Status {.cdecl, importc: "ffi_prep_cif", ffiLibrary.}
proc call*(cif: var TCif; fn: proc () {.cdecl.}; rvalue: pointer; avalue: ptr pointer) {.cdecl, importc: "ffi_call", ffiLibrary.}

# the same with an easier interface:
type
  ParamList* = array[0..100, ptr Type]
  ArgList* = array[0..100, pointer]

proc prep_cif*(cif: var TCif; abi: TABI; nargs: cuint; rtype: ptr Type; atypes: ParamList): Status {.cdecl, importc: "ffi_prep_cif", ffiLibrary.}
proc call*(cif: var TCif; fn, rvalue: pointer; avalue: ArgList) {.cdecl, importc: "ffi_call", ffiLibrary.}

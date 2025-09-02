proc emitTestTag(gen: var CGenerator, instr: Instruction, pc: int) =
  let a = instr.a
  let tag = instr.b
  let vkind = VKind(tag)
  case vkind
  of vkNil:
    gen.emit(&"if (r[{a}].kind == ETCH_VK_NIL) goto L{pc + 2};  // TestTag Nil - skip Jmp if match")
  of vkBool:
    gen.emit(&"if (r[{a}].kind == ETCH_VK_BOOL) goto L{pc + 2};  // TestTag Bool - skip Jmp if match")
  of vkChar:
    gen.emit(&"if (r[{a}].kind == ETCH_VK_CHAR) goto L{pc + 2};  // TestTag Char - skip Jmp if match")
  of vkInt:
    gen.emit(&"if (r[{a}].kind == ETCH_VK_INT) goto L{pc + 2};  // TestTag Int - skip Jmp if match")
  of vkFloat:
    gen.emit(&"if (r[{a}].kind == ETCH_VK_FLOAT) goto L{pc + 2};  // TestTag Float - skip Jmp if match")
  of vkString:
    gen.emit(&"if (r[{a}].kind == ETCH_VK_STRING) goto L{pc + 2};  // TestTag String - skip Jmp if match")
  of vkArray:
    gen.emit(&"if (r[{a}].kind == ETCH_VK_ARRAY) goto L{pc + 2};  // TestTag Array - skip Jmp if match")
  of vkTable:
    gen.emit(&"if (r[{a}].kind == ETCH_VK_TABLE) goto L{pc + 2};  // TestTag Table - skip Jmp if match")
  of vkSome:
    gen.emit(&"if (r[{a}].kind == ETCH_VK_SOME) goto L{pc + 2};  // TestTag Some - skip Jmp if match")
  of vkNone:
    gen.emit(&"if (r[{a}].kind == ETCH_VK_NONE) goto L{pc + 2};  // TestTag None - skip Jmp if match")
  of vkOk:
    gen.emit(&"if (r[{a}].kind == ETCH_VK_OK) goto L{pc + 2};  // TestTag Ok - skip Jmp if match")
  of vkErr:
    gen.emit(&"if (r[{a}].kind == ETCH_VK_ERR) goto L{pc + 2};  // TestTag Error - skip Jmp if match")
  of vkRef:
    gen.emit(&"if (r[{a}].kind == ETCH_VK_REF) goto L{pc + 2};  // TestTag Ref - skip Jmp if match")
  of vkClosure:
    gen.emit(&"if (r[{a}].kind == ETCH_VK_CLOSURE) goto L{pc + 2};  // TestTag Closure - skip Jmp if match")
  of vkWeak:
    gen.emit(&"if (r[{a}].kind == ETCH_VK_WEAK) goto L{pc + 2};  // TestTag Weak - skip Jmp if match")
  of vkCoroutine:
    gen.emit(&"if (r[{a}].kind == ETCH_VK_COROUTINE) goto L{pc + 2};  // TestTag Coroutine - skip Jmp if match")
  of vkChannel:
    gen.emit(&"if (r[{a}].kind == ETCH_VK_CHANNEL) goto L{pc + 2};  // TestTag Channel - skip Jmp if match")
  of vkTypeDesc:
    gen.emit(&"if (r[{a}].kind == ETCH_VK_TYPEDESC) goto L{pc + 2};  // TestTag TypeDesc - skip Jmp if match")
  of vkEnum:
    gen.emit(&"if (r[{a}].kind == ETCH_VK_ENUM) goto L{pc + 2};  // TestTag Enum - skip Jmp if match")

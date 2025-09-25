# types.nim
# Common types used across the Etch implementation

type
  Pos* = object
    line*, col*: int
    filename*: string

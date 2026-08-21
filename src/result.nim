type
  ResultKind* = enum
    rkOk
    rkErr

  Result*[T] = object
    case kind*: ResultKind
    of rkOk:
      value*: T
    of rkErr:
      error*: string

proc Success*[T](value: T): Result[T] =
  Result[T](kind: rkOk, value: value)

proc Failure*[T](error: string): Result[T] =
  Result[T](kind: rkErr, error: error)

proc isSuccess*[T](r: Result[T]): bool =
  r.kind == rkOk

proc isFailure*[T](r: Result[T]): bool =
  r.kind == rkErr

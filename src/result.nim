import std/options

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

  Unit* = object ## Placeholder for results that carry no value.

proc Success*[T](value: T): Result[T] =
  Result[T](kind: rkOk, value: value)

proc Success*(): Result[Unit] =
  Success(Unit())

proc Failure*[T](error: string): Result[T] =
  Result[T](kind: rkErr, error: error)

proc isSuccess*[T](r: Result[T]): bool =
  r.kind == rkOk

proc isFailure*[T](r: Result[T]): bool =
  r.kind == rkErr

proc map*[T, U](r: Result[T], f: proc(x: T): U): Result[U] =
  ## Transforms the success value; passes failures through unchanged.
  if isSuccess(r):
    Success(f(r.value))
  else:
    Failure[U](r.error)

proc flatMap*[T, U](r: Result[T], f: proc(x: T): Result[U]): Result[U] =
  ## Chains a fallible operation; passes failures through unchanged.
  if isSuccess(r):
    f(r.value)
  else:
    Failure[U](r.error)

proc successOr*[T](o: Option[T], error: string): Result[Unit] =
  ## Converts an Option to a Result[Unit]: Some(_) becomes Success, None becomes Failure.
  if o.isSome:
    Success()
  else:
    Failure[Unit](error)

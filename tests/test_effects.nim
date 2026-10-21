## Unit tests for performing effects: nothing happens until they are performed,
## and then in the order they were queued, no further than the first that fails.

import std/[os, unittest]
import effects
import results

suite "performing effects":
  let directory = getTempDir() / "nimver-effects-unit"

  setup:
    removeDir(directory)
    createDir(directory)

  test "building an effect changes nothing":
    let path = directory / "never.txt"
    discard writeTo(path, "x")
    check not fileExists(path)

  test "effects run in the order they were queued":
    let path = directory / "file.txt"
    check perform(@[writeTo(path, "first"), writeTo(path, "second")]).isOk
    check readFile(path) == "second"

  test "the first failure stops the rest, and is what is reported":
    let after = directory / "after.txt"
    let failing: Effect = proc(): Result[void, string] =
      err("boom")
    let performed = perform(@[failing, writeTo(after, "x")])
    check performed.error == "boom"
    check not fileExists(after)

  test "a write the filesystem refuses fails instead of raising":
    check perform(@[writeTo(directory / "missing" / "x.txt", "x")]).isErr

## Unit tests for the commit message parser: what shapes it accepts, and what
## it reports for the ones it rejects.

import std/[unittest]
import commitparser
import result

suite "valid commit messages":
  test "only header, no scope, not breaking":
    let message = "feat: this is a test"
    let parsed = parseCommitMessage(message)
    check isSuccess(parsed) == true
    check parsed.value.commitType == "feat"
    check parsed.value.breaking == false
    check parsed.value.scope == ""
    check parsed.value.subject == "this is a test"
  test "only header, no scope, breaking":
    let message = "feat!: this is a test"
    let parsed = parseCommitMessage(message)
    check isSuccess(parsed) == true
    check parsed.value.commitType == "feat"
    check parsed.value.breaking == true
    check parsed.value.scope == ""
    check parsed.value.subject == "this is a test"
  test "only header, with scope, not breaking":
    let message = "feat(scope): this is a test"
    let parsed = parseCommitMessage(message)
    check isSuccess(parsed) == true
    check parsed.value.commitType == "feat"
    check parsed.value.breaking == false
    check parsed.value.scope == "scope"
    check parsed.value.subject == "this is a test"
  test "only header, with scope, breaking":
    let message = "feat(scope)!: this is a test"
    let parsed = parseCommitMessage(message)
    check isSuccess(parsed) == true
    check parsed.value.commitType == "feat"
    check parsed.value.breaking == true
    check parsed.value.scope == "scope"
    check parsed.value.subject == "this is a test"
  test "breaking in body with BREAKING CHANGE":
    let message = """feat: this is a test
    some body

    BREAKING CHANGE: foobar"""
    let parsed = parseCommitMessage(message)
    check isSuccess(parsed) == true
    check parsed.value.commitType == "feat"
    check parsed.value.breaking == true
    check parsed.value.scope == ""
    check parsed.value.subject == "this is a test"
  test "breaking in body with BREAKING-CHANGE":
    let message = """feat: this is a test
    some body

    BREAKING-CHANGE: foobar"""
    let parsed = parseCommitMessage(message)
    check isSuccess(parsed) == true
    check parsed.value.commitType == "feat"
    check parsed.value.breaking == true
    check parsed.value.scope == ""
    check parsed.value.subject == "this is a test"

suite "invalid commit messages":
  test "empty message":
    let message = ""
    let parsed = parseCommitMessage(message)
    check isSuccess(parsed) == false
  test "invalid characters in commit type":
    let message = "fe!at!: this is a test"
    let parsed = parseCommitMessage(message)
    check isSuccess(parsed) == false
  test "unclosed scope":
    let message = "feat(scope!: this is a test"
    let parsed = parseCommitMessage(message)
    check isSuccess(parsed) == false
  test "empty subject":
    let message = "feat: "
    let parsed = parseCommitMessage(message)
    check isSuccess(parsed) == false
  test "empty scope":
    let message = "feat(): this is a test"
    let parsed = parseCommitMessage(message)
    check isSuccess(parsed) == false
  test "wrong ! placement":
    let message = "feat!(scope): this is a test"
    let parsed = parseCommitMessage(message)
    check isSuccess(parsed) == false
  test "no colon":
    let message = "feat(scope) this is a test"
    let parsed = parseCommitMessage(message)
    check isSuccess(parsed) == false
  test "space in scope":
    let message = "feat(my scope): this is a test"
    let parsed = parseCommitMessage(message)
    check isSuccess(parsed) == false
  test "space in type":
    let message = "feat ure(scope): this is a test"
    let parsed = parseCommitMessage(message)
    check isSuccess(parsed) == false

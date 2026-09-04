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

suite "type and scope spelling":
  test "uppercase and digits in type and scope":
    let parsed = parseCommitMessage("Fix(API2): this is a test")
    check isSuccess(parsed) == true
    check parsed.value.commitType == "Fix"
    check parsed.value.scope == "API2"
  test "a subsystem path as the type":
    let parsed = parseCommitMessage("net/http: rework the dialer")
    check isSuccess(parsed) == true
    check parsed.value.commitType == "net/http"
    check parsed.value.scope == ""
    check parsed.value.subject == "rework the dialer"
  test "underscores and dashes":
    let parsed = parseCommitMessage("feat_x(api-v2): this is a test")
    check isSuccess(parsed) == true
    check parsed.value.commitType == "feat_x"
    check parsed.value.scope == "api-v2"
  test "dots and commas in scope, but not in type":
    let parsed = parseCommitMessage("feat(web,cli.core)!: this is a test")
    check isSuccess(parsed) == true
    check parsed.value.scope == "web,cli.core"
    check parsed.value.breaking == true
    check isSuccess(parseCommitMessage("fe.at: this is a test")) == false
  test "the subject keeps every colon after the first":
    let parsed = parseCommitMessage("docs: note: mind the gap")
    check isSuccess(parsed) == true
    check parsed.value.commitType == "docs"
    check parsed.value.subject == "note: mind the gap"

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
  test "still no parens inside a scope":
    check isSuccess(parseCommitMessage("feat(a(b)): this is a test")) == false
  test "still no bang inside a scope":
    check isSuccess(parseCommitMessage("feat(sc!ope): this is a test")) == false

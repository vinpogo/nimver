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

suite "the Release-Note footer":
  test "a commit without one has no note":
    check parseCommitMessage("feat: a").value.releaseNote == ""

  test "the footer text is taken verbatim":
    let message = """feat(parser): tighten the scope regex

Release-Note: Scopes may now contain digits, slashes and dots."""
    let parsed = parseCommitMessage(message)
    check isSuccess(parsed) == true
    check parsed.value.subject == "tighten the scope regex"
    check parsed.value.releaseNote == "Scopes may now contain digits, slashes and dots."

  test "the key is matched without regard to case":
    check parseCommitMessage("feat: a\n\nrelease-note: hi").value.releaseNote == "hi"
    check parseCommitMessage("feat: a\n\nRELEASE-NOTE: hi").value.releaseNote == "hi"

  test "an empty footer is no note":
    check parseCommitMessage("feat: a\n\nRelease-Note:").value.releaseNote == ""
    check parseCommitMessage("feat: a\n\nRelease-Note:   ").value.releaseNote == ""

  test "the first footer wins":
    check parseCommitMessage("feat: a\n\nRelease-Note: first\nRelease-Note: second").value.releaseNote ==
      "first"

  test "a wrapped footer runs on until a blank line":
    let message = """feat: a

Release-Note: UPPERCASE, /, -, _ and numbers are now
supported for commit types, scopes can additionally
contain . and , .

Some trailing paragraph that is not part of the note."""
    check parseCommitMessage(message).value.releaseNote ==
      "UPPERCASE, /, -, _ and numbers are now supported for commit types, " &
      "scopes can additionally contain . and , ."

  test "a wrapped footer stops at the next footer":
    let message = """feat: a

Release-Note: the note
wraps once
Co-Authored-By: someone <someone@example.com>"""
    check parseCommitMessage(message).value.releaseNote == "the note wraps once"

  test "a wrapped footer stops at a breaking footer":
    let message = """feat!: a

Release-Note: the note
wraps once
BREAKING CHANGE: everything moved"""
    let parsed = parseCommitMessage(message)
    check parsed.value.breaking == true
    check parsed.value.releaseNote == "the note wraps once"

  test "the value may start on the line after the key":
    let message = """feat: a

Release-Note:
the whole note is down here"""
    check parseCommitMessage(message).value.releaseNote == "the whole note is down here"

  test "a body paragraph before the footer is not swallowed":
    let message = """feat: a

Some body explaining the change.

Release-Note: the note"""
    check parseCommitMessage(message).value.releaseNote == "the note"

  test "a header that reads like the footer is still a header":
    let parsed = parseCommitMessage("release-note: mind the gap")
    check isSuccess(parsed) == true
    check parsed.value.commitType == "release-note"
    check parsed.value.subject == "mind the gap"
    check parsed.value.releaseNote == ""

  test "a note survives alongside a breaking footer":
    let message = """feat!: a

BREAKING CHANGE: everything moved
Release-Note: Everything moved; see the migration guide."""
    let parsed = parseCommitMessage(message)
    check parsed.value.breaking == true
    check parsed.value.releaseNote == "Everything moved; see the migration guide."

suite "the breaking footer":
  test "the footer's text is kept, wrapping and all":
    let message = """feat: a

BREAKING CHANGE: the config key moved, and every
repository has to be re-initialised."""
    let parsed = parseCommitMessage(message)
    check parsed.value.breaking == true
    check parsed.value.breakingNote ==
      "the config key moved, and every repository has to be re-initialised."

  test "the dashed spelling reads the same":
    check parseCommitMessage("feat: a\n\nBREAKING-CHANGE: moved").value.breakingNote ==
      "moved"

  test "a bang alone breaks without a note":
    let parsed = parseCommitMessage("feat!: a")
    check parsed.value.breaking == true
    check parsed.value.breakingNote == ""

  test "the key is only read uppercase, as the spec asks":
    let parsed = parseCommitMessage("feat: a\n\nbreaking change: a prose sentence")
    check parsed.value.breaking == false
    check parsed.value.breakingNote == ""

  test "the header is not scanned for footers":
    # `BREAKING-CHANGE` is a well-formed type, so without this the header would
    # announce a break as a side effect of being read twice.
    let parsed = parseCommitMessage("BREAKING-CHANGE: a")
    check isSuccess(parsed) == true
    check parsed.value.commitType == "BREAKING-CHANGE"
    check parsed.value.breaking == false

  test "both footers can be read from one message":
    let message = """feat!: a

Release-Note: Everything moved.
BREAKING CHANGE: the config key moved."""
    let parsed = parseCommitMessage(message)
    check parsed.value.releaseNote == "Everything moved."
    check parsed.value.breakingNote == "the config key moved."

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

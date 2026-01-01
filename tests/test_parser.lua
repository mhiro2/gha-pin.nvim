local MiniTest = require("mini.test")
local expect = MiniTest.expect

local parser = require("gha-pin.parser")

local T = MiniTest.new_set()

local SHA1 = "0123456789abcdef0123456789abcdef01234567"
local SHA2 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

T["parse_lines: extracts owner/repo@sha40"] = function()
  local lines = {
    "jobs:",
    "  test:",
    "    steps:",
    ("    - uses: actions/checkout@%s"):format(SHA1),
  }

  local refs = parser.parse_lines(lines)
  expect.equality(#refs, 1)
  expect.equality(refs[1].owner, "actions")
  expect.equality(refs[1].repo, "checkout")
  expect.equality(refs[1].path, nil)
  expect.equality(refs[1].sha, SHA1)
end

T["parse_lines: supports quoted uses"] = function()
  local lines = {
    ('    - uses: "actions/checkout@%s"'):format(SHA1),
  }

  local refs = parser.parse_lines(lines)
  expect.equality(#refs, 1)
  expect.equality(refs[1].owner, "actions")
  expect.equality(refs[1].repo, "checkout")
  expect.equality(refs[1].sha, SHA1)
end

T["parse_lines: supports single-quoted uses"] = function()
  local lines = {
    ("    - uses: 'actions/checkout@%s'"):format(SHA1),
  }

  local refs = parser.parse_lines(lines)
  expect.equality(#refs, 1)
  expect.equality(refs[1].owner, "actions")
  expect.equality(refs[1].repo, "checkout")
  expect.equality(refs[1].sha, SHA1)
end

T["parse_lines: extracts owner/repo/path@sha40"] = function()
  local lines = {
    ("      uses: my-org/my-repo/some/action@%s"):format(SHA2),
  }

  local refs = parser.parse_lines(lines)
  expect.equality(#refs, 1)
  expect.equality(refs[1].owner, "my-org")
  expect.equality(refs[1].repo, "my-repo")
  expect.equality(refs[1].path, "some/action")
  expect.equality(refs[1].sha, SHA2)
end

T["parse_lines: does not match abuses/reuses"] = function()
  local lines = {
    ("    - abuses: actions/checkout@%s"):format(SHA1),
    ("    - reuses: actions/checkout@%s"):format(SHA1),
    ("    - uses: actions/checkout@%s"):format(SHA1),
  }

  local refs = parser.parse_lines(lines)
  expect.equality(#refs, 1)
  expect.equality(refs[1].owner, "actions")
  expect.equality(refs[1].repo, "checkout")
  expect.equality(refs[1].sha, SHA1)
end

T["parse_lines: ignores non-sha patterns"] = function()
  local lines = {
    "    - uses: ./local",
    "    - uses: docker://alpine:3.19",
    "    - uses: actions/checkout@v4",
    ("    - uses: actions/checkout@%s # comment"):format(SHA1),
    "    - uses: actions/checkout@${{ github.sha }}",
  }

  local refs = parser.parse_lines(lines)
  expect.equality(#refs, 1)
  expect.equality(refs[1].owner, "actions")
  expect.equality(refs[1].repo, "checkout")
  expect.equality(refs[1].sha, SHA1)
end

return T

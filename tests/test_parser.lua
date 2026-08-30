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
    "runs:",
    "  using: composite",
    "  steps:",
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
    "runs:",
    "  using: composite",
    "  steps:",
    ("    - uses: 'actions/checkout@%s'"):format(SHA1),
  }

  local refs = parser.parse_lines(lines)
  expect.equality(#refs, 1)
  expect.equality(refs[1].owner, "actions")
  expect.equality(refs[1].repo, "checkout")
  expect.equality(refs[1].sha, SHA1)
end

T["parse_lines: supports exact quoted uses mapping keys"] = function()
  local lines = {
    '"jobs":',
    '  "test":',
    '    "steps":',
    ('    - "uses": actions/checkout@%s'):format(SHA1),
    ("    - 'uses': 'actions/setup-node@%s'"):format(SHA2),
  }

  local refs = parser.parse_lines(lines)
  expect.equality(#refs, 2)
  expect.equality(refs[1].repo, "checkout")
  expect.equality(refs[2].repo, "setup-node")
end

T["parse_lines: extracts owner/repo/path@sha40"] = function()
  local lines = {
    "jobs:",
    "  test:",
    "    steps:",
    "      - name: Run a repository action",
    ("        uses: my-org/my-repo/some/action@%s"):format(SHA2),
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
    "runs:",
    "  using: composite",
    "  steps:",
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

T["parse_lines: ignores commented out uses lines"] = function()
  local lines = {
    ("# uses: actions/checkout@%s"):format(SHA1),
    ("    # uses: actions/setup-node@%s"):format(SHA1),
    ("name: demo # uses: actions/upload-artifact@%s"):format(SHA1),
    "jobs:",
    "  test:",
    "    steps:",
    ("      - uses: actions/checkout@%s"):format(SHA1),
  }

  local refs = parser.parse_lines(lines)
  expect.equality(#refs, 1)
  expect.equality(refs[1].owner, "actions")
  expect.equality(refs[1].repo, "checkout")
  expect.equality(refs[1].sha, SHA1)
end

T["parse_lines: ignores non-sha patterns"] = function()
  local lines = {
    "jobs:",
    "  test:",
    "    steps:",
    "      - uses: ./local",
    "      - uses: docker://alpine:3.19",
    "      - uses: actions/checkout@v4",
    ("      - uses: actions/checkout@%s # comment"):format(SHA1),
    "      - uses: actions/checkout@${{ github.sha }}",
  }

  local refs = parser.parse_lines(lines)
  expect.equality(#refs, 1)
  expect.equality(refs[1].owner, "actions")
  expect.equality(refs[1].repo, "checkout")
  expect.equality(refs[1].sha, SHA1)
end

T["parse_lines: supports reusable workflow job uses"] = function()
  local lines = {
    "jobs:",
    "  call-workflow:",
    ("    uses: octo-org/example/.github/workflows/called.yml@%s"):format(SHA1),
  }

  local refs = parser.parse_lines(lines)
  expect.equality(#refs, 1)
  expect.equality(refs[1].owner, "octo-org")
  expect.equality(refs[1].repo, "example")
  expect.equality(refs[1].path, ".github/workflows/called.yml")
end

T["parse_lines: supports uses in a multi-line step mapping"] = function()
  local lines = {
    "jobs:",
    "  test:",
    "    steps:",
    "      - name: Checkout",
    ("        uses: actions/checkout@%s"):format(SHA1),
  }

  local refs = parser.parse_lines(lines)
  expect.equality(#refs, 1)
  expect.equality(refs[1].owner, "actions")
  expect.equality(refs[1].repo, "checkout")
end

T["parse_lines: excludes uses keys outside GitHub Action contexts"] = function()
  local lines = {
    "env:",
    ("  uses: actions/checkout@%s"):format(SHA1),
    ("env.uses: actions/setup-node@%s"):format(SHA1),
    "jobs:",
    "  test:",
    "    env:",
    ("      uses: actions/setup-node@%s"):format(SHA1),
    "    steps:",
    "      - env:",
    ("          uses: actions/upload-artifact@%s"):format(SHA1),
    "      - with:",
    ("          uses: actions/cache@%s"):format(SHA1),
  }

  expect.equality(#parser.parse_lines(lines), 0)
end

T["parse_lines: excludes uses-looking text in block scalars"] = function()
  local lines = {
    "jobs:",
    "  test:",
    "    steps:",
    "      - run: |",
    ("          uses: actions/checkout@%s"):format(SHA1),
    ("          - uses: actions/setup-node@%s"):format(SHA1),
    "      - run: >-",
    ("          uses: actions/cache@%s"):format(SHA1),
    '      - "run": |-',
    ("          uses: actions/download-artifact@%s"):format(SHA1),
    "      - run: !!str |",
    ("          uses: actions/cache@%s"):format(SHA1),
    "      - run: &script |",
    ("          - uses: actions/github-script@%s"):format(SHA1),
    "      - run: !custom >-",
    ("          uses: actions/labeler@%s"):format(SHA1),
    ("      - uses: actions/upload-artifact@%s"):format(SHA2),
  }

  local refs = parser.parse_lines(lines)
  expect.equality(#refs, 1)
  expect.equality(refs[1].repo, "upload-artifact")
end

T["parse_lines: excludes uses-looking text in multiline quoted and plain scalars"] = function()
  local lines = {
    "jobs:",
    "  test:",
    "    steps:",
    '      - run: "echo start',
    ("        uses: actions/checkout@%s"):format(SHA1),
    '        echo end"',
    "      - run: 'echo start",
    ("        - uses: actions/setup-node@%s"):format(SHA1),
    "        echo end'",
    "      - run: echo start",
    ("          uses: actions/cache@%s"):format(SHA1),
    "          echo end",
    ("      - uses: actions/upload-artifact@%s"):format(SHA2),
  }

  local refs = parser.parse_lines(lines)
  expect.equality(#refs, 1)
  expect.equality(refs[1].repo, "upload-artifact")
end

T["parse_lines: supports indentationless workflow and composite step sequences"] = function()
  local workflow = parser.parse_lines({
    "jobs:",
    "  test:",
    "    steps:",
    ("    - uses: actions/checkout@%s"):format(SHA1),
    "    - name: Set up Node",
    ('      "uses": actions/setup-node@%s'):format(SHA2),
  })
  expect.equality(#workflow, 2)
  expect.equality(workflow[1].repo, "checkout")
  expect.equality(workflow[2].repo, "setup-node")

  local composite = parser.parse_lines({
    "runs:",
    "  using: composite",
    "  steps:",
    ("  - 'uses': actions/cache@%s"):format(SHA1),
  })
  expect.equality(#composite, 1)
  expect.equality(composite[1].repo, "cache")
end

T["parse_lines: ignores unsupported flow mappings and nested flow values"] = function()
  local lines = {
    "jobs:",
    "  test:",
    ("    steps: [{ uses: actions/checkout@%s }]"):format(SHA1),
    "  other:",
    "    steps:",
    "      - env: {",
    ("          uses: actions/setup-node@%s"):format(SHA1),
    "        }",
    "  flow-step:",
    "    steps:",
    "      - {",
    '          note: "a } inside a quoted scalar",',
    ("          uses: actions/cache@%s"):format(SHA1),
    "        }",
  }

  expect.equality(#parser.parse_lines(lines), 0)
end

T["parse_lines: ignores isolated step fragments without an action context"] = function()
  expect.equality(#parser.parse_lines({
    ("- uses: actions/checkout@%s"):format(SHA1),
    ('  - "uses": actions/setup-node@%s'):format(SHA2),
  }), 0)
end

T["parse_lines: excludes non-key uses text and similar keys"] = function()
  local lines = {
    ("message: uses: actions/checkout@%s"):format(SHA1),
    ("foo-uses: actions/setup-node@%s"):format(SHA1),
    ("run: echo uses: actions/cache@%s"):format(SHA1),
    ("- 'uses: actions/upload-artifact@%s'"):format(SHA1),
    ("# uses: actions/checkout@%s"):format(SHA1),
  }

  expect.equality(#parser.parse_lines(lines), 0)
end

return T

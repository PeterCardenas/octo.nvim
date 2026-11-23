describe("GitHub HTTP transport", function()
  local gh
  local config
  local original_system
  local original_gh_cmd
  local original_gh_env
  local completions
  local calls
  local temporary_command

  local function install_system_stub()
    calls = {}
    completions = {}
    vim.system = function(argv, opts, callback)
      calls[#calls + 1] = { argv = argv, opts = opts }
      completions[#completions + 1] = callback
      return { kill = function() end }
    end
  end

  local function complete_system(index, result)
    completions[index](result)
  end

  local function make_fallback_command()
    temporary_command = vim.fn.tempname()
    vim.fn.writefile({
      "#!/bin/sh",
      'if [ "$1" = "auth" ] && [ "$2" = "status" ]; then echo "Logged in to github.com as octo-test"; exit 0; fi',
      'printf \'{"data":{"fallback":true}}\\n\'',
    }, temporary_command)
    vim.fn.setfperm(temporary_command, "rwx------")
    config.values.gh_cmd = temporary_command
  end

  before_each(function()
    gh = require "octo.gh"
    config = require "octo.config"
    original_system = vim.system
    original_gh_cmd = config.values.gh_cmd
    original_gh_env = config.values.gh_env
    temporary_command = nil
    install_system_stub()
  end)

  after_each(function()
    vim.system = original_system
    config.values.gh_cmd = original_gh_cmd
    config.values.gh_env = original_gh_env
    if temporary_command and vim.fn.filereadable(temporary_command) == 1 then
      vim.fn.delete(temporary_command)
    end
  end)

  it("resolves a fresh authenticated context when the active account changes", function()
    local hostname = "octo-account-switch.example"
    local contexts = {}
    gh.get_auth_context(hostname, function(context)
      contexts[#contexts + 1] = context
    end)
    complete_system(1, { code = 0, stdout = "account-a-token\n", stderr = "" })
    assert.is_true(vim.wait(100, function()
      return #contexts == 1
    end))

    gh.get_auth_context(hostname, function(context)
      contexts[#contexts + 1] = context
    end)
    assert.are.same({ original_gh_cmd, "auth", "token", "--hostname", hostname }, calls[2].argv)
    complete_system(2, { code = 0, stdout = "account-b-token\n", stderr = "" })
    assert.is_true(vim.wait(100, function()
      return #contexts == 2
    end))

    assert.are.same("account-a-token", contexts[1].token)
    assert.are.same("account-b-token", contexts[2].token)
    assert.are_not.same(contexts[1].fingerprint, contexts[2].fingerprint)
  end)

  it("uses the gh token once per host and sends GraphQL over compressed HTTP/2", function()
    if vim.fn.executable "curl" ~= 1 then
      pending "curl is unavailable"
      return
    end

    local hostname = "octo-http-test.example"
    local received = {}
    gh.api.graphql {
      query = require("octo.gh.queries").discussion_fast,
      fields = { owner = "octo", name = "repo", number = 7 },
      jq = ".",
      opts = {
        hostname = hostname,
        cb = function(output, stderr, status)
          received[#received + 1] = { output = output, stderr = stderr, status = status }
        end,
      },
    }

    assert.are.same({ original_gh_cmd, "auth", "token", "--hostname", hostname }, calls[1].argv)
    complete_system(1, { code = 0, stdout = "secret-test-token\n", stderr = "" })
    assert.is_true(vim.wait(100, function()
      return #calls == 2
    end))

    local curl_call = calls[2]
    assert.are.same("curl", curl_call.argv[1])
    assert.is_true(curl_call.opts.stdin:find("http2", 1, true) ~= nil)
    assert.is_true(curl_call.opts.stdin:find("compressed", 1, true) ~= nil)
    assert.are.same("-q", curl_call.argv[2])
    assert.is_true(curl_call.opts.stdin:find("secret-test-token", 1, true) ~= nil)
    assert.is_true(curl_call.opts.stdin:find("data-binary", 1, true) ~= nil)
    assert.is_nil(table.concat(curl_call.argv, " "):find("secret-test-token", 1, true))
    assert.is_nil(table.concat(curl_call.argv, " "):find("octo", 1, true))
    assert.is_true(curl_call.opts.stdin:find("https://octo-http-test.example/api/graphql", 1, true) ~= nil)
    assert.is_true(curl_call.opts.stdin:find("data%-binary = ", 1) ~= nil)
    assert.is_true(curl_call.opts.stdin:find("octo", 1, true) ~= nil)
    assert.is_true(curl_call.opts.stdin:find("number", 1, true) ~= nil)

    complete_system(2, {
      code = 0,
      stdout = vim.json.encode { data = { issue = { number = 7 } } },
      stderr = "",
    })
    assert.is_true(vim.wait(100, function()
      return #received == 1
    end))
    assert.are.same(0, received[1].status)
    assert.are.same({ data = { issue = { number = 7 } } }, vim.json.decode(received[1].output))

    gh.api.graphql {
      query = require("octo.gh.queries").discussion_fast,
      fields = { owner = "octo", name = "repo", number = 7 },
      jq = ".",
      opts = {
        hostname = hostname,
        cb = function(output, stderr, status)
          received[#received + 1] = { output = output, stderr = stderr, status = status }
        end,
      },
    }
    assert.are.same(3, #calls)
    complete_system(3, { code = 0, stdout = vim.json.encode { data = { viewer = { login = "octo-test" } } } })
    assert.is_true(vim.wait(100, function()
      return #received == 2
    end))
  end)

  it("uses the GitHub REST and GHES REST endpoint shapes", function()
    if vim.fn.executable "curl" ~= 1 then
      pending "curl is unavailable"
      return
    end

    local received = 0
    gh.api.get {
      "/repos/octo/repo/pulls/7",
      opts = {
        hostname = "github.com",
        cb = function(output, stderr, status)
          received = received + 1
          assert.are.same(0, status)
          assert.are.same({ ok = true }, vim.json.decode(output))
        end,
      },
    }
    complete_system(1, { code = 0, stdout = "github-token\n" })
    assert.is_true(vim.wait(100, function()
      return #calls == 2
    end))
    assert.is_true(calls[2].opts.stdin:find("https://api.github.com/repos/octo/repo/pulls/7", 1, true) ~= nil)
    complete_system(2, { code = 0, stdout = '{"ok":true}' })
    assert.is_true(vim.wait(100, function()
      return received == 1
    end))

    gh.api.get {
      "/repos/octo/repo/pulls/7",
      opts = {
        hostname = "octo-ghes.example",
        cb = function(output, stderr, status)
          received = received + 1
          assert.are.same(0, status)
        end,
      },
    }
    complete_system(3, { code = 0, stdout = "ghes-token\n" })
    assert.is_true(vim.wait(100, function()
      return #calls == 4
    end))
    assert.is_true(calls[4].opts.stdin:find("https://octo-ghes.example/api/v3/repos/octo/repo/pulls/7", 1, true) ~= nil)
    complete_system(4, { code = 0, stdout = '{"ok":true}' })
    assert.is_true(vim.wait(100, function()
      return received == 2
    end))
  end)

  it("keeps mutations and unlisted GraphQL reads out of the curl transport", function()
    make_fallback_command()
    local completed = 0
    for _, query in ipairs {
      "mutation { addComment(input: {}) { clientMutationId } }",
      "query { viewer { login } }",
    } do
      gh.api.graphql {
        query = query,
        fields = {},
        jq = ".",
        opts = {
          hostname = "octo-unlisted-query.example",
          cb = function()
            completed = completed + 1
          end,
        },
      }
    end

    assert.is_true(vim.wait(2000, function()
      return completed == 2
    end))
    assert.are.same(0, #calls)
  end)

  it("refreshes a rejected token once before falling back to gh", function()
    make_fallback_command()
    local loaded
    gh.api.graphql {
      query = require("octo.gh.queries").discussion_fast,
      fields = { owner = "octo", name = "repo", number = 7 },
      jq = ".",
      opts = {
        hostname = "octo-expired-token.example",
        cb = function(output)
          loaded = output
        end,
      },
    }
    complete_system(1, { code = 0, stdout = "expired-token" })
    assert.is_true(vim.wait(100, function()
      return #calls == 2
    end))
    complete_system(2, { code = 22, stdout = '{"message":"Bad credentials"}', stderr = "HTTP 401" })
    assert.is_true(vim.wait(100, function()
      return #calls == 3
    end))
    complete_system(3, { code = 0, stdout = "refreshed-token" })
    assert.is_true(vim.wait(100, function()
      return #calls == 4
    end))
    assert.is_true(calls[4].opts.stdin:find("refreshed-token", 1, true) ~= nil)
    complete_system(4, { code = 22, stdout = '{"message":"Bad credentials"}', stderr = "HTTP 401" })

    assert.is_true(vim.wait(2000, function()
      return loaded ~= nil
    end))
    assert.are.same('{"data":{"fallback":true}}', vim.trim(loaded))
    assert.are.same(4, #calls)
  end)

  it("uses gh_env for curl and refreshes cached tokens when gh_env changes", function()
    local hostname = "octo-proxy-env.example"
    local received = 0
    config.values.gh_env = { https_proxy = "http://proxy-one", OCTO_AUTH_CONTEXT = "one" }
    local function request()
      gh.api.graphql {
        query = require("octo.gh.queries").discussion_fast,
        fields = { owner = "octo", name = "repo", number = 7 },
        jq = ".",
        opts = {
          hostname = hostname,
          cb = function()
            received = received + 1
          end,
        },
      }
    end

    request()
    complete_system(1, { code = 0, stdout = "token-one" })
    assert.is_true(vim.wait(100, function()
      return #calls == 2
    end))
    assert.are.same("http://proxy-one", calls[2].opts.env.https_proxy)
    complete_system(2, { code = 0, stdout = '{"data":{}}' })

    config.values.gh_env = { https_proxy = "http://proxy-two", OCTO_AUTH_CONTEXT = "two" }
    request()
    assert.is_true(vim.wait(100, function()
      return #calls == 3
    end))
    assert.are.same("auth", calls[3].argv[2])
    complete_system(3, { code = 0, stdout = "token-two" })
    assert.is_true(vim.wait(100, function()
      return #calls == 4
    end))
    assert.are.same("http://proxy-two", calls[4].opts.env.https_proxy)
    assert.is_true(calls[4].opts.stdin:find("token-two", 1, true) ~= nil)
    complete_system(4, { code = 0, stdout = '{"data":{}}' })
    assert.is_true(vim.wait(100, function()
      return received == 2
    end))
  end)

  it("falls back to gh when token retrieval fails", function()
    make_fallback_command()
    local loaded
    gh.api.graphql {
      query = require("octo.gh.queries").discussion_fast,
      fields = { owner = "octo", name = "repo", number = 7 },
      jq = ".",
      opts = {
        hostname = "octo-auth-failure.example",
        cb = function(output, stderr, status)
          loaded = { output = output, stderr = stderr, status = status }
        end,
      },
    }
    complete_system(1, { code = 1, stdout = "", stderr = "token unavailable" })

    assert.is_true(vim.wait(2000, function()
      return loaded ~= nil
    end))
    assert.are.same('{"data":{"fallback":true}}', vim.trim(loaded.output))
  end)

  it("falls back to gh when curl encounters a transport error", function()
    make_fallback_command()
    local loaded
    gh.api.graphql {
      query = require("octo.gh.queries").discussion_fast,
      fields = { owner = "octo", name = "repo", number = 7 },
      jq = ".",
      opts = {
        hostname = "octo-transport-failure.example",
        cb = function(output, stderr, status)
          loaded = { output = output, stderr = stderr, status = status }
        end,
      },
    }
    complete_system(1, { code = 0, stdout = "test-token" })
    assert.is_true(vim.wait(100, function()
      return #calls == 2
    end))
    complete_system(2, { code = 7, stdout = "", stderr = "connection failed" })

    assert.is_true(vim.wait(2000, function()
      return loaded ~= nil
    end))
    assert.are.same('{"data":{"fallback":true}}', vim.trim(loaded.output))
  end)
end)

local config = require "octo.config"
local fragments = require "octo.gh.fragments"
local queries = require "octo.gh.queries"
local mutations = require "octo.gh.mutations"
local _, Job = pcall(require, "plenary.job")
local vim = vim

---@class octo.GH
---@field api octo.GH.api
---@field [string] {
---  [string]: (fun(opts?: { opts?: RunOpts, [string]: any }): string?, string?),
---}
local M = {}

local headers = {
  "application/vnd.github.v3+json",
  "application/vnd.github.squirrel-girl-preview+json",
  "application/vnd.github.comfort-fade-preview+json",
  "application/vnd.github.bane-preview+json",
}

---@type table<string, string|integer>
local env_vars = {
  PATH = vim.env["PATH"],
  GH_CONFIG_DIR = vim.env["GH_CONFIG_DIR"],
  GITHUB_TOKEN = vim.env["GITHUB_TOKEN"],
  XDG_CONFIG_HOME = vim.env["XDG_CONFIG_HOME"],
  XDG_DATA_HOME = vim.env["XDG_DATA_HOME"],
  XDG_STATE_HOME = vim.env["XDG_STATE_HOME"],
  AppData = vim.env["AppData"],
  LocalAppData = vim.env["LocalAppData"],
  HOME = vim.env["HOME"],
  NO_COLOR = 1,
  http_proxy = vim.env["http_proxy"],
  https_proxy = vim.env["https_proxy"],
  no_proxy = vim.env["no_proxy"],
  SSH_AUTH_SOCK = vim.env["SSH_AUTH_SOCK"],
  DBUS_SESSION_BUS_ADDRESS = vim.env["DBUS_SESSION_BUS_ADDRESS"],
}

---@param stdout string?
---@param stderr string?
---@return string?
local function parse_user_name(stdout, stderr)
  return string.match(stderr or "", "Logged in to [^%s]+ as ([^%s]+)")
    or string.match(stderr or "", "Logged in to [^%s]+ account ([^%s]+)")
    or string.match(stdout or "", "Logged in to [^%s]+ as ([^%s]+)")
    or string.match(stdout or "", "Logged in to [^%s]+ account ([^%s]+)")
end

---@param stdout string?
---@param stderr string?
---@return string[]
local function parse_scopes(stdout, stderr)
  local all_scopes = string.match(stdout or "", " Token scopes: (.*)")
    or string.match(stderr or "", " Token scopes: (.*)")
    or ""

  local parsed_scopes = {} ---@type string[]
  for _, split_scope in ipairs(vim.split(all_scopes, ", ", { trimempty = true })) do
    local scope = string.gsub(split_scope, "'", "")
    table.insert(parsed_scopes, scope)
  end

  return parsed_scopes
end

local function get_env()
  local env = env_vars
  local gh_env = config.values.gh_env
  if type(gh_env) == "function" then
    local computed_env = gh_env()
    if type(computed_env) == "table" then
      env = vim.tbl_deep_extend("force", env, computed_env)
    end
  elseif type(gh_env) == "table" then
    ---@diagnostic disable-next-line: no-unknown
    env = vim.tbl_deep_extend("force", env, gh_env)
  end

  return env
end

---@type table<string, string>
local auth_tokens = {}
---@type table<string, fun(token: string?)[]>
local auth_token_waiters = {}

---@param hostname string
---@param callback fun(token: string?): nil
local function get_auth_token(hostname, callback)
  local cached = auth_tokens[hostname]
  if cached then
    callback(cached)
    return
  end

  local waiting = auth_token_waiters[hostname]
  if waiting then
    waiting[#waiting + 1] = callback
    return
  end
  auth_token_waiters[hostname] = { callback }

  local ok = pcall(
    vim.system,
    { config.values.gh_cmd, "auth", "token", "--hostname", hostname },
    { env = get_env(), text = true },
    vim.schedule_wrap(function(result)
      local token = result.code == 0 and vim.trim(result.stdout or "") or nil
      if token and (token == "" or token:find "[\r\n]") then
        token = nil
      end
      if token then
        auth_tokens[hostname] = token
      end

      local callbacks = auth_token_waiters[hostname]
      auth_token_waiters[hostname] = nil
      for _, waiter in ipairs(callbacks or {}) do
        waiter(token)
      end
    end)
  )
  if not ok then
    local callbacks = auth_token_waiters[hostname]
    auth_token_waiters[hostname] = nil
    for _, waiter in ipairs(callbacks or {}) do
      waiter(nil)
    end
  end
end

---uses GH to get the name of the authenticated user
---@param remote_hostname string?
function M.get_user_name(remote_hostname)
  if remote_hostname == nil then
    remote_hostname = require("octo.utils").get_remote_host()
  end

  ---@diagnostic disable-next-line: missing-fields
  local job = Job:new {
    enable_recording = true,
    command = config.values.gh_cmd,
    args = { "auth", "status", "--hostname", remote_hostname },
    env = get_env(),
  }
  job:sync(config.values.timeout)
  local stderr = table.concat(job:stderr_result(), "\n")
  local stdout = table.concat(job:result(), "\n")
  local user_name = parse_user_name(stdout, stderr)

  if user_name then
    return user_name
  else
    require("octo.utils").error(stderr)
  end
end

local scopes = {} ---@type string[]

---@param test_scopes string[]
function M.has_scope(test_scopes)
  for _, test_scope in ipairs(test_scopes) do
    if vim.tbl_contains(scopes, test_scope) then
      return true
    end
  end

  return false
end

function M.setup()
  fragments.setup()
  queries.setup()
  mutations.setup()
  _G.octo_pv2_fragment = ""
  ---@diagnostic disable-next-line: missing-fields
  Job:new({
    enable_recording = true,
    command = config.values.gh_cmd,
    args = { "auth", "status" },
    env = get_env(),
    on_exit = vim.schedule_wrap(function(j_self, _, _)
      local use_proj_v2 = config.values.default_to_projects_v2
      local stderr = table.concat(j_self:stderr_result(), "\n")
      local stdout = table.concat(j_self:result(), "\n")
      local user_name = parse_user_name(stdout, stderr)
      scopes = parse_scopes(stdout, stderr)

      if user_name and not vim.g.octo_viewer then
        vim.g.octo_viewer = user_name
      end

      if use_proj_v2 then
        if M.has_scope { "read:project", "project" } then
          _G.octo_pv2_fragment = fragments.projects_v2
        elseif not config.values.suppress_missing_scope.projects_v2 then
          require("octo.utils").error "Cannot request Projects v2: Missing scope 'read:project' or 'project'"
        end
      end
    end),
  }):start()
  local hostname = config.values.github_hostname
  if require("octo.utils").is_blank(hostname) then
    hostname = require("octo.utils").get_remote_host()
  end
  get_auth_token(hostname or "github.com", function() end)
end

---Create a callback function for the job
---@param opts? { success?: fun(output: string): nil; failure?: fun(stderr: string): nil }
---@return fun(output: string, stderr: string): nil
function M.create_callback(opts)
  opts = opts or {}

  local utils = require "octo.utils"

  opts.success = opts.success or utils.info
  opts.failure = opts.failure or utils.error

  return function(output, stderr)
    if stderr and not utils.is_blank(stderr) then
      opts.failure(stderr)
    elseif output then
      opts.success(output)
    end
  end
end

---@class RunOpts
---@field args? string[]
---@field mode? "sync" | "async"
---@field cb? fun(stdout: string, stderr: string, status: integer)
---@field stream_cb? fun(stdout: string, stderr: string)
---@field headers? string[]
---@field hostname? string
---@field debug? boolean
---@field [string] any

---Collect paginated `gh api --paginate` output into a JSON array, replicating
---the `--slurp` flag introduced in gh CLI v2.29.0. Older distributions (e.g.
---Debian stable) ship versions that predate this flag, causing octo to hang on
---"Loading..." because the gh call errors immediately and never resolves.
---`gh api --paginate` emits each page as a compact JSON value on its own line,
---so splitting on newlines and re-wrapping produces the same result as --slurp.
---@param output string raw stdout from `gh api --paginate`
---@return string JSON array of all pages
local function native_slurp(output)
  local pages = {}
  for line in (output .. "\n"):gmatch "([^\n]+)\n?" do
    line = vim.trim(line)
    if #line > 0 then
      local ok, decoded = pcall(vim.json.decode, line)
      if ok then
        table.insert(pages, decoded)
      end
    end
  end
  return vim.json.encode(pages)
end

---Run a gh command
---@param opts RunOpts
---@return string? output
---@return string? stderr
local function run(opts)
  if not Job then
    return
  end
  local remote_hostname = require("octo.utils").get_remote_host()

  -- Lazy load viewer name on the first gh command
  if not vim.g.octo_viewer then
    vim.g.octo_viewer = M.get_user_name(remote_hostname)
  end

  opts = opts or {}
  local conf = config.values
  local mode = opts.mode or "async"

  -- Strip --slurp and handle it natively so octo works with gh CLI < 2.29.0.
  local do_slurp = false
  local filtered_args = {}
  for _, arg in ipairs(opts.args) do
    if arg == "--slurp" then
      do_slurp = true
    else
      table.insert(filtered_args, arg)
    end
  end
  opts.args = filtered_args
  local hostname = ""
  if opts.args[1] == "api" then
    table.insert(opts.args, "-H")
    table.insert(opts.args, "Accept: " .. table.concat(headers, ";"))
    if opts.args[2] == "graphql" then
      table.insert(opts.args, "-H")
      table.insert(opts.args, "X-Github-Next-Global-ID: 1")
    end
    if not require("octo.utils").is_blank(opts.hostname) then
      hostname = opts.hostname
    elseif not require("octo.utils").is_blank(conf.github_hostname) then
      hostname = conf.github_hostname
    elseif not require("octo.utils").is_blank(remote_hostname) then
      hostname = remote_hostname
    end
    if not require("octo.utils").is_blank(hostname) and hostname ~= "github.com" then
      table.insert(opts.args, "--hostname")
      table.insert(opts.args, hostname)
    end
  end
  if opts.headers then
    for _, header in ipairs(opts.headers) do
      table.insert(opts.args, "-H")
      table.insert(opts.args, header)
    end
  end

  local env = get_env()
  if opts.debug then
    env.GH_DEBUG = "1"
  end

  ---@diagnostic disable-next-line: missing-fields
  local job = Job:new {
    enable_recording = true,
    command = config.values.gh_cmd,
    args = opts.args,
    on_stdout = vim.schedule_wrap(function(err, data, _)
      if mode == "async" and opts.stream_cb then
        opts.stream_cb(data, err)
      end
    end),
    on_exit = vim.schedule_wrap(function(j_self, status, _)
      if mode == "async" and opts.cb then
        local output = table.concat(j_self:result(), "\n")
        if do_slurp then
          output = native_slurp(output)
        end
        local stderr = table.concat(j_self:stderr_result(), "\n")
        opts.cb(output, stderr, status)
      end
    end),
    env = env,
  }
  if mode == "sync" then
    job:sync(conf.timeout)
    local output = table.concat(job:result(), "\n")
    if do_slurp then
      output = native_slurp(output)
    end
    return output, table.concat(job:stderr_result(), "\n")
  else
    job:start()
  end
end

---@param key string
local function create_flag(key)
  if #key == 1 then
    return "-" .. key
  else
    return "--" .. key
  end
end

---@param args string[]
---@param flag string
---@param parameter string
---@param key string
---@param value any
function M.insert_input(args, flag, parameter, key, value)
  if type(value) == "boolean" then
    value = tostring(value)
  end

  if type(value) == "table" then
    for k, v in
      pairs(value --[[@as table<any, any>]])
    do
      local new_parameter = type(key) == "number" and parameter .. "[]" or parameter .. "[" .. key .. "]"
      M.insert_input(args, flag, new_parameter, k, v)
    end
  elseif type(key) == "number" then
    table.insert(args, flag)
    table.insert(args, parameter .. "[]=" .. value)
  else
    table.insert(args, flag)
    table.insert(args, parameter .. "[" .. key .. "]=" .. value)
  end
end

---Insert the options into the args table
---@param args string[] the arguments table
---@param options table<any, any> the options to insert
---@param replace? table<string, string> key value pairs to replace in the key of the options
---@return string[] new_args the updated args table
function M.insert_args(args, options, replace)
  replace = replace or {}

  for key, value in pairs(options) do
    if type(key) == "number" then
      table.insert(args, value)
    else
      for k, v in pairs(replace) do
        key = string.gsub(key, k, v)
      end

      local flag = create_flag(key)

      if type(value) == "table" then
        for k, v in
          pairs(value --[[@as table<any, any>]])
        do
          if type(v) == "table" then
            for kk, vv in
              pairs(v --[[@as table<any, any>]])
            do
              M.insert_input(args, flag, k, kk, vv)
            end
          elseif type(v) == "boolean" then
            if v then
              table.insert(args, flag)
              table.insert(args, k .. "=" .. tostring(v))
            end
          else
            table.insert(args, flag)
            table.insert(args, k .. "=" .. v)
          end
        end
      elseif type(value) == "boolean" then
        if value then
          table.insert(args, flag)
        end
      else
        table.insert(args, flag)
        table.insert(args, value)
      end
    end
  end

  return args
end

---@class GraphQLOpts
---@field query? string
---@field fields? table
---@field paginate? boolean
---@field slurp? boolean
---@field F? table field
---@field f? table<string, any> raw-field
---@field jq? string

---Create the arguments for the graphql query
---@param opts GraphQLOpts
---@return table|nil
function M.create_graphql_opts(opts)
  -- add query to the existing raw-field
  local f = opts.f or {}
  local query = opts.query or f.query
  if not query then
    return
  end
  opts.query = nil

  f.query = query
  opts.f = f

  -- Join F and fields together
  local F = opts.F or {}
  local fields = opts.fields or {}

  opts.fields = nil

  opts.F = vim.tbl_extend("force", F, fields)

  return opts
end

local function resolve_api_hostname(hostname)
  if not require("octo.utils").is_blank(hostname) then
    return hostname
  elseif not require("octo.utils").is_blank(config.values.github_hostname) then
    return config.values.github_hostname
  end
  return require("octo.utils").get_remote_host() or "github.com"
end

---@param hostname string
---@param path string
---@param graphql_request boolean
---@return string?
local function direct_api_url(hostname, path, graphql_request)
  if hostname:find "[/\\?#%s]" then
    return nil
  end
  if graphql_request then
    if hostname:lower() == "github.com" then
      return "https://api.github.com/graphql"
    end
    return "https://" .. hostname .. "/api/graphql"
  end
  if not vim.startswith(path, "/") or vim.startswith(path, "//") then
    return nil
  end
  if hostname:lower() == "github.com" then
    return "https://api.github.com" .. path
  end
  return "https://" .. hostname .. "/api/v3" .. path
end

---@param value string
---@return string
local function quote_curl_config(value)
  value = value:gsub("[\r\n]", "")
  value = value:gsub("\\", "\\\\"):gsub('"', '\\"')
  return '"' .. value .. '"'
end

---@param hostname string
---@param url string
---@param method "GET"|"POST"
---@param body string?
---@param request_headers string[]?
---@param expects_json boolean
---@param callback fun(output: string): nil
---@param fallback fun(): nil
local function request_with_curl(hostname, url, method, body, request_headers, expects_json, callback, fallback)
  if vim.fn.executable "curl" ~= 1 then
    fallback()
    return
  end

  get_auth_token(hostname, function(token)
    if not token then
      fallback()
      return
    end

    local config_lines = {
      "silent",
      "show-error",
      "compressed",
      "http2",
      "fail-with-body",
      "request = " .. quote_curl_config(method),
      "url = " .. quote_curl_config(url),
      "header = " .. quote_curl_config("Authorization: Bearer " .. token),
    }
    if method == "POST" then
      table.insert(config_lines, 'header = "Content-Type: application/json"')
      table.insert(config_lines, 'header = "X-Github-Next-Global-ID: 1"')
      table.insert(config_lines, "header = " .. quote_curl_config("Accept: " .. table.concat(headers, ";")))
    else
      table.insert(config_lines, "header = " .. quote_curl_config("Accept: " .. table.concat(headers, ";")))
    end
    for _, header in ipairs(request_headers or {}) do
      table.insert(config_lines, "header = " .. quote_curl_config(header))
    end

    local args = { "curl", "--config", "-" }
    if body then
      table.insert(args, "--data-binary")
      table.insert(args, body)
    end
    local launched = pcall(
      vim.system,
      args,
      { stdin = table.concat(config_lines, "\n"), text = true },
      vim.schedule_wrap(function(result)
        if result.code ~= 0 then
          fallback()
          return
        end
        local output = result.stdout or ""
        if expects_json then
          local decoded_ok, decoded = pcall(vim.json.decode, output)
          if not decoded_ok or (type(decoded) == "table" and decoded.errors ~= nil) then
            fallback()
            return
          end
        end
        callback(output)
      end)
    )
    if not launched then
      fallback()
    end
  end)
end

---@param graphql_opts table
---@param run_opts RunOpts
---@param args string[]
---@return boolean
local function try_graphql_direct(graphql_opts, run_opts, args)
  if
    type(run_opts.cb) ~= "function"
    or run_opts.mode == "sync"
    or run_opts.stream_cb
    or run_opts.debug
    or graphql_opts.paginate
    or graphql_opts.slurp
    or (graphql_opts.jq ~= nil and graphql_opts.jq ~= ".")
  then
    return false
  end
  for key in pairs(graphql_opts) do
    if key ~= "f" and key ~= "F" and key ~= "jq" and key ~= "paginate" and key ~= "slurp" then
      return false
    end
  end
  local fields = graphql_opts.F
  local raw_fields = graphql_opts.f
  if type(fields) ~= "table" or type(raw_fields) ~= "table" or vim.tbl_count(raw_fields) ~= 1 then
    return false
  end
  local query = raw_fields.query
  if type(query) ~= "string" then
    return false
  end
  local hostname = resolve_api_hostname(run_opts.hostname)
  local url = direct_api_url(hostname, "/graphql", true)
  if not url then
    return false
  end
  local ok, body = pcall(vim.json.encode, { query = query, variables = fields })
  if not ok or type(body) ~= "string" then
    return false
  end

  request_with_curl(hostname, url, "POST", body, run_opts.headers, true, function(output)
    run_opts.cb(output, nil, 0)
  end, function()
    run {
      args = args,
      mode = run_opts.mode,
      cb = run_opts.cb,
      stream_cb = run_opts.stream_cb,
      headers = run_opts.headers,
      hostname = run_opts.hostname,
      debug = run_opts.debug,
    }
  end)
  return true
end

---@param method Method?
---@param opts table
---@param run_opts RunOpts
---@param args string[]
---@return boolean
local function try_rest_direct(method, opts, run_opts, args)
  if
    method ~= "GET"
    or type(run_opts.cb) ~= "function"
    or run_opts.mode == "sync"
    or run_opts.stream_cb
    or run_opts.debug
    or opts.jq ~= nil
    or opts.paginate
    or opts.slurp
    or opts.F
    or opts.f
  then
    return false
  end
  local path = opts[1]
  if type(path) ~= "string" then
    return false
  end
  local hostname = resolve_api_hostname(run_opts.hostname)
  local url = direct_api_url(hostname, path, false)
  if not url then
    return false
  end

  local expects_json = true
  for _, header in ipairs(run_opts.headers or {}) do
    if
      header:find("application/vnd.github.v3.diff", 1, true) or header:find("application/vnd.github.v3.raw", 1, true)
    then
      expects_json = false
      break
    end
  end

  request_with_curl(hostname, url, "GET", nil, run_opts.headers, expects_json, function(output)
    run_opts.cb(output, nil, 0)
  end, function()
    run {
      args = args,
      mode = run_opts.mode,
      cb = run_opts.cb,
      stream_cb = run_opts.stream_cb,
      headers = run_opts.headers,
      hostname = run_opts.hostname,
      debug = run_opts.debug,
    }
  end)
  return true
end

--- The gh.api commands
---@class octo.GH.api
M.api = {}

---@class ApiGraphqlOpts: GraphQLOpts
---@field opts? RunOpts

---Run a graphql query
---@param opts? ApiGraphqlOpts the options for the graphql query
---@return string? output
---@return string? stderr
function M.api.graphql(opts)
  opts = opts or {}
  local run_opts = opts.opts or {}

  opts.opts = nil
  local graphql_opts = M.create_graphql_opts(opts)

  if not graphql_opts then
    local utils = require "octo.utils"
    utils.error "Provide query directly or in the f table."
    return
  end

  local args = { "api", "graphql" }
  args = M.insert_args(args, graphql_opts, { ["_"] = "-" })

  if try_graphql_direct(graphql_opts, run_opts, args) then
    return
  end
  return run {
    args = args,
    mode = run_opts.mode,
    cb = run_opts.cb,
    stream_cb = run_opts.stream_cb,
    headers = run_opts.headers,
    hostname = run_opts.hostname,
    debug = run_opts.debug,
  }
end

---Mapping between format keys and their values
---@alias FormatTable table<string, string | number>

---Format the endpoint with the format table
---@param endpoint string the endpoint to format
---@param format FormatTable the format table
local function format_endpoint(endpoint, format)
  for key, value in pairs(format) do
    endpoint = endpoint:gsub("{" .. key .. "}", value)
  end
  return endpoint
end

---@alias Method "GET"|"POST"|"PATCH"|"DELETE"|"PUT"

---@class CreateRestArgsOpts
---@field [1] string The endpoint to call
---@field format FormatTable?

---@param method Method? the rest method
---@param opts CreateRestArgsOpts the options for the rest command
---@return string[]|nil
function M.create_rest_args(method, opts)
  local format = opts.format or {}

  local endpoint = opts[1]
  if not endpoint then
    return
  end
  endpoint = format_endpoint(endpoint, format)
  opts[1] = endpoint

  local args = { "api" }
  if method ~= nil then
    table.insert(args, "--method")
    table.insert(args, method)
  end

  opts.format = nil
  return M.insert_args(args, opts, { ["_"] = "-" })
end

---@class RestOpts : CreateRestArgsOpts
---@field opts? RunOpts

---Run a rest command
---@param method Method? the rest method
---@param opts RestOpts
local function rest(method, opts)
  local run_opts = opts.opts or {}

  opts.opts = nil
  local args = M.create_rest_args(method, opts)
  if not args then
    local utils = require "octo.utils"
    utils.error "Endpoint is required"
    return
  end

  if try_rest_direct(method, opts, run_opts, args) then
    return
  end
  return run {
    args = args,
    mode = run_opts.mode,
    cb = run_opts.cb,
    stream_cb = run_opts.stream_cb,
    headers = run_opts.headers,
    hostname = run_opts.hostname,
    debug = run_opts.debug,
  }
end

---@param opts RestOpts
function M.api.get(opts)
  return rest("GET", opts)
end

---@param opts RestOpts
function M.api.post(opts)
  return rest("POST", opts)
end

---@param opts RestOpts
function M.api.patch(opts)
  return rest("PATCH", opts)
end

---@param opts RestOpts
function M.api.delete(opts)
  return rest("DELETE", opts)
end

---@param opts RestOpts
function M.api.put(opts)
  return rest("PUT", opts)
end

---Call the api without specifying the method. GitHub CLI determines the method based on the arguments
setmetatable(M.api, {
  __call = function(_, opts)
    return rest(nil, opts)
  end,
})

local function create_subcommand(command)
  local subcommand = {}
  subcommand.command = command

  setmetatable(subcommand, {
    __call = function(_, opts)
      --- Allow for backwards compatibility with the old API gh.run { ... }
      if command == "run" then
        return run(opts)
      end
    end,
    __index = function(t, key)
      return function(opts) ---@param opts? { opts?: RunOpts }
        opts = opts or {}

        local run_opts = opts.opts or {}

        key = string.gsub(key, "_", "-")

        local args = {
          t.command,
          key,
        }

        opts.opts = nil
        args = M.insert_args(args, opts, { ["_"] = "-" })

        return run {
          args = args,
          mode = run_opts.mode,
          cb = run_opts.cb,
          stream_cb = run_opts.stream_cb,
          headers = run_opts.headers,
          hostname = run_opts.hostname,
          debug = run_opts.debug,
        }
      end
    end,
  })

  return subcommand
end

setmetatable(M, {
  __index = function(_, key)
    return create_subcommand(key)
  end,
})

return M

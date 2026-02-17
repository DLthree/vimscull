-- numscull/client.lua — JSON-RPC layer, message IDs, request/response

local M = {}
local transport = require("numscull.transport")
local crypto = require("numscull.crypto")

local _transport = nil
local _msg_id = 0

local function next_id()
  _msg_id = _msg_id + 1
  return _msg_id
end

--- Connect to host:port. Returns true or nil, err.
function M.connect(host, port)
  if _transport then
    return true
  end
  local t, err = transport.connect(host, port)
  if not t then
    return nil, err
  end
  _transport = t
  return true
end

--- Initialize session: plaintext control/init + key exchange.
--- identity: string
--- secret_key: 32-byte string, or nil to load from config_dir/identities/identity
--- config_dir: path (required if secret_key is nil)
--- version: string (default "0.2.4")
--- Returns init response or nil, err.
function M.init(identity, secret_key, config_dir, version)
  if not _transport then
    return nil, "not connected"
  end

  if not secret_key and config_dir and identity then
    local pk, sk = crypto.load_keypair(identity, config_dir)
    secret_key = sk
  end
  if not secret_key then
    return nil, "secret_key or (config_dir + identity) required"
  end

  version = version or "0.2.4"

  local req = {
    id = next_id(),
    method = "control/init",
    params = { identity = identity, version = version },
  }

  local resp = _transport.run_sync(function()
    _transport.send_plaintext(req)
    return _transport.recv_plaintext()
  end)

  local params = resp.params or resp.result or {}
  local pk_b64 = (params.publicKey or {}).bytes
  if not pk_b64 then
    return nil, "no publicKey in init response: " .. vim.inspect(resp)
  end

  -- Base64 decode server public key (pure Lua)
  local b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local function decode_char(c)
    if c == "=" then return nil end
    local idx = b64:find(c, 1, true)
    return idx and (idx - 1) or 0
  end
  local out = {}
  pk_b64 = pk_b64:gsub("[^%w%+%/=]", "")
  for i = 1, #pk_b64, 4 do
    local a = decode_char(pk_b64:sub(i, i))
    local b = decode_char(pk_b64:sub(i + 1, i + 1))
    local c = decode_char(pk_b64:sub(i + 2, i + 2))
    local d = decode_char(pk_b64:sub(i + 3, i + 3))
    if a == nil then break end
    out[#out + 1] = string.char((a or 0) * 4 + math.floor((b or 0) / 16))
    if b ~= nil and c ~= nil then
      out[#out + 1] = string.char(((b or 0) % 16) * 16 + math.floor((c or 0) / 4))
    end
    if c ~= nil and d ~= nil then
      out[#out + 1] = string.char(((c or 0) % 4) * 64 + (d or 0))
    end
  end
  local server_pk = table.concat(out):sub(1, 32)
  if #server_pk ~= 32 then
    return nil, "invalid server public key"
  end

  local channel = _transport.run_sync(function()
    return crypto.do_key_exchange(_transport._sock, secret_key, server_pk)
  end)
  _transport.set_channel(channel)

  return resp
end

--- Send JSON-RPC request, return result. Uses run_sync for blocking I/O.
--- On control/error response, returns nil, reason.
function M.request(method, params)
  if not _transport then
    return nil, "not connected"
  end

  params = params or {}
  local req = {
    id = next_id(),
    method = method,
    params = params,
  }

  local resp = _transport.run_sync(function()
    _transport.send(req)
    return _transport.recv()
  end)

  if resp.method == "control/error" then
    local reason = (resp.result or {}).reason or "unknown error"
    return nil, reason
  end

  return resp.result or resp.params or resp
end

--- Close the connection.
function M.close()
  if _transport then
    _transport.close()
    _transport = nil
  end
end

--- Check if connected.
function M.is_connected()
  return _transport ~= nil
end

return M

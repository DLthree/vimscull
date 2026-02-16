-- numscull/transport.lua — TCP connection, plaintext and encrypted framing
-- Uses vim.uv for TCP. Coroutine-based sync wrappers for connect/read/write.

local M = {}
local uv = vim.uv
local crypto = require("numscull.crypto")

local HEADER_SIZE = 10

-- Pack plaintext: 10-byte zero-padded decimal length + payload
local function pack_plaintext(msg)
  local payload = vim.json.encode(msg)
  local len_str = string.format("%010d", #payload)
  return len_str .. payload
end

--- Create a transport and connect to host:port.
--- Returns transport object, or nil, err on failure.
--- Uses coroutine + uv.run to block until connected.
function M.connect(host, port)
  host = host or "127.0.0.1"
  port = port or 5000
  local tcp = uv.new_tcp()
  local buffer = ""
  local read_want = nil
  local read_co = nil
  local read_result = nil
  local write_co = nil
  local main_co = nil
  local transport_result = nil

  -- Run event loop until main_co completes
  local function run_until_done()
    while main_co and coroutine.status(main_co) ~= "dead" do
      uv.run("once")
    end
  end

  local function _read(n)
    if #buffer >= n then
      local data = buffer:sub(1, n)
      buffer = buffer:sub(n + 1)
      return data
    end
    read_want = n
    read_co = coroutine.running()
    coroutine.yield()
    return read_result
  end

  local function _write(data)
    write_co = coroutine.running()
    tcp:write(data, function(err)
      if write_co then
        local co = write_co
        write_co = nil
        coroutine.resume(co, err)
      end
    end)
    local err = coroutine.yield()
    if err then
      error("write failed: " .. tostring(err))
    end
  end

  -- Sock-like object for crypto.do_key_exchange (sock:read(n) and sock:write(data))
  local sock = {
    read = function(_, n)
      return _read(n)
    end,
    write = function(_, data)
      _write(data)
    end,
  }

  local channel = nil -- EncryptedChannel after key exchange

  local transport_ref = {}
  transport_ref._tcp = tcp
  transport_ref._buffer = function() return buffer end
  transport_ref._sock = sock

  transport_ref.send_plaintext = function(msg)
    local data = pack_plaintext(msg)
    _write(data)
  end

  transport_ref.recv_plaintext = function()
    local header = _read(HEADER_SIZE)
    local payload_len = tonumber(header)
    if not payload_len or payload_len < 0 then
      error("invalid plaintext header: " .. tostring(header))
    end
    local payload = _read(payload_len)
    return vim.json.decode(payload)
  end

  transport_ref.set_channel = function(ch)
    channel = ch
  end

  transport_ref.send = function(msg)
    if channel then
      channel.send(msg)
    else
      transport_ref.send_plaintext(msg)
    end
  end

  transport_ref.recv = function()
    if channel then
      return channel.recv()
    else
      return transport_ref.recv_plaintext()
    end
  end

  transport_ref.close = function()
    if tcp and not tcp:is_closing() then
      tcp:read_stop()
      tcp:close()
    end
  end

  transport_ref.run_sync = function(fn)
    local result
    local co = coroutine.create(function()
      result = fn()
    end)
    local ok, err = coroutine.resume(co)
    if not ok then
      error(err)
    end
    local timeout_ms = tonumber(os.getenv("NUMSCULL_SYNC_TIMEOUT")) or 8000
    local timeout_flag = false
    local timer = uv.new_timer()
    timer:start(timeout_ms, 0, function()
      timeout_flag = true
    end)
    while coroutine.status(co) ~= "dead" and not timeout_flag do
      uv.run("once")
    end
    timer:stop()
    timer:close()
    if timeout_flag then
      error("run_sync: timeout after " .. timeout_ms .. "ms")
    end
    return result
  end

  main_co = coroutine.create(function()
    local ok, err = tcp:connect(host, port, function(connect_err)
      if main_co and coroutine.status(main_co) == "suspended" then
        local resumed_ok, ret = coroutine.resume(main_co, connect_err)
        if resumed_ok and ret then
          transport_result = ret
        end
      end
    end)
    if not ok then
      error("tcp:connect failed: " .. tostring(err))
    end
    local connect_err = coroutine.yield()
    if connect_err then
      tcp:close()
      error("connection failed: " .. tostring(connect_err))
    end

    tcp:read_start(function(read_err, chunk)
      if read_err then
        if read_co then
          local co = read_co
          read_co = nil
          read_want = nil
          read_result = nil
          coroutine.resume(co, nil, read_err)
        end
        return
      end
      if chunk and #chunk > 0 then
        buffer = buffer .. chunk
      end
      if read_want and #buffer >= read_want then
        read_result = buffer:sub(1, read_want)
        buffer = buffer:sub(read_want + 1)
        local co = read_co
        read_co = nil
        read_want = nil
        if co then
          coroutine.resume(co)
        end
      end
      if not chunk then
        -- EOF
        if read_co then
          local co = read_co
          read_co = nil
          read_want = nil
          coroutine.resume(co, nil, "EOF")
        end
      end
    end)

    return transport_ref
  end)

  local ok, result = coroutine.resume(main_co)
  if not ok then
    tcp:close()
    error(result)
  end

  run_until_done()

  if transport_result then
    return transport_result
  end

  return nil, "connect did not complete"
end

return M

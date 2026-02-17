-- numscull/crypto.lua — NaCl Box encryption, key exchange, encrypted channel
-- Port of mockscull/src/numscull/crypto.py using LuaJIT FFI to libsodium

local M = {}
local ffi = require("ffi")

-- Constants from mockscull transport/crypto
M.HEADER_SIZE = 10
M.BLOCK_SIZE = 512
M.MAC_BYTES = 16
M.NONCE_LEN = 24
M.KEY_LEN = 32
M.ENCRYPTED_BLOCK_SIZE = M.BLOCK_SIZE + M.MAC_BYTES -- 528

ffi.cdef([[
  int sodium_init(void);
  void randombytes_buf(void *buf, size_t size);
  int crypto_scalarmult_base(unsigned char *q, const unsigned char *n);
  int crypto_box_easy(unsigned char *c, const unsigned char *m,
                      unsigned long long mlen, const unsigned char *n,
                      const unsigned char *pk, const unsigned char *sk);
  int crypto_box_open_easy(unsigned char *m, const unsigned char *c,
                           unsigned long long clen, const unsigned char *n,
                           const unsigned char *pk, const unsigned char *sk);
]])

local sodium
do
  local names = { "sodium", "libsodium" }
  for _, name in ipairs(names) do
    local ok, err = pcall(function()
      sodium = ffi.load(name)
    end)
    if ok and sodium then break end
    if not ok then M._load_error = tostring(err) end
  end
  if not sodium then
    sodium = nil
  end
end

if not sodium then
  return M
end

-- 0 = first init, 1 = already initialized (idempotent), -1 = failure
local init_ret = sodium.sodium_init()
if init_ret == -1 then
  M._load_error = "sodium_init failed"
  return M
end

-- Pack little-endian u16
local function pack_u16_le(n)
  n = n % 65536
  return string.char(n % 256, math.floor(n / 256))
end

-- Unpack little-endian u16
local function unpack_u16_le(s)
  local b1, b2 = string.byte(s, 1, 2)
  return b1 + b2 * 256
end

-- Pack little-endian u64 (8 bytes) for nonce
local function pack_u64_le(n)
  local s = {}
  for _ = 1, 8 do
    s[#s + 1] = string.char(n % 256)
    n = math.floor(n / 256)
  end
  return table.concat(s)
end

--- Encode counter as 24-byte nonce: LE u64 + 16 zero bytes.
function M.counter_nonce(counter)
  return pack_u64_le(counter) .. string.rep("\0", 16)
end

--- Generate X25519 keypair. Returns (public_key, secret_key). Each 32 bytes.
function M.generate_x25519_keypair()
  local sk = ffi.new("unsigned char[32]")
  sodium.randombytes_buf(sk, 32)
  local pk = ffi.new("unsigned char[32]")
  if sodium.crypto_scalarmult_base(pk, sk) ~= 0 then
    error("crypto_scalarmult_base failed")
  end
  return ffi.string(pk, 32), ffi.string(sk, 32)
end

--- Load keypair from identity file. Returns (public_key, secret_key). Each 32 bytes.
--- config_dir: path string (e.g. "/path/to/config")
--- identity_name: string (e.g. "python-client")
function M.load_keypair(identity_name, config_dir)
  local path = config_dir .. "/identities/" .. identity_name
  local f = io.open(path, "rb")
  if not f then
    error("cannot open identity file: " .. path)
  end
  local raw = f:read("*a")
  f:close()
  if #raw ~= 64 then
    error("expected 64-byte identity file, got " .. #raw)
  end
  return raw:sub(1, 32), raw:sub(33, 64)
end

--- Pack plaintext bytes with 10-byte zero-padded decimal length header.
function M.pack_plaintext_bytes(payload)
  local len_str = string.format("%010d", #payload)
  return len_str .. payload
end

--- EncryptedChannel: encrypted communication using ephemeral X25519 + NaCl Box.
--- Created by do_key_exchange. Use :send(msg) and :recv().
function M.EncryptedChannel(sock, ours_recv_sk, ours_send_sk, theirs_recv_pk, theirs_send_pk)
  local send_nonce = 1
  local recv_nonce = 1

  local function send(message)
    local json_str = vim.json.encode(message)
    local json_bytes = json_str
    local framed = M.pack_plaintext_bytes(json_bytes)
    if #framed > M.BLOCK_SIZE - 2 then
      error("message too large: " .. #framed .. " > " .. (M.BLOCK_SIZE - 2))
    end

    local block = ffi.new("unsigned char[?]", M.BLOCK_SIZE)
    ffi.copy(block, pack_u16_le(#framed), 2)
    ffi.copy(block + 2, framed, #framed)
    -- Random padding for remaining bytes
    local padding_len = M.BLOCK_SIZE - 2 - #framed
    if padding_len > 0 then
      local pad = ffi.new("unsigned char[?]", padding_len)
      sodium.randombytes_buf(pad, padding_len)
      ffi.copy(block + 2 + #framed, pad, padding_len)
    end

    local nonce = M.counter_nonce(send_nonce)
    send_nonce = send_nonce + 1

    local ct = ffi.new("unsigned char[?]", M.BLOCK_SIZE + M.MAC_BYTES)
    local n = ffi.new("unsigned char[24]")
    ffi.copy(n, nonce, 24)
    local their_pk = ffi.new("unsigned char[32]")
    ffi.copy(their_pk, theirs_send_pk, 32)
    local our_sk = ffi.new("unsigned char[32]")
    ffi.copy(our_sk, ours_send_sk, 32)

    if sodium.crypto_box_easy(ct, block, M.BLOCK_SIZE, n, their_pk, our_sk) ~= 0 then
      error("crypto_box_easy failed")
    end

    sock:write(ffi.string(ct, M.ENCRYPTED_BLOCK_SIZE))
  end

  local function recv_raw()
    local ct = sock:read(M.ENCRYPTED_BLOCK_SIZE)
    if not ct or #ct ~= M.ENCRYPTED_BLOCK_SIZE then
      error("socket closed or short read")
    end

    local nonce = M.counter_nonce(recv_nonce)
    recv_nonce = recv_nonce + 1

    local block = ffi.new("unsigned char[?]", M.BLOCK_SIZE)
    local ct_buf = ffi.new("unsigned char[?]", M.ENCRYPTED_BLOCK_SIZE)
    ffi.copy(ct_buf, ct, M.ENCRYPTED_BLOCK_SIZE)
    local n = ffi.new("unsigned char[24]")
    ffi.copy(n, nonce, 24)
    local their_pk = ffi.new("unsigned char[32]")
    ffi.copy(their_pk, theirs_recv_pk, 32)
    local our_sk = ffi.new("unsigned char[32]")
    ffi.copy(our_sk, ours_recv_sk, 32)

    if sodium.crypto_box_open_easy(block, ct_buf, M.ENCRYPTED_BLOCK_SIZE, n, their_pk, our_sk) ~= 0 then
      error("crypto_box_open_easy failed (decryption)")
    end

    local msg_len = unpack_u16_le(ffi.string(block, 2))
    return ffi.string(block + 2, msg_len)
  end

  local function recv()
    local data = recv_raw()
    local header = data:sub(1, M.HEADER_SIZE)
    local json_len = tonumber(header)
    local json_bytes = data:sub(M.HEADER_SIZE + 1, M.HEADER_SIZE + json_len)

    while #json_bytes < json_len do
      local more = recv_raw()
      json_bytes = json_bytes .. more
    end

    return vim.json.decode(json_bytes:sub(1, json_len))
  end

  return {
    send = send,
    recv = recv,
    recv_raw = recv_raw,
  }
end

--- Perform the ephemeral key exchange after init.
--- sock: transport object with read(n) and write(data) methods
--- our_static_sk: 32-byte secret key
--- their_static_pk: 32-byte server public key
--- Returns EncryptedChannel table.
function M.do_key_exchange(sock, our_static_sk, their_static_pk)
  local server_exchange = sock:read(M.NONCE_LEN + M.ENCRYPTED_BLOCK_SIZE)
  if not server_exchange or #server_exchange ~= M.NONCE_LEN + M.ENCRYPTED_BLOCK_SIZE then
    error("short read during key exchange")
  end

  local server_nonce = server_exchange:sub(1, M.NONCE_LEN)
  local server_ct = server_exchange:sub(M.NONCE_LEN + 1)

  local server_block = ffi.new("unsigned char[?]", M.BLOCK_SIZE)
  local ct_buf = ffi.new("unsigned char[?]", M.ENCRYPTED_BLOCK_SIZE)
  ffi.copy(ct_buf, server_ct, M.ENCRYPTED_BLOCK_SIZE)
  local n = ffi.new("unsigned char[24]")
  ffi.copy(n, server_nonce, 24)
  local their_pk = ffi.new("unsigned char[32]")
  ffi.copy(their_pk, their_static_pk, 32)
  local our_sk = ffi.new("unsigned char[32]")
  ffi.copy(our_sk, our_static_sk, 32)

  if sodium.crypto_box_open_easy(server_block, ct_buf, M.ENCRYPTED_BLOCK_SIZE, n, their_pk, our_sk) ~= 0 then
    error("crypto_box_open_easy failed during key exchange")
  end

  local server_recv_pk = ffi.string(server_block, M.KEY_LEN)
  local server_send_pk = ffi.string(server_block + M.KEY_LEN, M.KEY_LEN)

  local our_recv_pk, our_recv_sk = M.generate_x25519_keypair()
  local our_send_pk, our_send_sk = M.generate_x25519_keypair()

  local block = ffi.new("unsigned char[?]", M.BLOCK_SIZE)
  ffi.copy(block, our_recv_pk, M.KEY_LEN)
  ffi.copy(block + M.KEY_LEN, our_send_pk, M.KEY_LEN)
  local pad = ffi.new("unsigned char[?]", M.BLOCK_SIZE - M.KEY_LEN * 2)
  sodium.randombytes_buf(pad, M.BLOCK_SIZE - M.KEY_LEN * 2)
  ffi.copy(block + M.KEY_LEN * 2, pad, M.BLOCK_SIZE - M.KEY_LEN * 2)

  local client_nonce = ffi.new("unsigned char[24]")
  sodium.randombytes_buf(client_nonce, M.NONCE_LEN)

  local client_ct = ffi.new("unsigned char[?]", M.ENCRYPTED_BLOCK_SIZE)
  local their_pk2 = ffi.new("unsigned char[32]")
  ffi.copy(their_pk2, their_static_pk, 32)
  local our_sk2 = ffi.new("unsigned char[32]")
  ffi.copy(our_sk2, our_static_sk, 32)

  if sodium.crypto_box_easy(client_ct, block, M.BLOCK_SIZE, client_nonce, their_pk2, our_sk2) ~= 0 then
    error("crypto_box_easy failed")
  end

  sock:write(ffi.string(client_nonce, M.NONCE_LEN) .. ffi.string(client_ct, M.ENCRYPTED_BLOCK_SIZE))

  return M.EncryptedChannel(sock, our_recv_sk, our_send_sk, server_send_pk, server_recv_pk)
end

--- Write a keypair to disk (identities/<name> and users/<name>.pub for server).
--- Used by tests to generate test identity.
function M.write_keypair(config_dir, identity_name, public_key, secret_key)
  local identities_dir = config_dir .. "/identities"
  local users_dir = config_dir .. "/users"
  vim.fn.mkdir(identities_dir, "p")
  vim.fn.mkdir(users_dir, "p")
  local identity_path = identities_dir .. "/" .. identity_name
  local f = io.open(identity_path, "wb")
  if not f then
    error("cannot write identity file: " .. identity_path)
  end
  f:write(public_key)
  f:write(secret_key)
  f:close()
  local pub_path = users_dir .. "/" .. identity_name .. ".pub"
  local pf = io.open(pub_path, "wb")
  if pf then
    pf:write(public_key)
    pf:close()
  end
end

return M

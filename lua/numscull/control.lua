-- numscull/control.lua — control module: init, projects, subscribe, exit

local M = {}
local client = require("numscull.client")

--- Initialize session (connect + control/init + key exchange).
--- host, port: connection
--- identity: string
--- secret_key: 32-byte string, or nil to load from config_dir
--- config_dir: path to dir with identities/<identity>
--- version: string (default "0.2.4")
function M.init(host, port, identity, secret_key, config_dir, version)
  local ok, err = client.connect(host, port)
  if not ok then
    return nil, err
  end
  return client.init(identity, secret_key, config_dir, version)
end

--- List projects.
function M.list_projects()
  return client.request("control/list/project", {})
end

--- Create project.
function M.create_project(name, repository, owner_identity)
  return client.request("control/create/project", {
    name = name,
    repository = repository,
    ownerIdentity = owner_identity,
  })
end

--- Change active project.
function M.change_project(name)
  return client.request("control/change/project", { name = name })
end

--- Remove project.
function M.remove_project(name)
  return client.request("control/remove/project", { name = name })
end

--- Subscribe to channels.
function M.subscribe(channels)
  return client.request("control/subscribe", { channels = channels })
end

--- Unsubscribe from channels.
function M.unsubscribe(channels)
  return client.request("control/unsubscribe", { channels = channels })
end

--- Exit session.
function M.exit()
  local result = client.request("control/exit", {})
  client.close()
  return result
end

--- Disconnect without exit RPC.
function M.disconnect()
  client.close()
end

return M

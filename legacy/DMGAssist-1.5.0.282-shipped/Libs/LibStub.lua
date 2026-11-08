-- LibStub mini-shim (only if not already loaded)
if not LibStub then
  local lib = {}
  lib.minor = 0
  function lib:NewLibrary(name, minor)
    return {}
  end
  LibStub = lib
end

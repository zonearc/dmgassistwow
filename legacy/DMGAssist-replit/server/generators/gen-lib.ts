/**
 * @module generators/gen-lib
 * @description
 * Generates **LibStub.lua** — minimal library management shim.
 *
 * Produces: `Libs/LibStub.lua` in the addon ZIP
 *
 * Provides a self-contained LibStub implementation for future library integration.
 * If LibStub is already loaded by another addon, this file is a no-op.
 */

export function generateLibStub(): string {
  return `-- LibStub mini-shim (only if not already loaded)
if not LibStub then
  local lib = {}
  lib.minor = 0
  function lib:NewLibrary(name, minor)
    return {}
  end
  LibStub = lib
end
`;
}

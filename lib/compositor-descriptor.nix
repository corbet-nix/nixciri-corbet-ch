# SPDX-License-Identifier: MIT OR Apache-2.0
package: {
  inherit package;
  command = "ciri --session";
  deviceEnvironment = [ ];
  rendererEnvironment = {
    auto = { };
    hardware = { };
    software.LIBGL_ALWAYS_SOFTWARE = "1";
  };
  headlessEnvironment = { };
  supportsHeadless = false;
  supportsVirtualOutputs = false;
  supportsNotify = true;
  currentDesktop = "ciri";
}

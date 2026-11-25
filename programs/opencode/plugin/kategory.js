// opencode-kategory's plugin: plain JavaScript with no imports, so OpenCode
// loads it from the read-only config dir with nothing to install.
//
// The wrapper (launch.sh) moved XDG_CONFIG_HOME, XDG_DATA_HOME and
// XDG_CACHE_HOME away from the user's for OpenCode itself, and saved the
// user's own as one JSON object in the variable below. Every shell OpenCode
// runs gets them back, so gh and git read the user's config. XDG_STATE_HOME
// stays moved: `state` keeps OpenCode's own run store.
//
// Parsed once, at load: the wrapper always sets it, so a missing or broken
// value is a bug and fails the load.
const userXdg = JSON.parse(process.env["@userXdgVar@"]);

export const Kategory = async () => ({
  "shell.env": async (_input, output) => {
    Object.assign(output.env, userXdg);
  },
});

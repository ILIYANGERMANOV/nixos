# The profiles: one folder each, `<name>/profile.nix` and any prose it owns
# (`agent.md` for every agent in that setup, `lead.md` for the lead only).
# Adding a profile is adding its folder. A profile.nix is a function from the
# arguments below to a spec for lib/profile.nix's `mkProfile`; its name is the
# folder's. Profiles are deltas: none imports another, whoever selects them
# lists them all.
{
  lib,
  mkProfile,
  mkFragment,
  mkInstructions,
  topics,
  qa,
  ctx,
  state,
}:

lib.mapAttrs (
  name: _:
  mkProfile (
    import ./${name}/profile.nix {
      inherit
        mkFragment
        mkInstructions
        topics
        qa
        ctx
        state
        ;
    }
  )
) (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./.))

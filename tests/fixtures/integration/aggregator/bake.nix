# Groups-only module: no own targets, references foreign targets via groups.
{
  middle,
  base,
  ...
}:
{
  targets = { };
  groups = {
    default = [
      middle.targets.main
      base.targets.main
    ];
  };
}

# Groups-only module: no own targets, references foreign targets via groups.
{
  middle,
  base,
  ...
}:
{
  namespace = "aggregator";
  targets = { };
  groups = {
    default = [
      middle.targets.main
      base.targets.main
    ];
  };
}

{ lib
, ...
}:
{
  optionsDefaults = o: lib.listToAttrs (map (e: e // { value = e.value.default; }) (lib.attrsToList o));
}

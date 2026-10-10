def list($name): (.[$name] // []);

def severity_rank:
  if . == "critical" then 0
  elif . == "major" then 1
  elif . == "minor" then 2
  else 3
  end;

def location:
  (.file // "") as $file
  | (if $file == "" then "(no file)" else $file end) as $location
  | if ((.line // 0) > 0) then
      $location + ":" + (.line | tostring)
      + (if ((.end_line // 0) > 0) then "-" + (.end_line | tostring) else "" end)
    else $location
    end;

def gist:
  (.body // "")
  | if . == "" then empty
    else
      gsub("\\s+"; " ")
      | sub("^ +"; "")
      | sub(" +$"; "")
      | (if (index(". ") != null) then (split(". ")[0] + ".") else . end)
      | if length > 200 then .[0:200] + "…" else . end
    end;

def entry:
  ((.severity // "") | tostring) as $severity
  | ((.verdict // "") | tostring) as $verdict
  | ((.id // "") | tostring) as $id
  | ((.title // "") | tostring) as $title
  | (location) as $location
  | (($id + " [" + $severity
      + (if $verdict == "" then "]" else ", " + $verdict + "]" end)
      + " " + $location + " — " + $title))
    , (gist | "  " + .);

def entries($name):
  [list($name) | to_entries[]
   | .value + {report_index: .key, severity_rank: (.value.severity // "" | severity_rank)}]
  | sort_by([.severity_rank, .report_index])
  | .[]
  | entry;

def sources_line:
  (.sources) as $sources
  | ["sources: " + (($sources.reported // 0) | tostring)
     + "/" + (($sources.expected // 0) | tostring) + " reported"]
  + (if (($sources.degraded // []) | length) > 0
     then ["degraded: " + (($sources.degraded | map(tostring)) | join(", "))]
     else [] end)
  + (if (($sources.agents // [])
         | map(select(.raised == 0 and .degraded != true) | (.name // "" | tostring))
         | length) > 0
     then ["raised 0: " + (($sources.agents // [])
         | map(select(.raised == 0 and .degraded != true) | (.name // "" | tostring))
         | join(", "))]
     else [] end)
  | join("; ");

([if has("sources") then sources_line else empty end]
 + ["findings: " + (list("findings") | length | tostring)]
 + [entries("findings")]
 + ["open_questions: " + (list("open_questions") | length | tostring)]
 + [entries("open_questions")]
 + ["pre_existing: " + (list("pre_existing") | length | tostring)
    + ", immaterial: " + (list("immaterial") | length | tostring)])
| .[]

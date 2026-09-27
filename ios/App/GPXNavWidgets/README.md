# GPXNavWidgets

Reserved for the Live Activity and Dynamic Island extension (milestone M4 in
[`docs/ios-plan.md`](../../../docs/ios-plan.md)).

The target exists in `project.yml` so the bundle id and the widget's place in
the app's architecture are settled early, but it has no sources yet. This
placeholder is tracked because git does not record empty directories, and
`xcodegen generate` fails outright if the `sources` path is missing — a fresh
clone has to be able to generate the project.

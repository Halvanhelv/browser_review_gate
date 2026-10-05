A browser run is for a feature: something a person does in the browser works differently or is new.
A cosmetic edit does not need one.

- `required`: the change adds or alters behavior a person exercises in a browser. This includes a
  new page or screen, a form or its validation, a flow or a step in it, navigation and redirects,
  interactive behavior in JavaScript, what a role is allowed to see or do, and a controller or API
  response a page depends on.
- `not-required`: the change is cosmetic or cannot reach the browser. Cosmetic means wording,
  headings, labels, translations, typos, colors, spacing, icons, or reordering static content, with
  no change in what a person can do. Not reaching the browser means documentation, tests, CI
  workflows, developer tooling, and background-only or internal-only code.
- A dependency update is `required` when the dependency runs in the browser or takes part in
  rendering or serving pages: a JavaScript or CSS package, a view, component or sanitizer library,
  the web framework itself. It is `not-required` when the dependency is used only in development,
  tests or CI.
- A change that mixes both is `required`.
- When you cannot tell whether behavior changed, or a patch is truncated or missing for a file that
  could change behavior, choose `required`.

---
name: ui-coding
description: How to build UI - reuse existing components before writing new ones, slot-based composition, pure presentational components, variant unions over boolean flags, mobile-first layouts that survive long text and overflow, and semantic color tokens so components work in light and dark theme without per-component overrides. Examples are React and Tailwind; the principles apply to any UI framework, Jetpack Compose included. Use whenever writing, modifying or reviewing UI - components, screens, layouts or styling.
---

# UI Coding

Applies on top of the `engineering` skill, which still governs code structure,
typing, domain modeling and coding style. This skill adds what is specific to
UI.

Examples use React and Tailwind because those are the primary stack. The
principles are not tied to them - apply the same rules in any UI framework,
Jetpack Compose included.

## Reuse before writing

Before writing a component, look for one that already exists: search the shared
UI directory and the component library the repo already depends on. Prefer
composing or extending an existing primitive over writing a new one. Introduce a
new shared primitive only after asking the user.

## Structure

Follow the code structure rules from `engineering`:

- Feature-specific components live with their feature and are never shared.
- Shared components must be feature-agnostic and re-usable.
- When unsure whether a component is feature-specific or feature-agnostic, ask.

## Components are pure

A component renders its props. Data fetching, subscriptions, global stores,
routers and other side effects belong at the feature edge - the screen or
container - and reach the component as props and callbacks. Props in, callbacks
out.

A shared component that fetches its own data is no longer re-usable: it is bound
to one source, one loading policy and one feature.

## Slots

Prefer the slot pattern for shared components: accept renderable content
(`ReactNode`) rather than a primitive when consumers may legitimately want
different UI in that position.

```tsx
// Good - re-usable: the consumer decides what the title is.
type CardProps = { title: ReactNode; children: ReactNode };

// Also good - fixed by design: every card title must render identically.
type CardProps = { title: string; children: ReactNode };
```

Use a plain value when uniformity is the intent, and a slot when flexibility is.
If the intent is unclear, ask.

## Variants over boolean flags

Express a component's appearance as a closed union, not as accumulated booleans,
so contradictory combinations are unrepresentable.

```tsx
// Good - one closed set of states.
type ButtonProps = { variant: "primary" | "secondary" | "danger" };

// Bad - isPrimary && isDanger is representable and meaningless.
type ButtonProps = { isPrimary?: boolean; isDanger?: boolean };
```

## Responsive and overflow

Build mobile-first: make the layout correct at the smallest width, then add
breakpoints upward. Assume text is longer than the mock shows.

- A flex or grid child needs `min-w-0` before `truncate` or wrapping works - its
  default minimum size is its content.
- Long unbroken strings (emails, URLs, hashes, addresses) must truncate or wrap.
- Wide content (tables, code, diagrams) scrolls inside its own container. The
  page itself must never scroll horizontally.
- Avoid fixed heights that clip when the content grows.
- Keep tap targets finger-sized on touch screens.

## Theming

A component must be correct in light and dark theme without knowing which one is
active. Theme decisions live in the token layer and nowhere else.

- Use semantic color tokens (`background`, `foreground`, `muted`, `border`,
  `destructive`), never raw values (`#fff`, `rgb(...)`) and never palette
  literals (`bg-gray-900`).
- Do not patch a component with per-component dark-theme overrides such as
  `dark:`. A component that needs one is a missing token - add the token
  instead.
- This rule is about color. Spacing, radius and typography are left to
  judgement.

```tsx
// Good - themed by the token layer, correct in both themes.
<div className="bg-card text-card-foreground border-border" />

// Bad - hard-coded palette, then patched per component.
<div className="bg-white text-gray-900 dark:bg-gray-900 dark:text-white" />
```

## Before you finish

Re-read your diff against these rules and fix what violates them.

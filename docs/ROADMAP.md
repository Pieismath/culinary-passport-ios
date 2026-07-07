# Culinary Passport iOS — build order

Mirrors the productization spec (Part B). Backend = the shared Supabase project;
schema lives in the web repo (`supabase/schema.sql` + `supabase/social-schema.sql`).

## Gate 0 — avatar de-risk (BEFORE committing to the build)

Run `node ../culinary-passport/scripts/avatar-style-test.mjs` with ~5 different
selfies through Gemini 2.5 Flash Image ("Nano Banana"). Judge the contact sheet:
- Do the outputs read as ONE matched character set?
- Is each person recognizable?

If no → re-run with `--provider flux` (Flux Kontext). If still no → rethink B2
before writing more Swift. The provider abstraction in the edge function means
switching costs one env var (`AVATAR_PROVIDER`).

## MVP (App Store submission target)

1. SwiftUI shell + Supabase auth (email done in scaffold; add Apple Sign In)
2. 3D globe view — SceneKit + Natural Earth polygons (`GlobeSceneView.swift` is the stub)
3. Personal entries: add / edit / delete with photo + rating
4. Avatar pipeline: selfie upload → Nano Banana → cached PNG (`AvatarService.swift` ready)
5. Solo profile view (private)
6. Country coloring + stamps for personal use

## v1.1 — social launch
7. Public profiles + follow graph (`follows` table live)
8. Discover feed
9. Timeline (port the web Journal: ticks, sticky years, sparkline)
10. Photo map view

## v1.2 — groups (the differentiator)
11. Group creation, invites (`join_group_by_invite` RPC + QR), membership
12. Group feed with reactions and comments (realtime enabled)
13. Group globe: solidarity / consensus / my-view toggles
14. Push notifications for group activity (batched — new edge function for fan-out)

## v1.3 — retention loops
15. Random dinner picker (port web A3: filter-aware spin + nearby cards)
16. Long-distance sync meal (heart-linked stamp)
17. Avatar unlockable accessories (preset PNG overlays first; prompt variants v2)
18. Yearly Wrapped

## Standing decisions

- Style prompt is a server-side constant. Never client-editable.
- Avatars cached forever; regenerate only on re-upload; 3/day server-enforced limit.
- No runtime 3D avatar builder in v1 — 2D stylized portraits as billboards in the
  globe scene. Ready Player Me is a v2 conversation.
- Never gate the core loop (logging + globe + groups). Plus tier = Wrapped video,
  avatar variants, custom stamps.
- Founder accounts (Jason + Jenn) become seed/demo data inside the app.

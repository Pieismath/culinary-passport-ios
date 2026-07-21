# Culinary Passport iOS — build order

Mirrors the productization spec (Part B). Backend = the shared Supabase project;
schema lives in the web repo (`supabase/migrations/` — see its `supabase/README.md`).

Status legend: ✅ shipped · 🔶 partial · ⛔ blocked

## Gate 0 — avatar de-risk (historical; superseded 2026-07-21)

`scripts/avatar-style-test.mjs` judged Gemini 2.5 Flash Image ("Nano Banana")
output before the build was greenlit, and the pipeline shipped. It was
**retired** in favour of user-chosen photos: a per-user generation cost and a
stylized face aren't the right fit for a food journal. The `generate-avatar`
edge function is still deployed but no longer called by the app — delete it
(and the `GEMINI_API_KEY` secret) if it isn't coming back. Bitmoji-style 3D
avatars would need a third-party avatar service (e.g. Ready Player Me), not
this pipeline.

## MVP (App Store submission target)

1. ✅ SwiftUI shell + Supabase auth (email + Google; Apple Sign In coded but
   needs the capability → paid dev account)
2. ✅ 3D globe — SceneKit + Natural Earth polygons, tessellated + mesh-cached
3. ✅ Personal entries: add / edit / delete with photos + rating (photos in a
   private bucket, rendered via signed URLs)
4. ✅ Avatar: user-chosen photo → `avatars/{user_id}/…` (own-folder RLS) →
   `profiles.avatar_url`, accessories composited client-side
5. ✅ Solo profile view
6. ✅ Country coloring for personal use

## v1.1 — social launch
7. ✅ Public profiles + follow graph
8. ✅ Discover feed (server-side `visibility = public` only)
9. ✅ Timeline (ticks, sticky years, sparkline)
10. ✅ Photo map view

## v1.2 — groups (the differentiator)
11. ✅ Group creation, invite-code join (`join_group_by_invite` RPC)
12. ✅ Group feed with reactions and comments — live via realtime subscription
    (`GroupFeedView.listenForChanges`), pull-to-refresh fallback
13. ✅ Group globe: solidarity / consensus / my-view toggles
14. ⛔ Push notifications — device-token registration ships; APNs delivery
    (notify-group), receive/tap handling, and the push entitlement are gated on
    a paid Apple Developer account

## v1.3 — retention loops
15. ✅ Random dinner picker — v2: the dice physically spins the globe and lands
    on an untried cuisine; the country panel offers Log + Nearby (the flag
    slot-machine sheet it replaced is gone)
16. ✅ Long-distance sync meal (heart-linked stamp)
17. 🔶 Avatar unlockable accessories — shipped as emoji/vector composites;
    swap for preset PNG art when it lands (prompt variants v2)
18. ✅ Yearly Wrapped

## Standing decisions

- Style prompt is a server-side constant. Never client-editable.
- Avatars cached forever; regenerate only on re-upload; 3/day server-enforced limit.
- No runtime 3D avatar builder in v1 — 2D stylized portraits as billboards in the
  globe scene. Ready Player Me is a v2 conversation.
- Never gate the core loop (logging + globe + groups). Plus tier = Wrapped video,
  avatar variants, custom stamps.
- Founder accounts (Jason + Jenn) become seed/demo data inside the app.

# Culinary Passport — iOS

Native SwiftUI client for Culinary Passport. The web app (`../culinary-passport`)
is the prototype and stays live as the marketing/landing page; this is the real
product: globe, camera flows, haptics, share sheets.

**Backend is shared** — same Supabase project as the web app. Schema lives in
the web repo as ordered migrations (`supabase/migrations/`, see its
`supabase/README.md`); edge functions deploy from there too.

## Project setup

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
so `.xcodeproj` noise stays out of git:

```bash
brew install xcodegen
xcodegen generate
open CulinaryPassport.xcodeproj
```

Dependencies (declared in `project.yml`, resolved by SPM):
- [supabase-swift](https://github.com/supabase/supabase-swift) — auth, Postgrest, storage, realtime

Configuration: copy `Config.example.xcconfig` to `Config.xcconfig` (gitignored) and
fill in your Supabase URL + anon key.

## Where things stand

MVP → v1.3 is built (see `docs/ROADMAP.md` for per-item status):
- **Globe**: real Natural Earth polygons triangulated onto the SceneKit sphere,
  mesh-cached; personal globe + three-lens group globe
- **Journal**: entries CRUD with photos (private bucket, signed-URL rendering
  via `PhotoSigning.swift`), per-entry visibility (public / groups / private)
  enforced by RLS
- **Social**: Apple + Google + email sign-in, public profiles, follows,
  discover feed, timeline, photo map
- **Groups**: create / invite-code join, live feed (realtime subscription +
  pull-to-refresh) with reactions and comments, synced meals, group globe
- **Retention**: dinner picker, avatar accessories, Yearly Wrapped
- **Avatar**: PhotosPicker selfie → Vision face-crop → `generate-avatar` edge
  function → composited accessories (server enforces the 3/day limit)

Still open: **push notifications** (ROADMAP item 14) — token registration works,
but APNs delivery, notification handling, and the push entitlement are gated on
a paid Apple Developer account (which real Apple Sign-In needs too).

Restaurant autocomplete goes through the `places-proxy` edge function (web
repo), which requires a signed-in user's JWT — never embed a Places key in the
binary.

## Repo layout

```
project.yml                    XcodeGen manifest (targets, SPM deps)
CulinaryPassport/
  CulinaryPassportApp.swift    app entry, auth-gated root
  Config.swift                 reads Supabase creds from the build config
  Models/Models.swift          Entry, Profile, Group, GroupPost, Follow — mirror the SQL schema
  Services/SupabaseService.swift   shared client + data access
  Services/AvatarService.swift     selfie → generate-avatar edge function
  Services/PhotoSigning.swift      signed-URL cache + SignedPhotoImage view
  Views/RootView.swift         tab shell (Globe / Journal / Groups / Profile)
  Globe/                       polygon tessellation + SceneKit globe
docs/ROADMAP.md                ordered build plan with status
```

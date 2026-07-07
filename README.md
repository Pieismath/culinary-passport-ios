# Culinary Passport — iOS

Native SwiftUI client for Culinary Passport. The web app (`../culinary-passport`)
is the prototype and stays live as the marketing/landing page; this is the real
product: globe, camera flows, haptics, share sheets.

**Backend is shared** — same Supabase project as the web app. Run both SQL files
from the web repo (`supabase/schema.sql`, then `supabase/social-schema.sql`) and
deploy the `generate-avatar` edge function before building social features here.

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

Working scaffold — auth-gated tab shell with:
- **Journal**: entries list / add / delete wired to Supabase (country picker from the
  bundled Natural Earth data, same demonym + rare-find logic as the web app)
- **Groups**: list, create (owner-seeded), join by invite code (`join_group_by_invite` RPC)
- **Profile**: PhotosPicker selfie → Vision face-crop → `generate-avatar` edge function
  → avatar display (server enforces the 3/day limit)
- **Globe**: SceneKit placeholder sphere; polygon port is MVP step 2

Restaurant autocomplete on iOS goes through the `places-proxy` edge function
(web repo) — never embed a Places key in the binary.

See `docs/ROADMAP.md` for the ordered build plan (MVP → v1.3), which mirrors the
productization spec in the web repo.

**Before investing further: run the avatar de-risk test** —
`node ../culinary-passport/scripts/avatar-style-test.mjs` with ~5 selfies.
The iOS build is a go only if the outputs feel like a matched set.

## Repo layout

```
project.yml                    XcodeGen manifest (targets, SPM deps)
CulinaryPassport/
  CulinaryPassportApp.swift    app entry, auth-gated root
  Config.swift                 reads Supabase creds from the build config
  Models/Models.swift          Entry, Profile, Group, GroupPost, Follow — mirror the SQL schema
  Services/SupabaseService.swift   shared client + data access
  Services/AvatarService.swift     selfie → generate-avatar edge function
  Views/RootView.swift         tab shell (Globe / Journal / Groups / Profile)
  Views/GlobeSceneView.swift   SceneKit globe placeholder (port of the web globe)
docs/ROADMAP.md                ordered build plan
```

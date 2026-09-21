# Stampd — iOS

**Eat your way around the world — and stamp the places you actually go.**
Every country has two stamps: Tasted (you ate its food) and Visited (you
went). Food is the weekly habit; travel is the big moment; one passport.

Native SwiftUI, iOS 17+. Backend is the shared Supabase project whose schema
lives in the web repo (`../culinary-passport/supabase/migrations`). The repo,
target and bundle id still say *CulinaryPassport*: the app pivoted to travel on
2026-09-17 ([`docs/TRAVEL-PIVOT.md`](docs/TRAVEL-PIVOT.md)) and brought food back
as the everyday half on 2026-09-21 — travel alone is a few trips a year, too
rare to become a habit. Those identifiers are wired into Supabase auth redirects.

## Run it

```bash
brew install xcodegen
xcodegen generate
open CulinaryPassport.xcodeproj
```

Copy `Config.example.xcconfig` to `Config.xcconfig` (gitignored) and fill in the
Supabase URL + anon key.

**No account needed to explore:** launch with `-uiPreview` (or tap *Explore with
demo data* on the sign-in screen in Debug builds). Every screen runs on
`DemoBackend` — a believable cast with passports, memories, groups and chat,
and generated postcard photos. Nothing touches the network.

Debug launch arguments (Debug builds only):

| argument | effect |
| --- | --- |
| `-uiPreview` | demo backend, signed in as Alex |
| `-tab globe\|friends\|groups\|passport` | open on a tab |
| `-open editor\|meal\|dinner\|cuisines\|cuisine\|import\|checklist\|wrapped\|settings\|memory\|trip\|plan\|country\|share\|stamp\|burst` | present a screen (`-code GE` picks the country/cuisine) |
| `-page visited\|tasted\|trips\|map` | open the Passport on a section |
| `-onboarding` | force the first-run flow |
| `-fly JP` | fly the globe to a country |

Tests: `xcodebuild test -scheme CulinaryPassport -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
(geometry, travel stats, trips, photo-location lookup, reminders, input
hygiene, and the app model against the demo backend).

## The product

| Tab | What it's for |
| --- | --- |
| **Globe** | Countries you've visited in your colour, cuisines you've tasted in a lighter wash of it, bucket list in amber. **+** logs a meal (hold for a travel memory). The dice rolls dinner: a cuisine you haven't tried and who serves it near you (hold for travel ideas). Tap a country for its meals, memories and who's been. |
| **Friends** | Meals and memories from people you follow and your groups, a *New stamps* strip, Discover (public), activity, find people. Save any friend's meal as a restaurant to try. |
| **Groups** | A shared globe per group, leaderboard, and a chat — share memories, 🎲 *what should we eat?* (a cuisine none of you has tried) or *where should we go?* |
| **Passport** | The booklet: cover, data page, then Visited and Tasted stamp pages. Trips — planned and been — a map, Year in Travel, settings. Each cuisine has a page: your meals, restaurants you've saved, where friends ate it, who serves it nearby. |

### Food: the weekly half

A meal is an `entries` row with kind `meal` — the culinary app's own shape,
so meals people logged before the travel pivot came back as Tasted stamps.
Logging one is photo → restaurant → cuisine → what you had: a photo's
location finds the restaurant (`MKLocalPointsOfInterestRequest`), the
restaurant's name suggests the cuisine (`Cuisine.suggest`), and a first taste
plays the stamp moment. `Cuisine` names ~210 cuisines the way people order
them ("Georgian", "Persian"), maps dishes to them for search ("pho" →
Vietnamese), and keeps the dice to cuisines a city of any size serves.
Deliberately *not* here: ratings and rankings. That's Beli's game; this one is
about what you haven't tried yet.

Ways into a passport: **scan the photo library**, tick countries on a
checklist, or add a memory (photos → place and date suggested from the photos'
metadata → save; a new country plays the stamp moment).

### The camera roll is the backlog

The scan reads photo locations on-device and clusters them into **trips and
the places inside them** — "Japan & South Korea · 9 days · Tokyo · Kyoto ·
Seoul" — skipping everyday life near the home it infers from where you shoot
most days (`PhotoTripBuilder`). Accepting them writes trips and one memory per
place, **private and photo-less**: nothing is uploaded, nothing reaches a
feed, and the pictures keep showing from the phone (`LocalMemoryPhotos`) until
you add them to a memory on purpose. The whole import is undoable in one tap
(`AppModel.ImportSummary`) from the Trips page.

### Planning is the same object as the log

A **trip** is where you're going, roughly when, who with, and the places
you've saved for it — a boarding pass with a countdown. Save places from a
friend's memory, from Discover, or from a map search; each one can be ticked
off, or turned into a memory with its place already filled in. When the dates
pass, the memories you posted in that window *are* the trip (`TripPlan.covers`),
so nothing has to be migrated from "planned" to "been". A trip attached to a
group is visible to that group, and they can add places to it.

## Architecture

```
CulinaryPassport/
  CulinaryPassportApp.swift   entry: splash, session switch, deep links, password reset
  DesignSystem/               Theme (light/dark tokens, type), Components, RemoteImage
                              (cached image pipeline), StampBadge, Ticket (boarding
                              pass, luggage tag, postcard), ImageTools
  Models/                     Models (Profile, Memory (memories and meals), Stamp, Taste,
                              Group…), Cuisines (names, dishes, clues, dice), Trips (planned
                              trips + saved places), Countries (197 countries +
                              territories), PlaceLocator (photo location → place),
                              TravelStats (stats, chapters, year review)
  Services/
    Backend.swift             protocol for everything the app asks of a server
    SupabaseBackend.swift     live implementation (RLS decides visibility)
    DemoBackend.swift, DemoData.swift   in-memory fixtures + postcard renderer
    AppModel.swift            @Observable single source of truth for the signed-in
                              user; optimistic mutations, per-account disk snapshot
    PhotoLibraryScanner.swift photo-library → countries (on-device)
    PhotoTripBuilder.swift    located photos → trips, stops and where home is
    PlaceSearch.swift         Apple Maps place search (food-only for meals, restaurants by
                              cuisine for the dice) + "On this day" reminders
    NearMe.swift              one-shot location, only when a food feature needs it
  Globe/                      SceneKit globe: tessellated Natural Earth polygons,
                              ribbon borders, small-country dots, themed, fit-to-view camera
  Views/                      App · Auth · Onboarding · Globe · Meals · Memories · Trips · Social · Groups · Passport · Shared
```

Rules worth keeping:

- **Every color is a token with a dark variant** (`Theme.swift`). Don't draw
  `.primary` text on a hard-coded paper color — that's what broke Dark Mode before.
- **Screens read `AppModel`, not their own copies** of the user's data, so a
  change on one tab shows everywhere immediately.
- **Images go through `ImagePipeline`** (disk-cached by storage path,
  downsampled to display size). Don't use `AsyncImage` for storage photos.
- **Privacy is the server's job** (RLS). Client queries filter for relevance only.
- **Paper, not panels.** The Passport tab is a booklet — gold-blocked cover,
  a data page with a machine-readable strip, stamp pages with a stitched
  spine and page numbers (`PassportBook.swift`). A trip is a ticket
  (`TicketShape`), a saved place is a luggage tag, a memory's words sit on a
  postcard. Reach for those before adding another rounded rectangle.
- Upload JPEGs via `ImageTools` — renderers use `.pixels` format (1pt = 1px)
  and re-encoding strips EXIF GPS from shared photos.

## Backend

Travel model (migration `20260917120000_travel_passport.sql`): `entries` rows
with `kind = 'memory'` are memories (pre-pivot meals are `kind = 'meal'` and
never read), `stamps` are the countries you've been to, and *Friends*
visibility (`visibility = 'groups'`) reaches mutual follows and group mates via
`is_friend()`. RPCs: `friends_feed`, `my_activity`, `add_stamps`,
`join_group_by_invite` (rate-limited). Edge function: `delete-account`.

Push delivery still needs the paid Apple Developer account (entitlement +
APNs key); device-token registration is in place and **local** "On this day"
reminders work without it.

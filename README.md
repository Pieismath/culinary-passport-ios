# Stampd — iOS

**How much of the world have you eaten?** Every cuisine you taste gets a stamp
and fills in your globe. When nobody can decide what's for dinner, spin the
globe: it lands on a cuisine nobody at your table has had, then shows who
serves it near you.

Native SwiftUI, iOS 17+. Backend is the shared Supabase project whose schema
lives in the web repo (`../culinary-passport/supabase/migrations`). The repo,
target and bundle id still say *CulinaryPassport* — those identifiers are wired
into Supabase auth redirects. The app went through a travel phase (2026-09-17,
[`docs/TRAVEL-PIVOT.md`](docs/TRAVEL-PIVOT.md)) and came back to food: first as
the weekly half of a two-stamp passport (2026-09-21), and since 2026-09-22 as
the whole app. Travel is a few trips a year, too rare to be a habit; dinner is
every day.

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
`DemoBackend` — a cast in and around San Francisco with meals, tastes, three
tables and their dinner talk, and generated plate photos. Nothing touches the
network except Apple Maps restaurant search.

Debug launch arguments (Debug builds only):

| argument | effect |
| --- | --- |
| `-uiPreview` | demo backend, signed in as Alex |
| `-tab globe\|tables\|me` | open on a tab |
| `-table club` | open the Friday Dinner Club table (or pass a group id) |
| `-spin` | spin as soon as the globe (or a table) is on screen |
| `-open meal\|detail\|settings\|cuisine\|cuisines\|spin\|tablespin\|share\|stamp\|burst` | present a screen (`-code ET` picks the cuisine) |
| `-onboarding` | force the first-run flow |
| `-fly JP` | fly the globe to a cuisine |

Tests: `xcodebuild test -scheme CulinaryPassport -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
(globe geometry, where a restaurant is, cuisines and dishes, how-much-of-the-world
stats, table spins, dinner picks, and the app model against the demo backend).

## The product

| Tab | What it's for |
| --- | --- |
| **Globe** | The world served on a plate. Cuisines you've eaten wear your colour; the rim shows each continent, inked as far round as you've got. **Spin** whirls the globe like a lazy Susan and lands on a cuisine you haven't tried — or, *spinning for* a table, one none of you has — then shows restaurants near you on a round map, each on a ticket (directions, save, suggest to a table, "I ate here"). Tap a country for its cuisine; **🍴+** logs a meal. |
| **Tables** | Your groups as a floor plan of round tables, everyone seated at theirs. A table has its own globe on a lazy Susan (what you've all had, what some of you have), a spin for the table, and the conversation: messages, shared meals, and dinner picks that people answer with **I'm in**. Friends' latest plates sit underneath, with the full feed, activity and find-people. |
| **Me** | The food passport: gold-foil cover, data page (home kitchen, cuisines, world %, favourite, machine-readable strip), the world as six continent plates, a yearly goal, a stamp page per nine cuisines, your meals as plates, and restaurants to try. Each cuisine and continent opens to what you've had and what's still waiting. |

### A meal, logged

A meal is an `entries` row of kind `meal`. Logging one is a photo on a plate
and a receipt: the photo's location finds the restaurant
(`MKLocalPointsOfInterestRequest`), the restaurant's name suggests the cuisine
(`Cuisine.suggest`), and a first taste plays the stamp moment ("Cuisine Nº 21").
`Cuisine` names ~210 cuisines the way people order them ("Georgian",
"Persian"), maps dishes to them for search ("pho" → Vietnamese), and keeps the
spin to cuisines a city of any size serves.

Deliberately *not* here: ratings and rankings. That's Beli's game; this one is
about what you haven't tried yet.

### The spin

`AppModel.spinPool(for:)` is every popular cuisine nobody eating has tasted —
your tastes, or the union of everyone's at a table (`tasted(by:)`), falling
back to what *you* haven't had once a table has eaten everything. The globe's
spin eases out like a flicked lazy Susan and clicks (haptics) as it slows;
where it lands drops a *Tonight* coaster onto the plate, then
`SpinResultSheet` searches Apple Maps around you (`PlaceSearch.restaurants`,
region-bound, within 40 km) and marks restaurants where friends have eaten.
Suggesting one posts a **dinner pick** to the table: a `group_posts` row with
`cuisine_code` and the restaurant (`place_name`, `place_address`,
`place_lat/lng`), plus a readable `text` for older clients and pushes.

## Architecture

```
CulinaryPassport/
  CulinaryPassportApp.swift   entry: splash, session switch, deep links, password reset
  DesignSystem/               Theme (light/dark tokens, type), Components, RemoteImage
                              (cached image pipeline), StampBadge, Tableware (plate,
                              continent rim + curved text, gingham, round table, spin
                              button, meal plates, plate stack), Ticket (ticket, tag,
                              receipt, postcard), ImageTools
  Models/                     Models (Profile, Meal, Taste, Group, GroupPost + DinnerPick…),
                              Cuisines (names, dishes, clues, the spin's pool), FoodStats
                              (how much of the world, by continent), Restaurants (saved
                              places), Countries (197 countries + territories),
                              PlaceLocator (a location → its country)
  Services/
    Backend.swift             protocol for everything the app asks of a server
    SupabaseBackend.swift     live implementation (RLS decides visibility)
    DemoBackend.swift, DemoData.swift   in-memory fixtures + plate-photo renderer
    AppModel.swift            @Observable single source of truth for the signed-in
                              user; optimistic mutations, per-account disk snapshot
    PlaceSearch.swift         Apple Maps search (restaurants for a meal, by cuisine for a spin)
    PhotoMetadata.swift       where and when a meal photo was taken
    NearMe.swift              one-shot location, only when a food feature needs it
  Globe/                      SceneKit globe: tessellated Natural Earth polygons,
                              ribbon borders, small-country dots, spin + fly flights
  Views/                      App · Auth · Onboarding · Globe · Spin · Tables · Meals · Me · Passport · Social · Shared
```

Rules worth keeping:

- **Circles before cards.** The world is on a plate, meals are plates, tables
  are round with people seated at them, a pick is a ticket, a saved restaurant
  is a tag, the editor is a receipt, the passport is a booklet. Reach for
  `Tableware.swift` and `Ticket.swift` before adding another rounded rectangle.
- **Every color is a token with a dark variant** (`Theme.swift`). Don't draw
  `.primary` text on a hard-coded paper color — that's what broke Dark Mode before.
- **Screens read `AppModel`, not their own copies** of the user's data, so a
  change on one tab shows everywhere immediately.
- **Images go through `ImagePipeline`** (disk-cached by storage path,
  downsampled to display size). Don't use `AsyncImage` for storage photos.
- **Privacy is the server's job** (RLS). Client queries filter for relevance only.
- A round map clips Apple Maps' logo and Legal link: pad the map's safe area
  (`SpinResultSheet`) so they stay inside the circle.
- Upload JPEGs via `ImageTools` — renderers use `.pixels` format (1pt = 1px)
  and re-encoding strips EXIF GPS from shared photos.

## Backend

The app reads `entries` of kind `meal`, `tastes` (the stamps, refitted from
meals by a trigger; `add_tastes` for the checklist), `saved_places` with a
`cuisine_code` (restaurants to try), and the group tables. Dinner picks are
`20260922090000_table_tickets.sql`. *Friends* visibility (`visibility =
'groups'`) reaches mutual follows and table mates via `is_friend()`.

The travel era's `stamps`, `trip_plans` and `kind = 'memory'` entries are
still in the database, untouched; the app no longer reads or writes them.

Push delivery still needs the paid Apple Developer account (entitlement +
APNs key); device-token registration is in place.

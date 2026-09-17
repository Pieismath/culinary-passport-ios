# The travel pivot (2026-09-17)

Stampd started as a cuisine globe: log a restaurant meal and that cuisine's
country fills in. On 2026-09-17 it became a **travel passport**. This is the
record of why, what changed, and what's still open.

## Why

- **The metaphor became literal.** A passport, stamps and a globe you fill in
  needed explaining for food ("Thai food in Sydney colors Thailand"). For
  travel they're simply true, and the brand (postage-stamp icon with a globe
  and a plane) already read as travel.
- **Cold start turns into the best moment.** Photos carry where they were
  taken; the app already had offline point-in-polygon lookup. A new user can
  see their passport filled in within a minute, with no API cost.
- **Beli owns social food logging.** Travel has no dominant *social* passport:
  Polarsteps is a trip journal, Been is a solo counter.
- **Most of the product carried over:** the globe engine, private photos with
  visibility rules, groups and chat, follows, reactions/comments, wishlist →
  bucket list, stamp moments, Wrapped, moderation, account deletion.

**The known risk is frequency** — people travel abroad a few times a year.
Counter-measures built in: cities and trips count (not just countries),
"On this day" reminders, a friends feed with new-stamp moments, "friends who've
been" on every country, and group trip planning. Watch retention for this
before adding more surface.

## What changed

### Backend (web repo, applied to the live project)
`supabase/migrations/20260917120000_travel_passport.sql`, additive — tested in
a rolled-back transaction with behavioural assertions before being applied.

| Change | Detail |
| --- | --- |
| `entries.kind` | `'meal'` (all 68 pre-pivot rows, hidden) / `'memory'` |
| `entries.title` | memory name; `restaurant_name` defaults to `''`, `rating` nullable |
| `profiles.home_country` | ISO code |
| `stamps` table | `(user_id, country_code)`, first/last visited, source `manual \| photos \| memory`; trigger keeps it in sync with memories |
| `is_friend()` | mutual follow OR shared group; now backs the `groups` visibility on entries, reactions, comments, photos, profiles |
| RPCs | `friends_feed`, `my_activity`, `add_stamps` |
| Hardening | `join_group_by_invite` returns NULL on a miss + 10 misses/hour limit; invite codes 6–32 `[a-z0-9]`; `groups.created_by` immutable; uploads only to your own `photos/{uid}/` folder; covers only for groups you own |
| `delete-account` | paginated storage cleanup + owned groups' covers |

### App
Rebuilt on a design system and a single app model:

- **Design system** — light/dark color tokens, serif editorial type, cards,
  buttons, toasts, empty states, stamp badges, postage stamps, share cards.
- **Data layer** — `Backend` protocol (Supabase + demo), `AppModel` as the one
  source of truth with optimistic mutations and a per-account cache, a cached
  downsampling image pipeline replacing `AsyncImage` + signed URLs.
- **Countries** — 197 countries (UN 193 + Vatican City, Palestine, Taiwan,
  Kosovo) plus popular territories; small ones drawn as tappable dots;
  Antarctica included; seven real continents.
- **Screens** — sign-in, 3-step onboarding, globe, country panel, memory
  editor (photo metadata → place/date), memory detail, photo import,
  checklist, friends feed, activity, people search, profiles with their globe,
  groups (shared globe, leaderboard, chat), passport, year in travel,
  settings, legal.

### Removed
Google Places restaurant search (and its per-request cost), cuisine inference,
restaurant recommender, cuisine flavour recommender, quick log, saved
restaurants, the dinner-picker framing, cuisine demonyms.

## Bugs fixed along the way

Infrastructure (commit `Fix infrastructure bugs found in review`): 9× oversized
uploads from screen-scale image renderers; globe scene leaked per group visit
(display link retain cycle); group colors changed every launch; People search
broke on commas; any deep link opened "set a new password"; notification
prompt fired cold at sign-in; slow date decoding.

In the rebuild: Dark Mode rendered white-on-cream; tabs showed stale data
until relaunch; Activity "unseen" dots never appeared; email sign-up gave no
"check your inbox"; account deletion failures were silent; group chat had no
report/delete (App Store 1.2); onboarding was per-device, not per-account;
"of 7 continents" counted the open ocean; reaction upserts silently failed
on repeats (no UPDATE policy — now DO NOTHING); Activity sent every one
of your entry ids in a URL. Two restaurant-search bugs (search biased to the
cuisine's country; editing a meal cleared its saved place) went away with
restaurant search.

## Open follow-ups

- **Paid Apple Developer account** → Sign in with Apple capability, push
  entitlement + APNs key (`notify-group` delivery), TestFlight.
- **Universal links** for invites (`culinarypassport://join/<code>` works only
  from places that open custom schemes).
- **App Store privacy labels**: Photo Library (read, on-device), Photos
  uploaded (EXIF stripped), Coarse Location (memory coordinates from photo GPS
  are rounded to ~1 km; place-search results are exact public places).
- Delete the `places-proxy` function and `GOOGLE_PLACES_SERVER_KEY` secret if
  restaurant search isn't coming back; `generate-avatar` is also dormant.
- Rename bundle id / URL scheme to Stampd before first release (update
  Supabase auth redirect allow-list at the same time).
- `demo` seed scripts in the web repo still create meals; rewrite for travel
  or tear down before launch.

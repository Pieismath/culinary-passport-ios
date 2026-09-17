# Stampd roadmap (travel)

Status: ✅ shipped · 🔶 partial · ⛔ blocked · ⬜ not started

The culinary-era plan is in `archive/2026-07-culinary-roadmap.md`.

## 1. Passport core — ✅
- ✅ Globe with visited / bucket list / small-country dots, light + dark
- ✅ Memories: photos, place (Apple Maps), date, story, visibility
- ✅ Stamps from memories, the checklist, and the photo-library scan
- ✅ Stamp moments + share cards (stamp, batch, passport, postcard, year)
- ✅ Passport: stats, continents, goal, bucket list, stamp book, trips, map
- ✅ Year in travel

## 2. Social — 🔶
- ✅ Friends feed + new-stamps strip, Discover, activity, reactions, comments
- ✅ Follow / friends (mutual) / people search / profiles with their globe
- ✅ Groups: shared globe lenses, leaderboard, chat with shared memories
- ✅ Moderation: report + block everywhere, account deletion
- ⛔ Push notifications (paid Apple account): new follower, reaction,
  comment, group message, friend stamped a new country
- ⬜ Universal links for group invites and profiles

## 3. Retention experiments — ⬜ (measure before building more)
- ✅ Local "On this day" reminders
- ⬜ Trip mode: "I'm in Japan" → friends see a live trip, daily memory prompt
- ⬜ Cities and regions as a second tier of stamps (domestic travel counts)
- ⬜ "Ask a friend who's been" — tips thread on a country
- ⬜ Group trip planning: shared bucket-list overlap, dates, itinerary
- ⬜ Photo book / printed passport (monetization candidate)

## Standing decisions
- Never gate the core loop (stamping, memories, globe, groups).
- The photo-library scan stays on-device; only chosen countries are saved.
- Privacy lives in RLS; the client never filters for privacy.

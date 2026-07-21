# Culinary Passport — full product & codebase review (2026-07-22)

A cold-eyes pass over everything built so far, judged against one question:
**what makes someone open this app in week six?** Beli is the reference —
not to copy it, but because it solved the same retention problem for the
same audience.

---

## 1. The structural problem: the globe saturates

The core loop — log a meal, a country fills in — is genuinely delightful
and completely **finite**. A typical eater reaches their 15–20 usual
cuisines in the first month, and then the globe stops changing. New
cuisines become rare events (that's what makes them special), which means
the *primary* surface goes quiet exactly when habit needs to form.

Beli never has this problem because its unit is the **restaurant**
(infinite) not the **country** (174, practically ~40). Their loop:
every meal is loggable, every log re-ranks your list, every rank is
social currency.

**The answer isn't to abandon the globe — it's the app's identity and
trophy case. It's to layer an infinite loop underneath it:**

- The globe = the *passport* (finite, prestige, shareable).
- Restaurants = the *journal* (infinite, daily, rankable).

Concretely: a per-cuisine restaurant history already exists in the data
(tap Thailand → your five Thai meals). Promote it: **"your Thai places,
ranked"**, best-of lists per cuisine, and later Beli-style pairwise
ranking ("better than Chat Thai?") instead of raw stars. Every dinner
becomes content again, even the 30th Thai one.

---

## 2. Retention features, in priority order

### 2.1 Want to Try (the missing half of the app) — HIGHEST VALUE
The single biggest reason people open a food app between meals is
**deciding where to eat**. Beli's "Want to Try" list is arguably their
core retention surface. We already have the `wishlist` table live in the
DB — **the web app had this feature and iOS never ported it.**

- Long-press menu on a country: *Log a meal / Add to Want to Try*.
- Country panel: bookmark toggle.
- Amber dashed treatment on the globe (web parity).
- Dice/spin: "Only my Want-to-Try" filter (web parity).
- Recommendations: "Save for later" on every restaurant pick.
- Restaurant-level want-to-try too (a `restaurant_wishlist` or a nullable
  `restaurant_name` on wishlist rows) — that's the one people use weekly.

### 2.2 Push notifications — the retention *infrastructure*
Chat, reactions, follows, and groups are all built — and all inert,
because nothing can call the user back. This is now the single most
valuable $99 the project can spend (paid Apple account). Sequence:
entitlement → APNs delivery in `notify-group` (scaffold exists, webhook
+ token table already live) → notify on: group message, reply to you,
reaction to your meal, new follower, friend's first-ever cuisine.

### 2.3 Stamp moments + share cards — delight AND growth
The web version's signature moment — the ink-stamp *thud* when a country
unlocks — never made it to iOS. First meal in a new cuisine should be an
event: full-screen stamp animation, haptic, confetti-adjacent, and a
**share card** (globe + "Cuisine #23: Ethiopian 🇪🇹") sized for
stories/messages. Wrapped should also have a share button — it's the
most shareable screen in the app and currently has no exit.

Share cards are the organic acquisition channel. An app like this grows
by screenshot; make the screenshot gorgeous and one-tap.

### 2.4 Activity tab
There is currently **no way to know someone noticed you** — no "Jenn
followed you", "Mom reacted 😋 to your ramen", "2 replies in Sydney
Eats". Social apps die without this surface. A simple `activity` feed
(derivable from follows/reactions/comments tables, or a small
`notifications` table written by triggers) + a badge on the People tab.
This is also what push notifications deep-link into.

### 2.5 Reactions & comments on meals (not just group chat)
The Discover feed is read-only: you see a friend's meal and can do
*nothing*. Extending the chat mechanics (any-emoji reactions, inline
comments) to entries themselves closes the loop that makes logging
socially rewarding. Schema: `entry_reactions` / `entry_comments` tables
mirroring the post ones, visibility inherited from the entry.

### 2.6 Yearly goal + streak surfacing
Beli's hook, verbatim: *"You tried 1 spots in 2025! How many in 2026?"*
We compute streaks and this-year counts already; add a user-set goal
(profiles column), a progress ring on the profile, and a gentle
streak-at-risk state. Cheap, proven mechanic.

### 2.7 Onboarding
Today: sign in → empty parchment globe, figure it out. The demo cast
proves how much better the app looks *with data*. First-run flow:
1. Pick your color (exists in edit-profile, promote it),
2. "Log your first meal" guided (pre-opened sheet),
3. Stamp moment plays (first delight in minute one),
4. Find friends / join a group by code (the Jenn step).

### 2.8 Faster logging
The entry sheet has ~13 inputs. Fine for the enthusiast's third entry,
heavy for the first. A quick-log path: photo → restaurant autocomplete
(country inferred from the Places result) → star rating → Done; details
editable later. Target: under 15 seconds.

### 2.9 Group leaderboard
The group globe answers "where have we been"; a leaderboard answers
"who's winning" — cuisines count, rare finds, streaks per member. All
computable from loaded data; one section on the group home. Friendly
competition is a proven group-chat re-opener.

---

## 3. App Store blockers (retention needs users; users need shipping)

| Blocker | Status | Note |
|---|---|---|
| Paid Apple Developer account | ❌ | Gates push, real Sign in with Apple, TestFlight |
| **In-app account deletion** | ❌ missing | Apple guideline 5.1.1(v) — **guaranteed rejection** for account-based apps without it |
| **UGC moderation** | ❌ missing | Photos + chat + profiles ⇒ Apple requires report content, block user, and terms (guideline 1.2) |
| App icon | ❌ none | `ASSETCATALOG_COMPILER_APPICON_NAME` deliberately empty |
| Launch screen | blank white | Paper-color it; trivial |
| Password reset | ❌ missing | Email auth exists with no "Forgot password" (`resetPasswordForEmail` + deep link) |
| Privacy policy + App Privacy labels | ❌ | Needed at submission |
| Demo data in prod | ⚠️ live | `teardown-demo.py` + `teardown-jason-meals.py` before real users |

Account deletion note: needs an edge function (client can't call
`auth.admin`); cascade delete + storage cleanup, mirroring what the
teardown scripts already do.

---

## 4. Code health

Overall: genuinely good shape. Consistent architecture (service
singleton, ports of web logic, RLS-first thinking), zero build warnings,
geometry + recommender under test, live E2E scripts for backend claims.
Debt worth tracking, roughly prioritized:

1. **No caching/offline** — every tab cold-load is a network spinner.
   Simplest high-impact fix: persist last-fetched JSON per surface and
   render stale-while-refreshing. The app would *feel* twice as fast.
2. **No pagination** — feed (150), chat (50), entries/journal
   (unbounded). Fine at family scale; cliff at community scale. Add
   cursor pagination to chat + feed first.
3. **Silent failures** — pervasive `try?` swallows errors (group load,
   reactions, follows…). At minimum: a shared toast/error pattern.
4. **`followCounts`** fetches all rows to count — use PostgREST
   `count=exact, head:true`.
5. **`discoverFeed`** can under-fill (fetch 150 → filter client-side)
   and does a second profiles round-trip — a DB view or RPC would do it
   in one.
6. **Chat realtime = reload-world on every event** — fine now; queue a
   targeted merge later.
7. **`updateEntry` doesn't delete removed photos** from storage
   (`deleteEntry` does) — slow orphan accumulation in a private bucket.
8. **Username uniqueness is case-sensitive** — `jason` and `Jason` can
   both exist; normalize to lowercase on save (or a citext/unique index
   on lower()).
9. **PhotoURLCache / signedUrls maps grow unboundedly** — trivial caps.
10. **Analytics: none.** Before inviting users, add a minimal,
    privacy-respecting event log (even a Supabase `events` table:
    app_open, meal_logged, chat_sent) — otherwise "did retention
    improve?" is unanswerable.
11. **Tests** cover geometry + recommender only. The RLS/E2E harness
    lives in ad-hoc session scripts; worth promoting the critical ones
    (visibility matrix, photo signing) into a repeatable script in
    `scripts/` so backend changes stay honest.
12. Open security follow-ups (tracked): places-proxy per-user rate
    limit; notify-group webhook secret when push lands.
13. Hard-coded "of 6 continents" in profile — derive from data (Natural
    Earth also has an "Oceania"/"Seven seas" quirk worth a bounds check).
14. Group chat can't send photos (`group_posts.photos` exists unused) —
    add when photos-in-chat matters.

---

## 5. Remove / simplify

- **SyncedMealsView** — weakest surface. Overlaps the group globe
  (consensus lens) and chat ("Propose tonight" is a chat message).
  Fold both into the group home (a "shared" chip + a propose button in
  chat) and delete the screen. One less place to maintain.
- **Deprecated web app** — already documented as such; don't spend
  another minute on it beyond the backend folder.
- **Demo cast** — tear down before launch (scripts exist).
- The old `-journalMode list` debug arg still accepts a dead value —
  cosmetic.

---

## 6. Suggested order of attack

**Phase 0 — shippable** (mostly small, one purchase):
paid account → push entitlement; account deletion; block/report + terms;
app icon + launch screen; password reset; privacy policy; teardown demo.

**Phase 1 — retention core:**
Want to Try everywhere → stamp moments + share cards (incl. Wrapped
share) → activity tab wired to push → yearly goal.

**Phase 2 — social depth:**
reactions/comments on meals → group leaderboard → invite links
(universal links for groups/profiles).

**Phase 3 — the infinite loop:**
restaurant lists ranked per cuisine → quick-log → pairwise ranking
experiment.

The honest one-line summary: **the app is feature-rich but loop-poor.**
It has more built surface than Beli's first year — what it needs now is
not more features but the four or five mechanics above that pull people
back, and the unglamorous Phase 0 that lets real users in at all.

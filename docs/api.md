# Port Makan backend API (for the frontend)

The backend is Supabase. The frontend talks to it with `@supabase/supabase-js` v2. Security is enforced in the database, so the frontend never needs secret keys.

## Setup

```bash
npm install --save-exact @supabase/supabase-js
```

`.env.local` (not committed; see `.env.example`):

```
VITE_SUPABASE_URL=https://sohgkeyykfkbiysvbozb.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=sb_publishable_ngGAUC3UL23lOjFsYigUXg_ayKNTsPz
```

```js
// src/lib/supabase.js
import { createClient } from '@supabase/supabase-js'
export const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY
)
```

Use only the **publishable** key in the frontend. Never use the `service_role` or secret key there.

## Values

- **category:** `warung` · `mamak` · `kopitiam` · `hawker_stall` · `night_market` · `cafe` · `other`
- **price_range:** `1` = RM, `2` = RM RM, `3` = RM RM RM
- **halal_status:** `halal` · `non_halal` · `null` (unknown)
- **opening_hours:** `{"mon": [["07:00","14:00"]], "tue": [], ...}`. An empty list means closed that day. `null` means unknown.
- **Launch area:** lat 5.90–6.35, lng 100.20–100.55 (Alor Setar). A spot outside this area is rejected.

## Login (FR-01, FR-02)

```js
await supabase.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: window.location.origin } })
await supabase.auth.signOut()
const { data: { user } } = await supabase.auth.getUser()
supabase.auth.onAuthStateChange((_event, session) => { /* update UI */ })
```

A profile row is created automatically the first time someone signs in. Show the PDPA privacy notice at sign-up (NFR-14). When the user accepts it:

```js
await supabase.from('profiles').update({ privacy_accepted_at: new Date().toISOString() }).eq('id', user.id)
```

## Map pins and list view (FR-07, FR-32–35, FR-37)

Call this whenever the map moves or a filter changes. Pass Leaflet's `map.getBounds()`.

```js
const b = map.getBounds()
const { data, error } = await supabase.rpc('spots_in_view', {
  min_lng: b.getWest(), min_lat: b.getSouth(), max_lng: b.getEast(), max_lat: b.getNorth(),
  p_category: null,      // or 'mamak'
  p_search: null,        // text typed in the search box
  p_min_rating: null,    // e.g. 4
  p_price: null,         // max price 1–3
  p_halal: null,         // true = halal only
  p_vegetarian: null,    // true = vegetarian-friendly only
  p_near_lat: null,      // user location, to sort by distance (only after they allow it)
  p_near_lng: null,
})
// each row: id, name, category, lat, lng, rating_avg, review_count, price_range,
//           halal_status, is_vegetarian_friendly, cover_photo_path, distance_m
```

Photo URL from a path:

```js
supabase.storage.from('spot-photos').getPublicUrl(path).data.publicUrl
```

## Spot page (FR-21–23)

```js
const { data: spot } = await supabase
  .from('spots')
  .select(`id, name, category, lat, lng, address, opening_hours, price_range, halal_status,
           is_vegetarian_friendly, rating_avg, review_count, created_by,
           spot_photos ( id, storage_path, alt_text ),
           reviews ( id, rating, body, must_try_dish, created_at, user_id,
                     profiles ( display_name, photo_url ) )`)
  .eq('id', spotId)
  .order('created_at', { referencedTable: 'reviews', ascending: false })
  .single()
```

## Add a spot (FR-13–18)

1. Warn about duplicates first (FR-18):

```js
const { data: dupes } = await supabase.rpc('nearby_duplicates', { p_name: name, p_lat: lat, p_lng: lng })
// if dupes.length > 0: "Is this the same place as …?"
```

2. Insert the spot. `created_by` is set automatically.

```js
const { data: spot, error } = await supabase.from('spots')
  .insert({ name, category, lat, lng, address, price_range, halal_status, is_vegetarian_friendly, opening_hours })
  .select('id').single()
```

3. Upload each photo. **Compress it first to under 500 KB, as WebP or JPEG** (NFR-03), for example with `browser-image-compression`. The bucket only accepts JPG, PNG and WebP up to 5 MB. The first folder of the path **must** be the user's id.

```js
const path = `${user.id}/${crypto.randomUUID()}.webp`
await supabase.storage.from('spot-photos').upload(path, file, { contentType: 'image/webp' })
await supabase.from('spot_photos').insert({ spot_id: spot.id, storage_path: path, alt_text: `Photo of ${name}` })
```

Only the person who added a spot, or an admin, can add photos to it, edit it or delete it:

```js
await supabase.from('spots').update({ address }).eq('id', spotId)
```

## Reviews (FR-26, FR-27, FR-29)

```js
await supabase.from('reviews').insert({ spot_id, rating: 5, body: 'Sedap!', must_try_dish: 'Mee rebus' })
await supabase.from('reviews').update({ rating: 4 }).eq('id', reviewId)
await supabase.from('reviews').delete().eq('id', reviewId)
```

A member can leave one review per spot. A second one fails with error code `23505`, so show "You already reviewed this spot. Edit your review instead." The spot's `rating_avg` and `review_count` update automatically.

## Profile (FR-03, FR-05)

```js
await supabase.from('profiles').select('id, display_name, photo_url, role').eq('id', user.id).single()
await supabase.from('profiles').update({ display_name }).eq('id', user.id)
```

Use `role === 'admin'` to show the admin buttons. The database checks admin rights again on every change, so hiding buttons is only for looks.

## Errors to handle (NFR-17)

| What happened | How to spot it | What to show |
|---|---|---|
| Daily limit (20 spots / 50 reviews) | `error.code === 'P0001'`, `error.hint` is `daily_spot_limit` or `daily_review_limit` | `error.message` (already friendly) |
| Already reviewed | `error.code === '23505'` | "You already reviewed this spot." |
| Outside Alor Setar | `error.code === '23514'` and the message contains `spots_in_launch_area` | "Port Makan only covers Alor Setar for now." |
| Bad text (`<` or `>`, too long) | `error.code === '23514'` | "Please check the name and try again." |
| Not allowed (not signed in, not owner, banned) | `error.code === '42501'`, or an update that changes 0 rows | "You can't change this." |
| Photo too big or wrong type | storage upload error | "Use a JPG, PNG or WebP under 5 MB." |

Never render user text as HTML (no `dangerouslySetInnerHTML`). React escapes text by default (NFR-10).

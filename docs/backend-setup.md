# Backend setup (Supabase)

Project: `port-makan`, ref `sohgkeyykfkbiysvbozb`, region Asia-Pacific.

## 1. Put the database code into Supabase

The code is in `supabase/migrations/` (tables, security rules, photo storage) and `supabase/seed.sql` (test spots).

**Option A: the CLI (recommended, keeps a history of changes).** Run these from the repo folder:

```bash
npx supabase login
npx supabase link --project-ref sohgkeyykfkbiysvbozb
npx supabase db push --include-seed
```

`link` asks for the database password you chose when you created the project.

**Option B: the dashboard.** Open **SQL Editor → New query**, then paste and run each file in this order:
1. `supabase/migrations/20261102145604_init_schema.sql`
2. `supabase/migrations/20261102145605_photo_storage.sql`
3. `supabase/seed.sql`

Use one method only. If you start with B, keep using the SQL Editor for later changes too.

## 2. Google login (FR-01)

1. Go to **Google Cloud Console → APIs & Services**.
   - Set up the **OAuth consent screen**: app name "Port Makan", type External, and your email.
   - Under **Credentials**, choose **Create credentials → OAuth client ID → Web application**.
   - Under **Authorised redirect URIs**, add `https://sohgkeyykfkbiysvbozb.supabase.co/auth/v1/callback`
2. In Supabase, open **Authentication → Sign In / Providers → Google**. Turn it on and paste the Client ID and Client Secret.
3. In Supabase, open **Authentication → URL Configuration**.
   - **Site URL**: `http://localhost:5173` for now. Change it to the Vercel address when the app goes live.
   - **Redirect URLs**: add `http://localhost:5173/**`, and later `https://<your-app>.vercel.app/**`.

The Client Secret stays in Supabase. Never put it in the code or the chat.

## 3. Make yourselves admins (FR-42)

Each of you signs in to the app once. Then run this in the SQL Editor:

```sql
update public.profiles set role = 'admin'
where id in (select id from auth.users where email in ('you@gmail.com', 'partner@gmail.com'));
```

## 4. Check it worked

- **Table Editor**: shows `profiles`, `spots`, `spot_photos` and `reviews`, each with "RLS enabled".
- **Storage**: shows a bucket called `spot-photos`.
- **Advisors → Security Advisor**: has no errors. Warnings about the `postgis` extension or `spatial_ref_sys` are normal.

## 5. Before launch

- Remove the test spots: `delete from public.spots where name like '[TEST]%';`
- Set up weekly backups (NFR-16). The free plan has no automatic backups. This will be a GitHub Action that runs `supabase db dump` every week.

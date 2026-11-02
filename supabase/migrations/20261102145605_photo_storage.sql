-- Port Makan: photo storage (FR-13, NFR-03, NFR-12)
-- Bucket "spot-photos": public to read, JPG/PNG/WebP only, 5 MB max.
-- The frontend compresses each photo to under 500 KB before uploading (NFR-03).
-- Files go in a folder named after the uploader: <user id>/<random id>.webp

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('spot-photos', 'spot-photos', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Reading needs no policy: the bucket is public, so photos load by their public URL.

create policy "Members upload photos to their own folder"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'spot-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and (select private.can_write())
  );

create policy "Members delete their own photos, admins any"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'spot-photos'
    and ((storage.foldername(name))[1] = (select auth.uid())::text or (select private.is_admin()))
  );

-- TEST DATA for development only. Every name starts with "[TEST]".
-- Remove before launch:  delete from public.spots where name like '[TEST]%';
-- Coordinates are spread around Alor Setar town centre so the map has pins to show.
insert into public.spots (name, category, lat, lng, address, price_range, halal_status, is_vegetarian_friendly, opening_hours) values
  ('[TEST] Warung Pak Mat',        'warung',       6.1248, 100.3655, 'Jalan Langgar, Alor Setar',        1, 'halal',     false, '{"mon":[["07:00","14:00"]],"tue":[["07:00","14:00"]],"wed":[["07:00","14:00"]],"thu":[["07:00","14:00"]],"fri":[],"sat":[["07:00","14:00"]],"sun":[["07:00","14:00"]]}'),
  ('[TEST] Mamak Corner 24 Jam',   'mamak',        6.1199, 100.3701, 'Jalan Sultan Badlishah',           1, 'halal',     true,  '{"mon":[["00:00","24:00"]],"tue":[["00:00","24:00"]],"wed":[["00:00","24:00"]],"thu":[["00:00","24:00"]],"fri":[["00:00","24:00"]],"sat":[["00:00","24:00"]],"sun":[["00:00","24:00"]]}'),
  ('[TEST] Kopitiam Lama',         'kopitiam',     6.1221, 100.3689, 'Lebuhraya Darul Aman',             1, null,        true,  null),
  ('[TEST] Gerai Laksa Teluk Kechai','hawker_stall',6.1105, 100.3480, 'Teluk Kechai',                    1, 'halal',     false, null),
  ('[TEST] Pasar Malam Simpang Kuala','night_market',6.1330, 100.3550,'Simpang Kuala',                  1, 'halal',     true,  '{"wed":[["17:00","23:00"]]}'),
  ('[TEST] Kafe Padi',             'cafe',         6.1287, 100.3742, 'Jalan Putra',                      2, 'halal',     true,  null),
  ('[TEST] Nasi Kandar Seberang',  'mamak',        6.1173, 100.3632, 'Jalan Tunku Ibrahim',              2, 'halal',     false, null),
  ('[TEST] Char Kuey Teow Stall',  'hawker_stall', 6.1235, 100.3712, 'Pekan Cina',                       1, 'non_halal', false, null),
  ('[TEST] Kopi Tarik Station',    'cafe',         6.1312, 100.3801, 'Jalan Stadium',                    2, 'halal',     true,  null),
  ('[TEST] Warung Ikan Bakar',     'warung',       6.1050, 100.3720, 'Jalan Kuala Kedah',                2, 'halal',     false, null),
  ('[TEST] Nasi Lemak Kampung',    'other',        6.1400, 100.3600, 'Kampung Berjaya',                  1, 'halal',     false, null),
  ('[TEST] AIU Area Food Court',   'hawker_stall', 6.1530, 100.4100, 'Near Albukhary International University', 1, 'halal', true, null);

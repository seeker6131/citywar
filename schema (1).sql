-- ศึกชิงเมือง v2 : ฐานข้อมูลและกติกาเกมทั้งหมด (รันใน Supabase > SQL Editor ได้ซ้ำหลายครั้ง)
-- ทุกอย่างคำนวณที่เซิร์ฟเวอร์ ตารางปิดหมด เข้าได้ทางฟังก์ชัน api_* เท่านั้น

-- ล้างของรุ่นแรก (รุ่นที่ยังวางผังเมืองไม่ได้) ถ้ามี
do $$ begin
  if exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'buildings')
     and not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'buildings' and column_name = 'x') then
    drop table if exists battles, buildings, players cascade;
  end if;
end $$;
drop function if exists api_upgrade(text), api_train(int), api_target(uuid), api_attack(uuid, int),
  g_rate(int), g_cap(int), g_def(int, int, int), _settle(uuid);

create table if not exists players(
  id uuid primary key,
  name text not null check (char_length(name) between 2 and 30),
  province text not null check (char_length(province) between 2 and 30),
  is_bot boolean not null default false,
  coins bigint not null default 800,
  gems int not null default 0,
  inf int not null default 5,
  tanks int not null default 0,
  trophies int not null default 0,
  shield_until timestamptz not null default now() + interval '12 hours',
  vip_until timestamptz not null default now(),
  hat int not null default 1,
  suit int not null default 0,
  hats int[] not null default '{0,1,2}',
  suits int[] not null default '{0,1,2}',
  last_daily date,
  xp int not null default 0,
  plots int[],
  rank_item int not null default 0,
  created_at timestamptz not null default now()
);
create unique index if not exists players_name_uq on players(lower(name));
create index if not exists players_trophies_ix on players(trophies desc);

create table if not exists buildings(
  id bigserial primary key,
  player_id uuid not null references players(id) on delete cascade,
  kind text not null check (kind in ('hq','house','farm','gas','office','market','vault','power','school','water','fire','lab','port','airport','barracks','factory','hospital','turret','radar','aa','wall','road')),
  x int not null check (x between 0 and 27),
  y int not null check (y between 0 and 27),
  level int not null default 0,          -- 0 = กำลังสร้างครั้งแรก
  done_at timestamptz,                   -- เวลาที่งานก่อสร้าง/อัปเกรดเสร็จ
  tax_at timestamptz not null default now(),
  unique(player_id, x, y)
);

alter table players add column if not exists xp int not null default 0;
alter table players add column if not exists plots int[];
alter table players add column if not exists rank_item int not null default 0;
alter table players alter column gems set default 0;
do $$ begin
  alter table buildings drop constraint if exists buildings_player_id_x_y_key;
  alter table buildings add constraint buildings_player_id_x_y_key unique (player_id, x, y) deferrable initially immediate;
exception when duplicate_table or duplicate_object then null; end $$;
alter table buildings drop constraint if exists buildings_x_check;
alter table buildings drop constraint if exists buildings_y_check;
alter table buildings add constraint buildings_x_check check (x between 0 and 27);
alter table buildings add constraint buildings_y_check check (y between 0 and 27);
alter table buildings drop constraint if exists buildings_kind_check;
alter table buildings add constraint buildings_kind_check check (kind in ('hq','house','farm','gas','office','market','vault','power','school','water','fire','lab','port','airport','barracks','factory','hospital','turret','radar','aa','wall','road'));

create table if not exists battles(
  id bigserial primary key,
  attacker uuid not null, defender uuid not null,
  attacker_name text not null, defender_name text not null,
  win boolean not null, loot bigint not null, trophies int not null,
  at timestamptz not null default now()
);
create index if not exists battles_att_ix on battles(attacker, at desc);
create index if not exists battles_def_ix on battles(defender, at desc);

alter table players enable row level security;
alter table buildings enable row level security;
alter table battles enable row level security;

-- ---------- สูตรเกม ----------
create or replace function g_kinds() returns text[] language sql immutable as $$
  select array['house','farm','gas','office','market','vault','power','school','water','fire','lab','port','airport','barracks','factory','hospital','turret','radar','aa','wall','road'] $$;
create or replace function g_base(k text) returns int[] language sql immutable as $$   -- {ราคาเริ่ม, วินาทีสร้าง}
  select case k when 'hq' then '{600,60}' when 'house' then '{100,10}' when 'farm' then '{80,8}' when 'gas' then '{350,20}'
    when 'office' then '{700,30}' when 'market' then '{300,20}' when 'vault' then '{200,15}' when 'power' then '{400,25}'
    when 'school' then '{300,20}' when 'water' then '{350,20}' when 'fire' then '{300,20}' when 'lab' then '{800,40}'
    when 'port' then '{1200,50}' when 'airport' then '{2000,60}' when 'barracks' then '{250,20}' when 'factory' then '{600,40}'
    when 'hospital' then '{500,30}' when 'turret' then '{300,20}' when 'radar' then '{500,30}' when 'aa' then '{450,30}' when 'wall' then '{50,0}' when 'road' then '{10,0}' end::int[] $$;
create or replace function g_cost(k text, lvl int) returns bigint language sql immutable as $$
  select round((g_base(k))[1] * power(1.7, lvl))::bigint $$;
create or replace function g_secs(k text, lvl int) returns int language sql immutable as $$
  select ((g_base(k))[2] * power(2, lvl))::int $$;
create or replace function g_max(k text, hq int) returns int language sql immutable as $$
  select case k when 'hq' then 1 when 'house' then 2 + 2 * hq when 'farm' then 2 + hq / 2 when 'gas' then hq / 2 when 'office' then hq / 3
    when 'market' then (hq + 1) / 2 when 'vault' then 1 + hq / 3 when 'power' then least(3, (hq + 1) / 2)
    when 'school' then least(1, hq / 2) when 'water' then least(1, hq / 2) when 'fire' then least(1, hq / 2)
    when 'lab' then least(1, hq / 3) when 'port' then least(1, hq / 4) when 'airport' then least(1, hq / 5)
    when 'barracks' then 1 + hq / 3 when 'factory' then hq / 2 when 'hospital' then least(2, hq / 2)
    when 'turret' then 1 + hq when 'radar' then hq / 3 when 'aa' then hq / 2 when 'wall' then 4 + 4 * hq when 'road' then 80 else 0 end $$;
create or replace function g_tax(k text, lvl int) returns numeric language sql immutable as $$
  select case k when 'house' then 240 * lvl when 'farm' then 150 * lvl when 'gas' then 400 * lvl when 'office' then 500 * lvl
    when 'market' then 600 * lvl else 0 end::numeric $$;
-- ราคาชุดเจ้าเมือง (เพชรแดง) 0 = ฟรี
create or replace function g_avprice(part text, i int) returns int language sql immutable as $$
  select case when i < 0 or i > 4 then null when i <= 2 then 0 when part = 'hat' then (array[40, 120])[i - 2] else (array[40, 80])[i - 2] end $$;

create or replace function _hq(pid uuid) returns int language sql stable security definer set search_path = public as $$
  select coalesce((select level from buildings where player_id = pid and kind = 'hq'), 1) $$;
create or replace function _cap(pid uuid) returns bigint language sql stable security definer set search_path = public as $$
  select 2000 + coalesce((select sum(round(3000 * power(level, 1.5))) from buildings where player_id = pid and kind = 'vault' and level >= 1), 0)::bigint $$;
-- ยศเจ้าเมือง: 0 คนธรรมดา 1 นายก 2 พลตรี 3 พลโท 4 พลเอก 5 จอมพล 6 พระเจ้า (ได้จากการสุ่มตัวละครเท่านั้น)
-- ยศปกติมาจากถ้วยรางวัลที่สะสมจากการตีเมืองคนอื่น: 100 / 300 / 700 / 1500 / 3000
create or replace function _rank(pid uuid) returns int language sql stable security definer set search_path = public as $$
  select greatest(p.rank_item, case when p.trophies >= 3000 then 5 when p.trophies >= 1500 then 4 when p.trophies >= 700 then 3
    when p.trophies >= 300 then 2 when p.trophies >= 100 then 1 else 0 end) from players p where p.id = pid $$;
-- โบนัสโจมตี/ป้องกัน: ยศละ +5% จอมพล +25% พระเจ้า +35% (และภาษี +10%)
create or replace function _rbonus(r int) returns numeric language sql immutable as $$
  select case when r >= 6 then 0.35 else 0.05 * r end $$;
-- เลเวลตัวละครจาก Exp / จำนวนที่ดินสูงสุดที่ถือได้ (7x7 แปลง)
create or replace function _lvl(x int) returns int language sql immutable as $$ select floor(sqrt(x / 40.0))::int + 1 $$;
create or replace function _maxplots(pid uuid) returns int language sql stable security definer set search_path = public as $$
  select least(49, 2 + _lvl(coalesce((select xp from players where id = pid), 0))) $$;
create or replace function _plotprice(n int) returns bigint language sql immutable as $$ select round(300 * power(1.45, greatest(0, n)))::bigint $$;
create or replace function _owns(pid uuid, x int, y int) returns boolean language sql stable security definer set search_path = public as $$
  select x between 0 and 27 and y between 0 and 27 and exists (select 1 from players where id = pid and ((y / 4) * 7 + (x / 4)) = any(plots)) $$;
create or replace function _addxp(pid uuid, n int) returns void language sql security definer set search_path = public as $$
  update players set xp = xp + greatest(0, n) where id = pid $$;
-- ตัวคูณภาษีทั้งเมือง: โรงไฟฟ้า +8%/ระดับ สาธารณูปโภคอื่น +3%/ระดับ VIP x1.2
create or replace function _boost(pid uuid) returns numeric language sql stable security definer set search_path = public as $$
  select (1 + coalesce((select sum(case when kind = 'power' then 0.08 else 0.03 end * level) from buildings
      where player_id = pid and level >= 1 and kind in ('power','school','water','fire','lab','port','airport')), 0))
    * (select case when vip_until > now() then 1.2 else 1 end from players where id = pid)
    * (case when _rank(pid) >= 6 then 1.1 else 1 end) $$;
-- โรงพยาบาลลดการสูญเสียกำลังพล 6%/ระดับ สูงสุด 48%
create or replace function _heal(pid uuid) returns numeric language sql stable security definer set search_path = public as $$
  select least(0.48, 0.06 * coalesce((select sum(level) from buildings where player_id = pid and kind = 'hospital' and level >= 1), 0)) $$;
create or replace function _def(pid uuid) returns numeric language sql stable security definer set search_path = public as $$
  select round((40 + 20 * _hq(pid)
    + coalesce((select sum(case kind when 'turret' then 70 * power(level, 1.3) when 'radar' then 45 * power(level, 1.2) when 'aa' then 60 * power(level, 1.25) else 12 * power(level, 1.2) end)
        from buildings where player_id = pid and kind in ('turret', 'radar', 'aa', 'wall') and level >= 1), 0)
    + (select inf * 4 + tanks * 20 from players where id = pid)) * (1 + _rbonus(_rank(pid)))) $$;
-- สัดส่วนอาคารเศรษฐกิจที่ไม่มีป้อมปืนคุ้มกันในระยะ 2 ช่อง (0 ถึง 1)
create or replace function _uncovered(pid uuid) returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(avg(case when exists (select 1 from buildings t where t.player_id = pid and t.kind = 'turret' and t.level >= 1
      and abs(t.x - b.x) <= 2 and abs(t.y - b.y) <= 2) then 0 else 1 end), 0)
  from buildings b where b.player_id = pid and (g_tax(b.kind, 1) > 0 or b.kind = 'vault') and b.level >= 1 $$;
create or replace function _layout(pid uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'x', x, 'y', y, 'level', level)), '[]'::jsonb) from buildings where player_id = pid $$;

create or replace function _finish(pid uuid) returns void language sql security definer set search_path = public as $$
  update buildings set tax_at = case when level = 0 then now() else tax_at end, level = level + 1, done_at = null
  where player_id = pid and done_at is not null and done_at <= now() $$;

create or replace function _me() returns uuid language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'ยังไม่ได้เข้าสู่ระบบ'; end if;
  if not exists (select 1 from players where id = uid) then raise exception 'ยังไม่ได้ตั้งเมือง'; end if;
  return uid;
end $$;

-- เก็บภาษี: อาคารสะสมภาษีได้สูงสุด 2 ชั่วโมง แล้วหยุดจนกว่าจะมาเก็บ
create or replace function _collect(pid uuid, bid bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare p players; space bigint; r buildings; amt bigint; take bigint; rate numeric; hrs numeric; total bigint := 0; items jsonb := '[]'::jsonb; bo numeric;
begin
  select * into p from players where id = pid for update;
  bo := _boost(pid);
  space := greatest(0, _cap(pid) - p.coins);
  for r in select * from buildings where player_id = pid and g_tax(kind, 1) > 0 and level >= 1 and (bid is null or id = bid) order by id loop
    rate := g_tax(r.kind, r.level) * bo;
    hrs := least(2.0, extract(epoch from now() - r.tax_at) / 3600.0);
    amt := floor(rate * hrs);
    take := least(amt, space);
    if take <= 0 then continue; end if;
    if take = amt then update buildings set tax_at = now() where id = r.id;
    else update buildings set tax_at = now() - make_interval(secs => ((amt - take) / rate * 3600)::double precision) where id = r.id; end if;
    space := space - take; total := total + take;
    items := items || jsonb_build_object('id', r.id, 'amount', take);
  end loop;
  if total > 0 then update players set coins = coins + total where id = pid; end if;
  return jsonb_build_object('total', total, 'items', items, 'full', space <= 0);
end $$;

-- ---------- ตั้งเมือง ----------
create or replace function api_join(p_name text, p_province text) returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); nm text := btrim(coalesce(p_name, ''));
begin
  if uid is null then raise exception 'ยังไม่ได้เข้าสู่ระบบ'; end if;
  if exists (select 1 from players where id = uid) then raise exception 'มีเมืองอยู่แล้ว'; end if;
  if char_length(nm) < 2 or char_length(nm) > 16 then raise exception 'ชื่อต้องยาว 2-16 ตัวอักษร'; end if;
  if char_length(coalesce(p_province, '')) < 2 or char_length(p_province) > 30 then raise exception 'เลือกจังหวัดก่อน'; end if;
  if exists (select 1 from players where lower(name) = lower(nm)) then raise exception 'ชื่อนี้มีคนใช้แล้ว'; end if;
  insert into players(id, name, province, plots) values (uid, nm, p_province, array[16, 17]);   -- แปลงของศูนย์บัญชาการ + ที่ดินฟรี 1 แปลง
  insert into buildings(player_id, kind, x, y, level, tax_at) values (uid, 'hq', 9, 9, 1, now());
  return jsonb_build_object('ok', true);
end $$;

-- ---------- สถานะเมือง ----------
create or replace function api_state() returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); daily boolean := false; p players; hq int; vip numeric; ks text[] := g_kinds(); col jsonb;
begin
  if uid is null then raise exception 'ยังไม่ได้เข้าสู่ระบบ'; end if;
  if not exists (select 1 from players where id = uid) then return jsonb_build_object('player', null); end if;
  perform _finish(uid);
  col := _collect(uid, null);   -- เก็บภาษีอัตโนมัติ
  update players set coins = coins + 100, last_daily = current_date where id = uid and (last_daily is null or last_daily < current_date);
  daily := found;
  select * into p from players where id = uid;
  hq := _hq(uid); vip := _boost(uid);
  return jsonb_build_object(
    'now', now(), 'daily', daily, 'collected', col, 'rank', _rank(uid), 'level', _lvl(p.xp), 'xp', p.xp, 'xp_next', 40 * power(_lvl(p.xp), 2)::int, 'plots', to_jsonb(p.plots), 'max_plots', _maxplots(uid), 'plot_price', _plotprice(coalesce(array_length(p.plots, 1), 2) - 2), 'hq', hq, 'boost', vip, 'heal', _heal(uid), 'cap', _cap(uid), 'defense', _def(uid), 'uncovered', _uncovered(uid),
    'builders', case when p.vip_until > now() then 2 else 1 end,
    'inf_cap', 5 + 10 * coalesce((select sum(level) from buildings where player_id = uid and kind = 'barracks' and level >= 1), 0),
    'tank_cap', 3 * coalesce((select sum(level) from buildings where player_id = uid and kind = 'factory' and level >= 1), 0),
    'player', jsonb_build_object('name', p.name, 'province', p.province, 'coins', p.coins, 'gems', p.gems, 'inf', p.inf, 'tanks', p.tanks,
      'trophies', p.trophies, 'shield_until', p.shield_until, 'vip_until', p.vip_until,
      'hat', p.hat, 'suit', p.suit, 'hats', to_jsonb(p.hats), 'suits', to_jsonb(p.suits)),
    'buildings', (select jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'x', x, 'y', y, 'level', level, 'done_at', done_at,
        'cost', g_cost(kind, level), 'secs', g_secs(kind, level),
        'tax_at', tax_at, 'rate', g_tax(kind, level) * vip)) from buildings where player_id = uid),
    'shop', (select jsonb_object_agg(k, jsonb_build_object('max', g_max(k, hq), 'cost', g_cost(k, 0), 'secs', g_secs(k, 0),
        'unlock', (select min(h) from generate_series(1, 10) h where g_max(k, h) > 0),
        'count', (select count(*) from buildings where player_id = uid and kind = k))) from unnest(ks) k));
end $$;

-- ---------- สร้าง / อัปเกรด / ย้าย ----------
create or replace function _builder_free(pid uuid) returns void language plpgsql security definer set search_path = public as $$
declare busy int; vip boolean;
begin
  select count(*) into busy from buildings where player_id = pid and done_at is not null;
  select vip_until > now() into vip from players where id = pid;
  if busy >= (case when vip then 2 else 1 end) then raise exception 'ช่างไม่ว่าง รอให้งานก่อนหน้าเสร็จ (VIP ได้ช่าง 2 ชุด)'; end if;
end $$;

-- ศูนย์บัญชาการกินพื้นที่ 2x2 ช่อง อาคารอื่น 1 ช่อง
create or replace function _free(pid uuid, k text, px int, py int, ignore bigint) returns boolean language sql stable security definer set search_path = public as $$
  select px >= 0 and py >= 0 and px + (case when k = 'hq' then 1 else 0 end) <= 27 and py + (case when k = 'hq' then 1 else 0 end) <= 27
    and _owns(pid, px, py)
    and (k <> 'hq' or (_owns(pid, px + 1, py) and _owns(pid, px, py + 1) and _owns(pid, px + 1, py + 1)))
    and not exists (select 1 from buildings b where b.player_id = pid and (ignore is null or b.id <> ignore)
      and px <= b.x + (case when b.kind = 'hq' then 1 else 0 end) and px + (case when k = 'hq' then 1 else 0 end) >= b.x
      and py <= b.y + (case when b.kind = 'hq' then 1 else 0 end) and py + (case when k = 'hq' then 1 else 0 end) >= b.y) $$;

create or replace function api_build(p_kind text, p_x int, p_y int) returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := _me(); p players; cost bigint; cnt int;
begin
  perform _finish(uid);
  select * into p from players where id = uid for update;
  if p_kind is null or not (p_kind = any(g_kinds())) then raise exception 'ไม่มีอาคารนี้'; end if;
  if p_x is null or p_y is null or not _free(uid, p_kind, p_x, p_y, null) then raise exception 'วางตรงนี้ไม่ได้ ช่องไม่ว่างหรืออยู่นอกพื้นที่'; end if;
  select count(*) into cnt from buildings where player_id = uid and kind = p_kind;
  if cnt >= g_max(p_kind, _hq(uid)) then raise exception 'สร้างอาคารชนิดนี้ครบจำนวนแล้ว อัปเกรดศูนย์บัญชาการเพื่อสร้างเพิ่ม'; end if;
  cost := g_cost(p_kind, 0);
  if p_kind in ('road', 'wall') then   -- ถนนและกำแพงสร้างเสร็จทันที ไม่ใช้ช่าง
    if p.coins < cost then raise exception 'ทองคำไม่พอ'; end if;
    update players set coins = coins - cost where id = uid;
    insert into buildings(player_id, kind, x, y, level) values (uid, p_kind, p_x, p_y, 1);
    return jsonb_build_object('ok', true);
  end if;
  perform _builder_free(uid);
  if p.coins < cost then raise exception 'ทองคำไม่พอ'; end if;
  update players set coins = coins - cost where id = uid;
  perform _addxp(uid, (cost / 20)::int);
  insert into buildings(player_id, kind, x, y, level, done_at) values (uid, p_kind, p_x, p_y, 0, now() + make_interval(secs => g_secs(p_kind, 0)));
  return jsonb_build_object('ok', true);
end $$;

create or replace function api_upgrade(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := _me(); p players; b buildings; cost bigint;
begin
  perform _finish(uid);
  select * into p from players where id = uid for update;
  select * into b from buildings where id = p_id and player_id = uid for update;
  if not found then raise exception 'ไม่พบอาคารนี้'; end if;
  if b.kind = 'road' then raise exception 'ถนนอัปเกรดไม่ได้'; end if;
  if b.done_at is not null then raise exception 'อาคารนี้กำลังก่อสร้างอยู่'; end if;
  if b.level >= 10 then raise exception 'อาคารนี้ระดับสูงสุดแล้ว'; end if;
  if b.kind <> 'hq' and b.level >= _hq(uid) then raise exception 'ต้องอัปเกรดศูนย์บัญชาการก่อน'; end if;
  perform _builder_free(uid);
  cost := g_cost(b.kind, b.level);
  if p.coins < cost then raise exception 'ทองคำไม่พอ'; end if;
  update players set coins = coins - cost where id = uid;
  perform _addxp(uid, (cost / 20)::int);
  update buildings set done_at = now() + make_interval(secs => g_secs(b.kind, b.level)) where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function api_move(p_id bigint, p_x int, p_y int) returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := _me(); k text;
begin
  select kind into k from buildings where id = p_id and player_id = uid;
  if not found then raise exception 'ไม่พบอาคารนี้'; end if;
  if p_x is null or p_y is null or not _free(uid, k, p_x, p_y, p_id) then raise exception 'วางตรงนี้ไม่ได้ ช่องไม่ว่างหรืออยู่นอกพื้นที่'; end if;
  update buildings set x = p_x, y = p_y where id = p_id and player_id = uid;
  return jsonb_build_object('ok', true);
end $$;

-- รื้ออาคาร คืนทองคำครึ่งราคาสร้าง
create or replace function api_remove(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := _me(); b buildings; back bigint;
begin
  select * into b from buildings where id = p_id and player_id = uid for update;
  if not found then raise exception 'ไม่พบอาคารนี้'; end if;
  if b.kind = 'hq' then raise exception 'รื้อศูนย์บัญชาการไม่ได้'; end if;
  back := least(g_cost(b.kind, 0) / 2, greatest(0, _cap(uid) - (select coins from players where id = uid)));
  delete from buildings where id = p_id;
  update players set coins = coins + back where id = uid;
  return jsonb_build_object('ok', true, 'refund', back);
end $$;

-- ซื้อที่ดินแปลงใหม่ (ต้องติดกับแปลงที่มีอยู่ ราคาแพงขึ้นเรื่อยๆ จำกัดตามเลเวล)
create or replace function api_buy_plot(p_px int, p_py int) returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := _me(); p players; pid int; n int; price bigint;
begin
  if p_px is null or p_py is null or p_px < 0 or p_py < 0 or p_px > 6 or p_py > 6 then raise exception 'ไม่มีที่ดินแปลงนี้'; end if;
  select * into p from players where id = uid for update;
  pid := p_py * 7 + p_px; n := coalesce(array_length(p.plots, 1), 0);
  if pid = any(p.plots) then raise exception 'ที่ดินแปลงนี้เป็นของคุณแล้ว'; end if;
  if not exists (select 1 from unnest(p.plots) q where (abs(q % 7 - p_px) + abs(q / 7 - p_py)) = 1) then raise exception 'ต้องซื้อที่ดินที่ติดกับที่ดินของคุณ'; end if;
  if n >= _maxplots(uid) then raise exception 'เลเวลยังไม่พอ เก็บ Exp เพิ่มเพื่อขยายเมือง'; end if;
  price := _plotprice(n - 2);
  if p.coins < price then raise exception 'ทองคำไม่พอ'; end if;
  update players set coins = coins - price, plots = plots || pid where id = uid;
  perform _addxp(uid, 20);
  return jsonb_build_object('ok', true, 'price', price);
end $$;

-- รีเซ็ตผังเมือง: จัดอาคารทั้งหมดเรียงใหม่ในที่ดินที่มี (เสียทอง 50 ต่ออาคาร) แล้วค่อยลากย้ายเองต่อได้
create or replace function api_reset_layout() returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := _me(); p players; cnt int; cost bigint; hx int; hy int;
begin
  perform _finish(uid);
  select * into p from players where id = uid for update;
  select count(*) into cnt from buildings where player_id = uid and kind <> 'hq';
  if cnt = 0 then raise exception 'ยังไม่มีอาคารให้จัดผัง'; end if;
  cost := 50 * cnt;
  if p.coins < cost then raise exception 'ทองคำไม่พอ'; end if;
  select x, y into hx, hy from buildings where player_id = uid and kind = 'hq';
  set constraints buildings_player_id_x_y_key deferred;
  with t as (
    select row_number() over (order by q, ty, tx) rn, tx, ty from (
      select q, (q / 7) * 4 + dy as ty, (q % 7) * 4 + dx as tx from unnest(p.plots) q, generate_series(0, 3) dx, generate_series(0, 3) dy) z
    where not (tx between hx and hx + 1 and ty between hy and hy + 1)),
  b as (select id, row_number() over (order by case when kind in ('road', 'wall') then 1 else 0 end, id) rn from buildings where player_id = uid and kind <> 'hq')
  update buildings set x = t.tx, y = t.ty from b join t on t.rn = b.rn where buildings.id = b.id;
  update players set coins = coins - cost where id = uid;
  return jsonb_build_object('ok', true, 'price', cost);
end $$;

create or replace function api_collect(p_id bigint default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := _me(); r jsonb;
begin
  perform _finish(uid);
  r := _collect(uid, p_id);
  if (r->>'total')::bigint = 0 and (r->>'full')::boolean then raise exception 'หลอดทองคำเต็ม สร้างหรืออัปเกรดคลังก่อน'; end if;
  return r;
end $$;

-- ---------- ซื้อกำลังพล ----------
create or replace function api_train(p_unit text, p_n int) returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := _me(); p players; cap int; price int;
begin
  if p_n is null or p_n < 1 or p_n > 500 then raise exception 'จำนวนไม่ถูกต้อง'; end if;
  perform _finish(uid);
  select * into p from players where id = uid for update;
  if p_unit = 'inf' then
    price := 30; cap := 5 + 10 * coalesce((select sum(level) from buildings where player_id = uid and kind = 'barracks' and level >= 1), 0);
    if p.inf + p_n > cap then raise exception 'ค่ายทหารเต็ม สร้างหรืออัปเกรดค่ายทหารก่อน'; end if;
    if p.coins < price * p_n then raise exception 'ทองคำไม่พอ'; end if;
    update players set coins = coins - price * p_n, inf = inf + p_n where id = uid;
  elsif p_unit = 'tank' then
    price := 160; cap := 3 * coalesce((select sum(level) from buildings where player_id = uid and kind = 'factory' and level >= 1), 0);
    if cap = 0 then raise exception 'ต้องสร้างโรงงานรถถังก่อน'; end if;
    if p.tanks + p_n > cap then raise exception 'โรงงานรถถังเต็ม อัปเกรดโรงงานก่อน'; end if;
    if p.coins < price * p_n then raise exception 'ทองคำไม่พอ'; end if;
    update players set coins = coins - price * p_n, tanks = tanks + p_n where id = uid;
  else raise exception 'ไม่มีหน่วยรบนี้'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- แต่งตัวเจ้าเมือง ----------
create or replace function api_avatar(p_hat int, p_suit int) returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := _me(); p players; cost int := 0; ph int; ps int;
begin
  select * into p from players where id = uid for update;
  ph := g_avprice('hat', p_hat); ps := g_avprice('suit', p_suit);
  if ph is null or ps is null then raise exception 'ไม่มีชุดนี้'; end if;
  if not (p_hat = any(p.hats)) then cost := cost + ph; end if;
  if not (p_suit = any(p.suits)) then cost := cost + ps; end if;
  if p.gems < cost then raise exception 'เพชรแดงไม่พอ (ต้องใช้ % เพชรแดง)', cost; end if;
  update players set gems = gems - cost, hat = p_hat, suit = p_suit,
    hats = case when p_hat = any(hats) then hats else hats || p_hat end,
    suits = case when p_suit = any(suits) then suits else suits || p_suit end where id = uid;
  return jsonb_build_object('ok', true, 'price', cost);
end $$;

-- ---------- แผนที่ / สอดแนม / โจมตี ----------
create or replace function api_map() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare uid uuid := _me(); t int;
begin
  select trophies into t from players where id = uid;
  return (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select p.id, p.name, p.province, p.trophies, p.is_bot, (p.shield_until > now()) as shield, _hq(p.id) as hq
    from players p where p.id <> uid order by abs(p.trophies - t), p.created_at limit 40) x);
end $$;

create or replace function api_scout(p_id uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := _me(); t players;
begin
  select * into t from players where id = p_id and id <> uid;
  if not found then raise exception 'ไม่พบเมืองนี้'; end if;
  perform _finish(t.id);
  if t.is_bot then perform _collect(t.id, null); select * into t from players where id = p_id; end if;
  return jsonb_build_object('id', t.id, 'name', t.name, 'province', t.province, 'trophies', t.trophies, 'is_bot', t.is_bot,
    'shield', t.shield_until > now(), 'hq', _hq(t.id), 'rank', _rank(t.id), 'defense', _def(t.id), 'hat', t.hat, 'suit', t.suit,
    'loot', floor(t.coins * (0.10 + 0.20 * _uncovered(t.id)))::bigint, 'layout', _layout(t.id), 'plots', to_jsonb(t.plots));
end $$;

create or replace function api_attack(p_target uuid, p_inf int, p_tanks int) returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := _me(); a players; d players; atk numeric; def numeric; win boolean; f numeric; li int; lt int; loot bigint := 0; tr int; dtr int;
begin
  if p_target is null or p_target = uid then raise exception 'ตีเมืองตัวเองไม่ได้'; end if;
  perform 1 from players where id in (uid, p_target) order by id for update;
  perform _finish(uid); perform _finish(p_target);
  select * into a from players where id = uid;
  select * into d from players where id = p_target;
  if not found then raise exception 'ไม่พบเมืองนี้'; end if;
  if d.is_bot then perform _collect(d.id, null); select * into d from players where id = p_target; end if;
  if d.shield_until > now() then raise exception 'เมืองนี้ติดการ์ดป้องกันอยู่'; end if;
  p_inf := coalesce(p_inf, 0); p_tanks := coalesce(p_tanks, 0);
  if p_inf < 0 or p_tanks < 0 or p_inf > a.inf or p_tanks > a.tanks or p_inf + p_tanks < 1 then raise exception 'จำนวนกำลังพลไม่ถูกต้อง'; end if;
  atk := round((p_inf * 10 + p_tanks * 60) * (1 + _rbonus(_rank(uid))) * (0.85 + random() * 0.30));
  def := _def(p_target);
  win := atk > def;
  if win then
    f := least(0.9, greatest(0.2, def / atk)) * (1 - _heal(uid));
    li := ceil(p_inf * f); lt := floor(p_tanks * f);
    loot := least(floor(d.coins * (0.10 + 0.20 * _uncovered(p_target)))::bigint, greatest(0, _cap(uid) - a.coins));
    tr := 20 + least(10, greatest(0, (d.trophies - a.trophies) / 20));
    dtr := -least(d.trophies, 15);
  else
    li := ceil(p_inf * (1 - _heal(uid))); lt := ceil(p_tanks * (1 - _heal(uid))); tr := -least(a.trophies, 10); dtr := 5;
  end if;
  update players set inf = inf - li, tanks = tanks - lt, coins = coins + loot, trophies = trophies + tr,
    shield_until = least(shield_until, now()) where id = uid;
  update players set coins = coins - loot, trophies = trophies + dtr,
    inf = case when win then floor(inf * 0.7)::int else inf end, tanks = case when win then floor(tanks * 0.7)::int else tanks end,
    shield_until = case when win then now() + (case when is_bot then interval '5 minutes' else interval '6 hours' end) else shield_until end
    where id = p_target;
  perform _addxp(uid, 10 + (case when win then 30 else 0 end));
  insert into battles(attacker, defender, attacker_name, defender_name, win, loot, trophies)
    values (uid, p_target, a.name, d.name, win, loot, tr);
  return jsonb_build_object('win', win, 'atk', atk, 'def', def, 'lost_inf', li, 'lost_tanks', lt, 'loot', loot, 'trophies', tr,
    'name', d.name, 'layout', _layout(p_target), 'plots', to_jsonb((select plots from players where id = p_target)));
end $$;

-- ---------- ร้านการ์ด (ใช้เพชรแดง) ----------
create or replace function api_buy(p_item text) returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := _me(); p players; price int; rem numeric;
begin
  perform _finish(uid);
  select * into p from players where id = uid for update;
  if p_item = 'shield' then
    price := 30;
    if p.gems < price then raise exception 'เพชรแดงไม่พอ'; end if;
    update players set gems = gems - price, shield_until = greatest(shield_until, now()) + interval '24 hours' where id = uid;
  elsif p_item = 'vip' then
    price := 100;
    if p.gems < price then raise exception 'เพชรแดงไม่พอ'; end if;
    update players set gems = gems - price, vip_until = greatest(vip_until, now()) + interval '7 days' where id = uid;
  elsif p_item = 'finish' then
    select coalesce(sum(greatest(0, extract(epoch from done_at - now()))), 0) into rem from buildings where player_id = uid and done_at is not null;
    if rem <= 0 then raise exception 'ไม่มีงานก่อสร้างให้เร่ง'; end if;
    price := greatest(1, ceil(rem / 300.0))::int;
    if p.gems < price then raise exception 'เพชรแดงไม่พอ (ต้องใช้ % เพชรแดง)', price; end if;
    update players set gems = gems - price where id = uid;
    update buildings set done_at = now() where player_id = uid and done_at is not null;
    perform _finish(uid);
  else
    raise exception 'ไม่มีสินค้านี้';
  end if;
  return jsonb_build_object('ok', true, 'price', price);
end $$;

-- ---------- อันดับ / ประวัติ ----------
create or replace function api_top() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare uid uuid := _me();
begin
  return jsonb_build_object(
    'players', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
        select p.name, p.province, p.trophies, p.is_bot, (p.id = uid) as me, _hq(p.id) as hq
        from players p order by p.trophies desc, p.created_at limit 20) x),
    'provinces', (select coalesce(jsonb_agg(y), '[]'::jsonb) from (
        select province, sum(trophies)::int as total, count(*)::int as cities,
          (array_agg(name order by trophies desc, created_at))[1] as lord
        from players group by province order by sum(trophies) desc, province limit 20) y));
end $$;

create or replace function api_battles() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare uid uuid := _me();
begin
  return (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select (attacker = uid) as mine, attacker, attacker_name, defender_name, win, loot, trophies, at
    from battles where attacker = uid or defender = uid order by at desc limit 12) x);
end $$;

-- ---------- เมืองบอท ----------
create or replace function _seed_bots() returns void language plpgsql security definer set search_path = public as $$
declare i int; j int; bid uuid; lv int;
  provs text[] := array['กรุงเทพมหานคร','ชลบุรี','เชียงใหม่','ภูเก็ต','ขอนแก่น','นครราชสีมา','สงขลา','ระยอง','สุราษฎร์ธานี','อุดรธานี','พิษณุโลก','ประจวบคีรีขันธ์','ตราด','กระบี่'];
  hx int[] := array[1,5,1,5,3,6,0,3]; hy int[] := array[1,1,5,5,6,3,3,0];
  tx int[] := array[2,4,4,2,6,1];     ty int[] := array[2,5,2,4,5,6];
  wx int[] := array[2,3,4,5,2,5,2,5]; wy int[] := array[7,7,7,7,0,0,6,6];
begin
  if exists (select 1 from players where is_bot) then return; end if;
  for i in 1..14 loop
    bid := gen_random_uuid(); lv := 1 + (i - 1) / 2;
    insert into players(id, name, province, is_bot, coins, inf, tanks, trophies, shield_until, hat, suit)
      values (bid, 'บอท' || provs[i], provs[i], true, 400 * i, 2 * (i - 1), (i - 1) / 4, 25 * (i - 1), now(), i % 3, i % 3);
    insert into buildings(player_id, kind, x, y, level) values (bid, 'hq', 3, 3, lv);
    update players set plots = array[16,17,18,23,24,25,30,31,32] where id = bid;
    for j in 1..least(8, 2 + lv) loop insert into buildings(player_id, kind, x, y, level) values (bid, 'house', hx[j], hy[j], lv); end loop;
    for j in 1..least(6, (lv + 1) / 2) loop insert into buildings(player_id, kind, x, y, level) values (bid, 'turret', tx[j], ty[j], lv); end loop;
    for j in 1..least(8, lv) loop insert into buildings(player_id, kind, x, y, level) select bid, 'wall', wx[j], wy[j], lv where not exists (select 1 from buildings where player_id = bid and x = wx[j] and y = wy[j]); end loop;
    if lv >= 2 then insert into buildings(player_id, kind, x, y, level) values (bid, 'market', 6, 4, lv - 1); end if;
    if lv >= 3 then insert into buildings(player_id, kind, x, y, level) values (bid, 'vault', 0, 5, lv - 2), (bid, 'barracks', 7, 2, lv - 1); end if;
    if lv >= 5 then insert into buildings(player_id, kind, x, y, level) values (bid, 'factory', 0, 0, lv - 3); end if;
    update buildings set x = x + 8, y = y + 8 where player_id = bid;
  end loop;
end $$;
select _seed_bots();
-- ย้ายเมืองเก่า (ผัง 12x12) เข้าสู่แผนที่ใหญ่ 28x28 : เลื่อนเข้ากลางเกาะ +8 และให้ที่ดินกลางเกาะ 9 แปลง
update players set gems = gems where false;
delete from players where is_bot and plots is null;
do $$ begin
  if exists (select 1 from players where plots is null) then
    set constraints buildings_player_id_x_y_key deferred;
    update buildings set x = x + 8, y = y + 8 where player_id in (select id from players where plots is null);
    update players set plots = array[16,17,18,23,24,25,30,31,32] where plots is null;
  end if;
end $$;
select _seed_bots();

-- ======================= ตลาดเทรด: เพชรแดง <-> ทองคำ =======================
-- ราคา "ทองคำต่อเพชรแดง 1 เม็ด" เซิร์ฟเวอร์สร้างเอง ขยับทุก 1 นาที (สุ่มเดินแบบดึงกลับเข้าหาค่ากลาง 200)
-- เผยแพร่เฉพาะแท่งเทียนที่ปิดแล้วเท่านั้น ผู้เล่นจึงเห็นอนาคตล่วงหน้าไม่ได้ ทองคำถอนเป็นเงินจริงไม่ได้
create table if not exists market_candles(m bigint primary key, o numeric not null, h numeric not null, l numeric not null, c numeric not null);
create table if not exists positions(
  id bigserial primary key,
  player_id uuid not null references players(id) on delete cascade,
  side text not null check (side in ('long', 'short')),
  margin bigint not null check (margin > 0),
  lev int not null check (lev in (1, 2, 3, 5, 10)),
  entry numeric not null,
  open_m bigint not null,
  opened_at timestamptz not null default now(),
  status text not null default 'open' check (status in ('open', 'closed', 'liq')),
  exit_price numeric, pnl bigint, closed_at timestamptz
);
create index if not exists positions_pl_ix on positions(player_id, status, id desc);
alter table market_candles enable row level security;
alter table positions enable row level security;

create or replace function _gauss() returns numeric language sql volatile as $$
  select (sqrt(-2 * ln(greatest(random(), 1e-9))) * cos(2 * pi() * random()))::numeric $$;

create or replace function _market_tick() returns void language plpgsql security definer set search_path = public as $$
declare cur bigint := floor(extract(epoch from now()) / 60)::bigint - 1; last bigint; p numeric; o numeric; hi numeric; lo numeric; k int; mm bigint;
begin
  perform pg_advisory_xact_lock(777001);
  select max(m) into last from market_candles;
  if last is null then last := cur - 300; p := 200;
  else
    if cur - last > 720 then last := cur - 720; end if;
    select c into p from market_candles where m = (select max(m) from market_candles);
  end if;
  for mm in last + 1 .. cur loop
    o := p; hi := p; lo := p;
    for k in 1..6 loop
      p := greatest(70, least(900, p * exp(0.0045 * _gauss() + 0.004 * ln(200 / p))));
      hi := greatest(hi, p); lo := least(lo, p);
    end loop;
    insert into market_candles values (mm, round(o, 2), round(hi, 2), round(lo, 2), round(p, 2)) on conflict do nothing;
  end loop;
  delete from market_candles where m < cur - 3000;
end $$;

create or replace function _price() returns numeric language sql stable security definer set search_path = public as $$
  select c from market_candles order by m desc limit 1 $$;

-- ปิดสถานะที่ถูกบังคับขายเมื่อราคาแตะจุดล้างพอร์ต (ขาดทุนเท่าเงินประกัน)
create or replace function _liq(uid uuid) returns void language plpgsql security definer set search_path = public as $$
declare r positions;
begin
  for r in select * from positions where player_id = uid and status = 'open' for update loop
    if r.lev > 1 and ((r.side = 'long' and exists (select 1 from market_candles where m > r.open_m and l <= r.entry * (1 - 1.0 / r.lev)))
        or (r.side = 'short' and exists (select 1 from market_candles where m > r.open_m and h >= r.entry * (1 + 1.0 / r.lev)))) then
      update positions set status = 'liq', exit_price = _price(), pnl = -r.margin, closed_at = now() where id = r.id;
    end if;
  end loop;
end $$;

create or replace function api_market() returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := _me(); p players;
begin
  perform _market_tick(); perform _liq(uid);
  select * into p from players where id = uid;
  return jsonb_build_object('price', _price(), 'now', now(), 'next_in', 60 - extract(epoch from now())::bigint % 60,
    'coins', p.coins, 'gems', p.gems,
    'candles', (select coalesce(jsonb_agg(jsonb_build_array(m, o, h, l, c) order by m), '[]'::jsonb) from (select * from market_candles order by m desc limit 720) z),
    'positions', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'side', side, 'margin', margin, 'lev', lev, 'entry', entry, 'status', status,
        'exit', exit_price, 'pnl', pnl, 'at', opened_at) order by id desc), '[]'::jsonb)
      from (select * from positions where player_id = uid and (status = 'open' or closed_at > now() - interval '1 day') order by id desc limit 20) q));
end $$;

-- แลกเพชรแดงเป็นทองคำที่ราคาตลาด (หักค่าธรรมเนียม 2%) ทางเดียว ทองคำแลกกลับเป็นเพชรแดงไม่ได้
create or replace function api_exchange(p_gems int) returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := _me(); p players; px numeric; got bigint;
begin
  if p_gems is null or p_gems < 1 or p_gems > 100000 then raise exception 'จำนวนไม่ถูกต้อง'; end if;
  perform _market_tick();
  select * into p from players where id = uid for update;
  if p.gems < p_gems then raise exception 'เพชรแดงไม่พอ'; end if;
  px := _price(); got := floor(p_gems * px * 0.98);
  update players set gems = gems - p_gems, coins = coins + got where id = uid;
  return jsonb_build_object('ok', true, 'gold', got, 'price', px);
end $$;

create or replace function api_open(p_side text, p_margin bigint, p_lev int) returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := _me(); p players; fee bigint; px numeric; om bigint;
begin
  if p_side not in ('long', 'short') or p_lev not in (1, 2, 3, 5, 10) then raise exception 'จำนวนไม่ถูกต้อง'; end if;
  if p_margin is null or p_margin < 50 or p_margin > 1000000000 then raise exception 'เงินประกันขั้นต่ำ 50 ทองคำ'; end if;
  perform _market_tick(); perform _liq(uid);
  select * into p from players where id = uid for update;
  if (select count(*) from positions where player_id = uid and status = 'open') >= 5 then raise exception 'เปิดสถานะได้พร้อมกันไม่เกิน 5 รายการ'; end if;
  fee := ceil(p_margin * p_lev * 0.002);
  if p.coins < p_margin + fee then raise exception 'ทองคำไม่พอ'; end if;
  px := _price(); select max(m) into om from market_candles;
  update players set coins = coins - p_margin - fee where id = uid;
  insert into positions(player_id, side, margin, lev, entry, open_m) values (uid, p_side, p_margin, p_lev, px, om);
  return jsonb_build_object('ok', true, 'price', px, 'fee', fee);
end $$;

create or replace function api_close(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := _me(); r positions; px numeric; pnl bigint; pay bigint; fee bigint;
begin
  perform _market_tick(); perform _liq(uid);
  select * into r from positions where id = p_id and player_id = uid for update;
  if not found then raise exception 'ไม่พบสถานะนี้'; end if;
  if r.status <> 'open' then raise exception 'สถานะนี้ปิดไปแล้ว'; end if;
  px := _price();
  pnl := floor(r.margin * r.lev * (case when r.side = 'long' then px / r.entry - 1 else 1 - px / r.entry end));
  fee := ceil(r.margin * r.lev * 0.002);
  pay := greatest(0, r.margin + pnl - fee);
  update positions set status = 'closed', exit_price = px, pnl = pay - r.margin, closed_at = now() where id = r.id;
  update players set coins = coins + pay where id = uid;
  return jsonb_build_object('ok', true, 'pay', pay, 'pnl', pay - r.margin, 'price', px);
end $$;

-- ---------- สิทธิ์: ปิดทุกอย่าง เปิดเฉพาะ api_* ให้ผู้ที่ล็อกอินแล้ว ----------
revoke all on players, buildings, battles, market_candles, positions from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function api_join(text, text), api_state(), api_build(text, int, int), api_upgrade(bigint), api_move(bigint, int, int),
  api_collect(bigint), api_remove(bigint), api_train(text, int), api_avatar(int, int), api_map(), api_scout(uuid), api_attack(uuid, int, int),
  api_buy(text), api_top(), api_battles(), api_buy_plot(int, int), api_reset_layout(), api_market(), api_exchange(int), api_open(text, bigint, int), api_close(bigint) to authenticated;

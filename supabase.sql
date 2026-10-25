-- TimelessTouch · Kho đồng hồ
-- Chạy 1 lần trong Supabase → SQL Editor của project TimelessTouch (project riêng, không dùng chung với HPG CRM).
-- Chạy lại nhiều lần cũng không sao.

-- 1) Danh sách chủ shop: chỉ email trong bảng này mới thấy giá nhập, chi phí, lãi
create table if not exists public.owners (email text primary key);
alter table public.owners enable row level security;
drop policy if exists "owners self read" on public.owners;
create policy "owners self read" on public.owners for select to authenticated
  using (lower(email) = lower(coalesce(auth.jwt()->>'email','')));

create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.owners where lower(email) = lower(coalesce(auth.jwt()->>'email','')))
$$;

-- 2) Đồng hồ: mỗi dòng là 1 chiếc (hàng 2hand, mỗi mẫu 1 chiếc)
create table if not exists public.watches (
  id text primary key,
  brand text default '', model text default '', ref text default '', year text default '',
  movement text default '', size text default '', material text default '',
  condition text default '', accessories jsonb default '[]'::jsonb, photos jsonb default '[]'::jsonb,
  status text default 'Mới nhập', list_price numeric default 0, in_date date, note text default '',
  deposit numeric default 0, deposit_date date,
  sold_date date, sale_price numeric default 0,
  buyer_name text default '', buyer_phone text default '', buyer_social text default '',
  channel text default '', pay_method text default '', warranty_until date,
  created_by text default '', created_at timestamptz default now(), updated_at timestamptz default now()
);
alter table public.watches add column if not exists show_on_shop boolean default true;
alter table public.watches add column if not exists shop_desc text default '';
alter table public.watches add column if not exists hold_until timestamptz;
alter table public.watches enable row level security;
drop policy if exists "watches read" on public.watches;
drop policy if exists "watches insert" on public.watches;
drop policy if exists "watches update" on public.watches;
drop policy if exists "watches delete owner" on public.watches;
create policy "watches read"   on public.watches for select to authenticated using (true);
create policy "watches insert" on public.watches for insert to authenticated with check (true);
create policy "watches update" on public.watches for update to authenticated using (true) with check (true);
create policy "watches delete owner" on public.watches for delete to authenticated using (public.is_owner());

-- 3) Giá nhập + chi phí sửa: CHỈ chủ shop đọc / ghi được
create table if not exists public.watch_costs (
  watch_id text primary key references public.watches(id) on delete cascade,
  buy_price numeric default 0, buy_from text default '', repairs jsonb default '[]'::jsonb,
  note text default '', updated_at timestamptz default now()
);
alter table public.watch_costs enable row level security;
drop policy if exists "costs owner" on public.watch_costs;
create policy "costs owner" on public.watch_costs for all to authenticated
  using (public.is_owner()) with check (public.is_owner());

-- 4) Chi phí chung của shop (quảng cáo, ship, hộp quà...): CHỈ chủ shop
create table if not exists public.tt_expenses (
  id uuid primary key default gen_random_uuid(),
  date date, category text default '', amount numeric default 0, note text default '',
  created_at timestamptz default now()
);
alter table public.tt_expenses enable row level security;
drop policy if exists "expenses owner" on public.tt_expenses;
create policy "expenses owner" on public.tt_expenses for all to authenticated
  using (public.is_owner()) with check (public.is_owner());

-- 5) Kho ảnh sản phẩm (ảnh nén nhỏ trước khi tải lên)
insert into storage.buckets (id, name, public) values ('photos', 'photos', true)
on conflict (id) do nothing;
drop policy if exists "photos read" on storage.objects;
drop policy if exists "photos upload" on storage.objects;
drop policy if exists "photos update" on storage.objects;
drop policy if exists "photos delete" on storage.objects;
create policy "photos read"   on storage.objects for select to authenticated using (bucket_id = 'photos');
create policy "photos upload" on storage.objects for insert to authenticated with check (bucket_id = 'photos');
create policy "photos update" on storage.objects for update to authenticated using (bucket_id = 'photos');
create policy "photos delete" on storage.objects for delete to authenticated using (bucket_id = 'photos');

-- 6) WEBSITE BÁN HÀNG: khách xem hàng, đặt mua, chuyển khoản theo mã QR
-- Khách (chưa đăng nhập) chỉ xem được các cột an toàn, KHÔNG thấy giá nhập / thông tin khách khác
create or replace view public.shop_watches as
  select id, brand, model, ref, year, movement, size, material, condition, accessories, photos,
         list_price, shop_desc, updated_at,
         case when status = 'Sẵn sàng bán' or (status = 'Đang giữ (đơn web)' and hold_until < now()) then 'available' else 'held' end as avail
  from public.watches
  where coalesce(show_on_shop, true) and list_price > 0
    and (status = 'Sẵn sàng bán' or status = 'Đang giữ (đơn web)' or status = 'Khách đã cọc');
grant select on public.shop_watches to anon, authenticated;

create table if not exists public.tt_orders (
  id text primary key, watch_id text references public.watches(id) on delete set null,
  name text default '', phone text default '', address text default '', note text default '',
  amount numeric default 0, status text default 'Chờ thanh toán',
  created_at timestamptz default now(), paid_at timestamptz
);
alter table public.tt_orders enable row level security;
drop policy if exists "orders staff" on public.tt_orders;
create policy "orders staff" on public.tt_orders for all to authenticated using (true) with check (true);

-- Khách đặt hàng qua hàm này (giữ hàng 2 tiếng để chuyển khoản)
create or replace function public.place_order(p_watch text, p_name text, p_phone text, p_address text, p_note text)
returns json language plpgsql security definer set search_path = public as $$
declare w public.watches; code text;
begin
  if length(trim(coalesce(p_name,''))) < 2 or length(regexp_replace(coalesce(p_phone,''),'\D','','g')) < 9 then
    raise exception 'Vui lòng nhập họ tên và số điện thoại';
  end if;
  select * into w from public.watches where id = p_watch for update;
  if not found or not coalesce(w.show_on_shop, true) or coalesce(w.list_price,0) <= 0
     or not (w.status = 'Sẵn sàng bán' or (w.status = 'Đang giữ (đơn web)' and w.hold_until < now())) then
    raise exception 'Chiếc đồng hồ này vừa có khách khác đặt';
  end if;
  update public.tt_orders set status = 'Hết hạn' where watch_id = p_watch and status = 'Chờ thanh toán';
  code := 'TT' || to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'DDMM') || upper(substr(md5(random()::text), 1, 4));
  insert into public.tt_orders (id, watch_id, name, phone, address, note, amount)
  values (code, p_watch, left(trim(p_name),80), left(trim(p_phone),20), left(coalesce(p_address,''),300), left(coalesce(p_note,''),500), w.list_price);
  update public.watches set status = 'Đang giữ (đơn web)', hold_until = now() + interval '2 hours', updated_at = now() where id = p_watch;
  return json_build_object('code', code, 'amount', w.list_price);
end $$;
grant execute on function public.place_order(text,text,text,text,text) to anon, authenticated;

-- Khách xem tình trạng đơn của mình bằng mã đơn
create or replace function public.order_status(p_code text) returns text
language sql stable security definer set search_path = public as $$
  select status from public.tt_orders where id = upper(trim(p_code))
$$;
grant execute on function public.order_status(text) to anon, authenticated;

-- Quyền truy cập API (phòng khi project tắt tự cấp quyền cho bảng mới)
grant usage on schema public to anon, authenticated;
grant select on public.owners to authenticated;
grant select, insert, update, delete on public.watches, public.watch_costs, public.tt_expenses, public.tt_orders to authenticated;

-- 7) ĐỔI email bên dưới thành email chị dùng để đăng nhập (chỉ email này thấy giá nhập & lãi)
insert into public.owners (email) values ('EMAIL_CUA_CHI@gmail.com') on conflict do nothing;

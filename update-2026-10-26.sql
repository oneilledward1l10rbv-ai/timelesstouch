-- TimelessTouch · cập nhật 26/10/2026 — chạy 1 lần trong Supabase → SQL Editor
-- 1) Khách đặt hàng KHÔNG giữ đồng hồ nữa: chỉ khi tiệm xác nhận đã nhận tiền mới chuyển sang Đã bán
-- 2) Chiếc đã bán vẫn hiện trên web với nhãn "Đã bán"
-- 3) Kiểm tra số điện thoại Việt Nam hợp lệ (10 số, đầu 03/05/07/08/09, hoặc +84)

create or replace view public.shop_watches as
  select id, brand, model, ref, year, movement, size, material, condition, accessories, photos,
         list_price, shop_desc, updated_at,
         case when status = 'Đã bán' then 'sold' when status = 'Khách đã cọc' then 'held' else 'available' end as avail
  from public.watches
  where coalesce(show_on_shop, true) and list_price > 0
    and status in ('Sẵn sàng bán', 'Đang giữ (đơn web)', 'Khách đã cọc', 'Đã bán');
grant select on public.shop_watches to anon, authenticated;

create or replace function public.place_order(p_watch text, p_name text, p_phone text, p_address text, p_note text)
returns json language plpgsql security definer set search_path = public as $$
declare w public.watches; code text; ph text;
begin
  ph := regexp_replace(coalesce(p_phone,''), '[\s\.\-]', '', 'g');
  if length(trim(coalesce(p_name,''))) < 2 then raise exception 'Vui lòng nhập họ tên'; end if;
  if ph !~ '^(0|\+?84)(3|5|7|8|9)[0-9]{8}$' then raise exception 'Số điện thoại chưa đúng (10 số, ví dụ 0901234567)'; end if;
  select * into w from public.watches where id = p_watch;
  if not found or not coalesce(w.show_on_shop, true) or coalesce(w.list_price,0) <= 0
     or w.status not in ('Sẵn sàng bán', 'Đang giữ (đơn web)') then
    raise exception 'Chiếc đồng hồ này vừa được bán, bạn xem mẫu khác nhé';
  end if;
  code := 'TT' || to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'DDMM') || upper(substr(md5(random()::text), 1, 4));
  insert into public.tt_orders (id, watch_id, name, phone, address, note, amount)
  values (code, p_watch, left(trim(p_name),80), left(ph,20), left(coalesce(p_address,''),300), left(coalesce(p_note,''),500), w.list_price);
  return json_build_object('code', code, 'amount', w.list_price);
end $$;
grant execute on function public.place_order(text,text,text,text,text) to anon, authenticated;

-- Trả các chiếc đang "giữ hàng" về Sẵn sàng bán
update public.watches set status = 'Sẵn sàng bán', hold_until = null where status = 'Đang giữ (đơn web)';

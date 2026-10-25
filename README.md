# TimelessTouch · Kho đồng hồ + Web bán hàng

- `quanly/` — trang quản lý (đăng nhập): kho có ảnh, cọc / bán, đơn web, khách mua, chi phí shop, báo cáo lãi.
- `index.html` (trang chủ) — web bán hàng công khai: khách xem ảnh, đặt mua, quét QR chuyển khoản (VietQR). Đơn về mục **Đơn web**.
- `supabase.sql` — chạy 1 lần trong Supabase (project riêng cho TimelessTouch).
- `config.js` — URL + khoá publishable của Supabase, thông tin tài khoản nhận tiền, link mạng xã hội.

Phân quyền: email trong bảng `owners` (chủ shop) mới thấy giá nhập, chi phí sửa, chi phí shop và lãi — chặn ở cơ sở dữ liệu (RLS), không chỉ ẩn trên giao diện. Nhân viên chỉ thêm / sửa thông tin, ảnh, ghi cọc, bán.

Web bán hàng chỉ đọc được view `shop_watches` (không có giá nhập, không có thông tin khách). Đặt hàng qua hàm `place_order` — giữ hàng 2 tiếng; quá hạn chưa thanh toán thì chiếc đó tự hiện lại là còn hàng.

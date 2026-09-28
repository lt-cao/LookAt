# Kiểm tra LookAt 1.0

Kiểm thử code/giao diện: 09/09/2026; hoàn thiện đóng gói: 10/09/2026. macOS 26.6.2, Apple Silicon, Swift 6.3.3. Cấu hình Release với Swift 6 concurrency checking.

## Kết quả kiểm thử tự động

8/8 ca trong `Tests/LookAtTests/StabilityTests.swift` đạt:

1. Ảnh PNG 11.584 × 8.688 px: chọn 1:1 ngay khi đang tải; raster cuối đúng kích thước, mẫu pixel, độ sâu màu và tên không gian màu khớp kết quả giải mã trực tiếp từ file gốc.
2. Preview tối đa 3.072 px chuyển sang ảnh gốc khi zoom trên 110%, không bị kết quả tải chậm thay lại bằng preview.
3. Chuyển nhanh 40 lượt, hủy các tác vụ cũ, giữ đúng ảnh cuối; gặp file PNG giả/hỏng thì báo lỗi, xóa hình cũ và mở tiếp được ảnh hợp lệ.
4. GIF đã tải trước phát đủ 3 frame với tổng thời gian 0,4 giây và lặp vô hạn; chọn 1:1 vẫn giữ đủ pixel.
5. JPEG có EXIF xoay 90° trả kích thước đã đổi chiều đúng; PNG 16-bit/P3 giữ độ sâu và các mẫu pixel ở chế độ gốc.
6. GIF 4.000 × 3.000 px × 8 frame vượt ngân sách animation 320 MiB: 1:1 dùng frame đầu đủ pixel, kết quả animation cũ không được ghi đè.
7. Ghi đè một file ảnh rồi mở lại từ nguồn ngoài: hiển thị đúng bản mới, không dùng preview cũ.
8. Double-click đổi vừa cửa sổ/1:1 trên Retina; 1 pixel ảnh ứng với 1 pixel vật lý; thu nhỏ tối thiểu 70%; kéo chéo vẫn giữ đủ phần ảnh; cập nhật nhãn zoom được gộp bất đồng bộ, không phát state ngay trong lượt cập nhật view.

Lệnh tái chạy: `zsh scripts/test.sh`.

## Phạm vi số đo

Trên lượt Release ngày 09/09, ảnh PNG thử 11.584 × 8.688 hoàn thành mở, tải gốc và đối chiếu mẫu pixel trong khoảng 0,62 giây. 2.000 lượt thay đổi hình học canvas tốn khoảng 2 ms CPU. Đây là ảnh sinh tự động và phép đo CPU; không tương đương benchmark file ảnh 89,2 MB thực tế hoặc FPS của màn hình.

Canvas thay đổi transform của CALayer theo từng sự kiện, không giải mã lại khi kéo. Chỉ nhãn phần trăm SwiftUI được gộp tối đa 30 lần/giây. Không đặt timer 30/60 Hz lên chuyển động ảnh. Chưa đo bằng Instruments/Core Animation trên màn hình 120 Hz; không khẳng định đạt 120 FPS ở mọi kích thước ảnh hoặc mọi máy.

## Đóng gói

Kiểm tra trực tiếp app đã đóng gói: mở PNG 11.584 × 8.688, chọn 1:1 rồi vừa cửa sổ; chuyển sang GIF và quay lại trong cùng cửa sổ; menu chuột phải có Sao chép đứng đầu; Cài Đặt hiện “Phiên bản 1.0” và tác giả Cao Le.

DMG dùng `hdiutil create` với HFS+/UDZO, thay cho `makehybrid` vốn có thể tự thêm FinderInfo vào file icon và làm hỏng chữ ký. Script kiểm tra checksum, gắn DMG chỉ đọc, xác minh chữ ký bundle bên trong, đối chiếu phiên bản/binary, kiểm tra lối tắt Applications, rồi chép app ra thư mục thử và xác minh chữ ký lần nữa trước khi xuất bản DMG.

Tên hiển thị/phiên bản: LookAt 1.0, build 2. Giữ icon hiện có. Script tạo ứng dụng và DMG dùng thư mục tạm riêng; chỉ thay bản xuất sau khi ký/kiểm tra thành công. Bản ứng dụng/ZIP trước được chuyển vào `work/previous-release.*`; DMG beta trước được giữ nguyên để có thể quay lại.

Ký ad-hoc cục bộ, chưa có Developer ID/notarization. Người dùng cài bản mới bằng cách kéo LookAt.app từ DMG vào Applications. Bộ kiểm thử giúp xác nhận các đường đi đã liệt kê, không phải cam kết không còn lỗi trong mọi file hoặc thiết bị.
